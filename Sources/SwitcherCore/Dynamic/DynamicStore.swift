import Foundation
import Darwin

public enum DynamicStoreError: String, Error, LocalizedError {
    case unsafePath, unsafeFile, oversized, invalidMetadata, futureVersion, duplicateProfile, invalidName
    case lockRequired, recoveryRequired, providerNotStopped, writeFailed, unsupportedProfile
    public var errorDescription: String? { "Pairbar metadata: \(rawValue). Data has been preserved." }
}

/// Only Pairbar metadata is decoded. Provider directories are created or renamed as opaque units.
public final class DynamicStore {
    public let root: URL
    private let backing: PrivateStore
    private var locked = false
    private var rootIdentity: (dev_t, ino_t)?
    private let limit = 65_536
    public init(root: URL) throws {
        self.root = root.standardizedFileURL
        self.backing = try PrivateStore(root: root)
    }
    public func acquireLock() throws {
        try backing.acquireLock()
        var info = stat()
        guard lstat(root.path, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFDIR,
              info.st_mode & 0o077 == 0 else { throw DynamicStoreError.unsafePath }
        rootIdentity = (info.st_dev, info.st_ino); locked = true
    }
    private func requireLock() throws { guard locked else { throw DynamicStoreError.lockRequired } }

    private func directory(_ parts: [String], create: Bool) throws -> Int32? {
        try requireLock()
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("/") && !$0.contains("\0") }) else { throw DynamicStoreError.unsafePath }
        let descriptor = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DynamicStoreError.unsafePath }
        var rootInfo = stat()
        guard fstat(descriptor, &rootInfo) == 0, rootInfo.st_uid == getuid(), rootInfo.st_mode & 0o077 == 0,
              let rootIdentity, rootIdentity.0 == rootInfo.st_dev, rootIdentity.1 == rootInfo.st_ino else {
            close(descriptor); throw DynamicStoreError.unsafePath
        }
        var current = descriptor
        do {
            for part in parts {
                if create {
                    if mkdirat(current, part, 0o700) == 0 {
                        guard fsync(current) == 0 else { throw DynamicStoreError.writeFailed }
                    } else if errno != EEXIST {
                        throw DynamicStoreError.writeFailed
                    }
                }
                let next = openat(current, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else {
                    if !create && errno == ENOENT { close(current); return nil }
                    throw DynamicStoreError.unsafePath
                }
                var info = stat()
                guard fstat(next, &info) == 0, info.st_uid == getuid(), info.st_mode & 0o077 == 0 else {
                    close(next); throw DynamicStoreError.unsafePath
                }
                close(current); current = next
            }
            return current
        } catch { close(current); throw error }
    }
    private func checkFile(_ parent: Int32, _ name: String) throws -> Bool {
        var info = stat()
        if fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return false }; throw DynamicStoreError.unsafeFile
        }
        guard info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { throw DynamicStoreError.unsafeFile }
        return true
    }
    private func bytes(_ parts: [String]) throws -> Data? {
        guard let name = parts.last, let parent = try directory(Array(parts.dropLast()), create: false) else { return nil }
        defer { close(parent) }
        guard try checkFile(parent, name) else { return nil }
        let descriptor = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw DynamicStoreError.unsafeFile }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFREG,
              info.st_mode & 0o077 == 0, info.st_nlink == 1 else { close(descriptor); throw DynamicStoreError.unsafeFile }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        let data = try file.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw DynamicStoreError.oversized }
        return data
    }
    private func read<T: Decodable>(_ type: T.Type, _ parts: [String]) throws -> T? {
        guard let data = try bytes(parts) else { return nil }
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw DynamicStoreError.invalidMetadata }
    }
    private func writeBytes(_ data: Data, _ parts: [String]) throws {
        guard data.count <= limit else { throw DynamicStoreError.oversized }
        guard let name = parts.last, let parent = try directory(Array(parts.dropLast()), create: true) else { throw DynamicStoreError.unsafePath }
        defer { close(parent) }
        _ = try checkFile(parent, name)
        let temporary = ".write-" + UUID().uuidString.lowercased()
        let descriptor = openat(parent, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw DynamicStoreError.writeFailed }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        defer { try? file.close(); unlinkat(parent, temporary, 0) }
        try file.write(contentsOf: data); try file.synchronize()
        _ = try checkFile(parent, name)
        guard renameat(parent, temporary, parent, name) == 0, fsync(parent) == 0 else { throw DynamicStoreError.writeFailed }
    }
    private func write<T: Encodable>(_ value: T, _ parts: [String]) throws { try writeBytes(JSONEncoder().encode(value), parts) }
    private func removeMetadata(_ parts: [String]) throws {
        guard let name = parts.last, let parent = try directory(Array(parts.dropLast()), create: false) else { return }
        defer { close(parent) }; guard try checkFile(parent, name) else { return }
        guard unlinkat(parent, name, 0) == 0, fsync(parent) == 0 else { throw DynamicStoreError.writeFailed }
    }
    private func names(_ parts: [String]) throws -> [String] {
        guard let descriptor = try directory(parts, create: false) else { return [] }
        guard let stream = fdopendir(descriptor) else { close(descriptor); throw DynamicStoreError.unsafePath }
        defer { closedir(stream) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                if errno != 0 { throw DynamicStoreError.unsafePath }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: 1024) { String(cString: $0) }
            }
            if name != "." && name != ".." && !name.hasPrefix(".write-") { result.append(name) }
        }
        return result.sorted()
    }
    private func profileFile(_ provider: ProviderID2, _ id: ManagedProfileID) -> [String] {
        ["Metadata", "profiles", provider.rawValue, id.description + ".json"]
    }
    private struct Schema: Codable { var schemaVersion: Int }
    private struct Migration: Codable {
        let preferences: Preferences2
        let providers: [ProviderSettings2]
        let profiles: [ProfileRecord2]
    }
    public func migrateIfNeeded() throws {
        try requireLock()
        let schema = try read(Settings.self, ["settings.json"])
        if let version = schema?.schemaVersion, version > 3 { throw DynamicStoreError.futureVersion }
        if schema?.schemaVersion == 3 {
            _ = try loadPreferences()
            for provider in ProviderID2.allCases { _ = try loadProvider(provider) }
            _ = try listProfiles()
            try removeMetadata(["Metadata", "migration.json"])
            return
        }
        var migration = try read(Migration.self, ["Metadata", "migration.json"])
        if migration == nil {
            guard try bytes(["Metadata", "preferences.json"]) == nil else { throw DynamicStoreError.recoveryRequired }
            // Tolerate legacy settings without a schema, as the old decoder does.
            let legacy = try read(Settings.self, ["settings.json"])
            let oldReceipts = try read([LaunchReceipt].self, ["receipts.json"]) ?? []
            let oldPending = try read([ProfileID].self, ["pending.json"]) ?? []
            let retained = try MetadataMigration.keepSecondaryReceipts(oldReceipts)
            let hasLegacyStorage = try directoryExists(["Profiles", "b"])
            let hadLegacy = legacy != nil || !oldReceipts.isEmpty || !oldPending.isEmpty || hasLegacyStorage
            var codex = ProviderSettings2(provider: .codex)
            if let old = legacy {
                guard !old.isFromFutureVersion else { throw DynamicStoreError.futureVersion }
                codex.currentName = old.nameA; codex.appPath = old.appPath
                codex.approvedFingerprint = old.approvedFingerprint; codex.setupComplete = old.setupComplete
            }
            var records: [ProfileRecord2] = []
            if hadLegacy {
                var profile = ProfileRecord2(id: .legacySecond, provider: .codex,
                    name: legacy?.nameB ?? "Second account", storage: .legacySecond)
                profile.favorite = true; profile.order = 1; profile.shortcut = .legacySecond
                if let receipt = retained.first {
                    let paths = Paths2(root: root, provider: .codex, storage: .legacySecond)
                    guard receipt.home == paths.codexHome.path, receipt.electron == paths.electron.path else { throw DynamicStoreError.invalidMetadata }
                    profile.receipt = LaunchReceipt2(provider: .codex, profileID: profile.id,
                        storageGeneration: profile.storageGeneration, stamp: receipt.stamp, paths: paths,
                        fingerprint: legacy?.approvedFingerprint, provenance: .legacy)
                }
                if oldPending.contains(.b) {
                    profile.pending = PendingLaunch2(launchID: profile.receipt?.launchID ?? UUID(),
                        fingerprint: legacy?.approvedFingerprint, legacy: true)
                }
                records = [profile]
            }
            let prepared = Migration(preferences: Preferences2(), providers: [codex, ProviderSettings2(provider: .claude)], profiles: records)
            for file in ["settings.json", "receipts.json", "pending.json"] {
                if let data = try bytes([file]) { try writeBytes(data, ["Metadata", "legacy", file]) }
            }
            try write(prepared, ["Metadata", "migration.json"])
            migration = prepared
        }
        guard let migration else { throw DynamicStoreError.invalidMetadata }
        // No provider processes are launched until the schema sentinel and journal are durable.
        try write(migration.preferences, ["Metadata", "preferences.json"])
        for provider in migration.providers { try write(provider, ["Metadata", "providers", provider.provider.rawValue + ".json"]) }
        for profile in migration.profiles { try write(profile, profileFile(profile.provider, profile.id)) }
        _ = try loadPreferences()
        for provider in ProviderID2.allCases { _ = try loadProvider(provider) }
        _ = try listProfiles()
        try write(Schema(schemaVersion: 3), ["settings.json"])
        try removeMetadata(["Metadata", "migration.json"])
    }
    public func loadPreferences() throws -> Preferences2 {
        guard let preferences = try read(Preferences2.self, ["Metadata", "preferences.json"]) else { throw DynamicStoreError.invalidMetadata }
        guard preferences.schemaVersion == 3 else { throw DynamicStoreError.futureVersion }
        guard ["system", "english", "spanish"].contains(preferences.language) else { throw DynamicStoreError.invalidMetadata }
        return preferences
    }
    public func savePreferences(_ value: Preferences2) throws {
        guard value.schemaVersion == 3, ["system", "english", "spanish"].contains(value.language) else { throw DynamicStoreError.invalidMetadata }
        try write(value, ["Metadata", "preferences.json"])
    }
    public func loadProvider(_ provider: ProviderID2) throws -> ProviderSettings2 {
        guard let result = try read(ProviderSettings2.self, ["Metadata", "providers", provider.rawValue + ".json"]), result.provider == provider else { throw DynamicStoreError.invalidMetadata }
        try validateName(result.currentName)
        guard result.appPath.hasPrefix("/"), !result.appPath.contains("\0"), result.appPath.utf8.count <= 4096,
              (-1_000_000_000...1_000_000_000).contains(result.currentOrder),
              result.currentShortcut?.isValid != false else { throw DynamicStoreError.invalidMetadata }
        return result
    }
    public func saveProvider(_ value: ProviderSettings2) throws {
        try validateName(value.currentName)
        guard value.appPath.hasPrefix("/"), !value.appPath.contains("\0"), value.appPath.utf8.count <= 4096,
              (-1_000_000_000...1_000_000_000).contains(value.currentOrder),
              value.currentShortcut?.isValid != false else { throw DynamicStoreError.invalidMetadata }
        let records = try listProfiles()
        guard !records.contains(where: { $0.provider == value.provider && !$0.archived && normalized($0.name) == normalized(value.currentName) }) else {
            throw DynamicStoreError.duplicateProfile
        }
        if let shortcut = value.currentShortcut {
            guard !records.contains(where: { !$0.archived && $0.shortcut == shortcut }),
                  !ProviderID2.allCases.filter({ $0 != value.provider }).contains(where: { (try? loadProvider($0).currentShortcut) == shortcut }) else {
                throw DynamicStoreError.duplicateProfile
            }
        }
        try write(value, ["Metadata", "providers", value.provider.rawValue + ".json"])
    }
    public func listProfiles(provider: ProviderID2? = nil) throws -> [ProfileRecord2] {
        var records: [ProfileRecord2] = []
        let selectedProviders = provider.map({ [$0] }) ?? ProviderID2.allCases
        for selected in selectedProviders {
            for name in try names(["Metadata", "profiles", selected.rawValue]) {
                guard name.hasSuffix(".json"), let uuid = UUID(uuidString: String(name.dropLast(5))),
                      let record = try read(ProfileRecord2.self, profileFile(selected, ManagedProfileID(uuid))),
                      record.provider == selected, record.id.rawValue == uuid else { throw DynamicStoreError.invalidMetadata }
                try validate(record); records.append(record)
            }
        }
        var ids = Set<ManagedProfileID>(), paths = Set<String>(), pids = Set<Int32>()
        for record in records {
            guard ids.insert(record.id).inserted else { throw DynamicStoreError.duplicateProfile }
            if !record.archived { guard paths.insert(pathsFor(record).base.path).inserted else { throw DynamicStoreError.duplicateProfile } }
            if let receipt = record.receipt { guard pids.insert(receipt.stamp.pid).inserted else { throw DynamicStoreError.duplicateProfile } }
        }
        var shortcuts = Set<Shortcut2>()
        for selected in selectedProviders {
            let settings = try loadProvider(selected)
            var profileNames = Set([normalized(settings.currentName)])
            if let shortcut = settings.currentShortcut {
                guard shortcuts.insert(shortcut).inserted else { throw DynamicStoreError.duplicateProfile }
            }
            for record in records where record.provider == selected && !record.archived {
                guard profileNames.insert(normalized(record.name)).inserted else { throw DynamicStoreError.duplicateProfile }
                if let shortcut = record.shortcut {
                    guard shortcuts.insert(shortcut).inserted else { throw DynamicStoreError.duplicateProfile }
                }
            }
        }
        return records.sorted { $0.order == $1.order ? $0.id.description < $1.id.description : $0.order < $1.order }
    }
    public func createProfile(provider: ProviderID2, name: String) throws -> ProfileRecord2 {
        guard provider == .codex else { throw DynamicStoreError.unsupportedProfile }
        var record = ProfileRecord2(provider: provider, name: name.trimmingCharacters(in: .whitespacesAndNewlines))
        let maximum = try listProfiles().map(\.order).max() ?? 0
        let next = maximum.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue <= 1_000_000_000 else { throw DynamicStoreError.invalidMetadata }
        record.order = next.partialValue
        try saveProfile(record); return record
    }
    public func saveProfile(_ record: ProfileRecord2) throws {
        try validate(record)
        let records = try listProfiles()
        let current = try loadProvider(record.provider)
        if !record.archived {
            guard normalized(current.currentName) != normalized(record.name), !records.contains(where: {
                $0.id != record.id && !$0.archived && $0.provider == record.provider && normalized($0.name) == normalized(record.name)
            }) else { throw DynamicStoreError.duplicateProfile }
            guard !records.contains(where: { $0.id != record.id && !$0.archived && pathsFor($0).base == pathsFor(record).base }) else { throw DynamicStoreError.duplicateProfile }
        }
        if let receipt = record.receipt {
            guard !records.contains(where: { $0.id != record.id && $0.receipt?.stamp.pid == receipt.stamp.pid }) else { throw DynamicStoreError.duplicateProfile }
        }
        if !record.archived, let shortcut = record.shortcut {
            guard !records.contains(where: { $0.id != record.id && !$0.archived && $0.shortcut == shortcut }),
                  !ProviderID2.allCases.contains(where: { (try? loadProvider($0).currentShortcut) == shortcut }) else {
                throw DynamicStoreError.duplicateProfile
            }
        }
        try write(record, profileFile(record.provider, record.id))
    }
    private func normalized(_ name: String) -> String { name.precomposedStringWithCanonicalMapping.lowercased() }
    private func validateName(_ name: String) throws {
        guard !name.isEmpty, name.count <= 40, name == name.trimmingCharacters(in: .whitespacesAndNewlines),
              !name.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }) else { throw DynamicStoreError.invalidName }
    }
    private func validate(_ profile: ProfileRecord2) throws {
        guard profile.schemaVersion == 1 else { throw DynamicStoreError.futureVersion }
        try validateName(profile.name)
        guard (-1_000_000_000...1_000_000_000).contains(profile.order),
              profile.shortcut?.isValid != false else { throw DynamicStoreError.invalidMetadata }
        guard profile.storage != .legacySecond || (profile.provider == .codex && profile.id == .legacySecond),
              !profile.archived || (profile.receipt == nil && profile.pending == nil && !profile.launchAtLogin && profile.shortcut == nil) else { throw DynamicStoreError.invalidMetadata }
        if let receipt = profile.receipt {
            guard receipt.launchPolicyVersion == 1,
                  receipt.owns(receipt.stamp, profile: profile, paths: pathsFor(profile), uid: getuid()) else {
                throw DynamicStoreError.invalidMetadata
            }
            switch receipt.provenance {
            case .runtime:
                guard let fingerprint = receipt.fingerprint, !fingerprint.isEmpty, fingerprint.utf8.count <= 512 else {
                    throw DynamicStoreError.invalidMetadata
                }
            case .legacy:
                guard profile.provider == .codex, profile.id == .legacySecond else { throw DynamicStoreError.invalidMetadata }
            }
        }
        if let pending = profile.pending {
            guard pending.launchPolicyVersion == 1, pending.startedAt.timeIntervalSinceReferenceDate.isFinite else {
                throw DynamicStoreError.invalidMetadata
            }
            if pending.legacy {
                guard profile.provider == .codex, profile.id == .legacySecond else { throw DynamicStoreError.invalidMetadata }
            } else {
                guard let fingerprint = pending.fingerprint, !fingerprint.isEmpty, fingerprint.utf8.count <= 512 else {
                    throw DynamicStoreError.invalidMetadata
                }
            }
            if let receipt = profile.receipt {
                guard pending.launchID == receipt.launchID, pending.fingerprint == receipt.fingerprint,
                      pending.launchPolicyVersion == receipt.launchPolicyVersion,
                      pending.legacy == (receipt.provenance == .legacy) else { throw DynamicStoreError.invalidMetadata }
            }
        }
    }
    private func pathsFor(_ profile: ProfileRecord2) -> Paths2 { Paths2(root: root, provider: profile.provider, storage: profile.storage) }
    public func paths(for profile: ProfileRecord2) -> Paths2 { pathsFor(profile) }
    public func prepareStorage(for profile: ProfileRecord2) throws -> Paths2 {
        try requireLock(); try validate(profile)
        guard !profile.archived, profile.provider == .codex else { throw DynamicStoreError.unsupportedProfile }
        let paths = pathsFor(profile)
        let baseParts: [String]
        switch profile.storage {
        case .legacySecond: baseParts = ["Profiles", "b"]
        case .generated(let id): baseParts = ["Profiles", profile.provider.rawValue, id.uuidString.lowercased()]
        }
        for parts in [baseParts, baseParts + ["electron"], baseParts + ["codex"]] {
            guard let descriptor = try directory(parts, create: true) else { throw DynamicStoreError.unsafePath }
            close(descriptor)
        }
        return paths
    }
    private func directoryExists(_ parts: [String]) throws -> Bool {
        guard let descriptor = try directory(parts, create: false) else { return false }
        close(descriptor)
        return true
    }
    public func hasOrphanStorage(provider: ProviderID2, records: [ProfileRecord2]) throws -> Bool {
        let stored = Set(records.filter { $0.provider == provider && !$0.archived }.map { pathsFor($0).base.lastPathComponent })
        let directoryNames = try names(["Profiles", provider.rawValue])
        if directoryNames.contains(where: { !stored.contains($0) }) { return true }
        guard provider == .codex else { return false }
        return try directoryExists(["Profiles", "b"]) && !stored.contains("b")
    }
    private struct ArchiveOperation: Codable {
        let id: UUID
        let before: ProfileRecord2
        let after: ProfileRecord2
        let hadStorage: Bool
    }
    private func operations() throws -> [ArchiveOperation] {
        try names(["Metadata", "operations"]).map { name in
            guard name.hasSuffix(".json"), UUID(uuidString: String(name.dropLast(5))) != nil,
                  let operation = try read(ArchiveOperation.self, ["Metadata", "operations", name]),
                  name == operation.id.uuidString.lowercased() + ".json" else { throw DynamicStoreError.invalidMetadata }
            return operation
        }
    }
    public func hasPendingOperations(provider: ProviderID2) throws -> Bool { try operations().contains { $0.before.provider == provider } }
    private func requireQuiescence(_ evidence: ProviderQuiescence2) throws {
        guard evidence.officialProcessCount == 0, !evidence.hasUnverifiableProcesses,
              Date().timeIntervalSince(evidence.observedAt) >= 0, Date().timeIntervalSince(evidence.observedAt) <= 2 else { throw DynamicStoreError.providerNotStopped }
        guard !(try listProfiles(provider: evidence.provider)).contains(where: { $0.receipt != nil || $0.pending != nil }) else { throw DynamicStoreError.recoveryRequired }
        let records = try listProfiles()
        guard try !hasOrphanStorage(provider: evidence.provider, records: records) else { throw DynamicStoreError.recoveryRequired }
    }
    public func archive(profileID: ManagedProfileID, reset: Bool, evidence: ProviderQuiescence2) throws -> ArchiveResult2 {
        guard evidence.provider.managedProfilesEnabled else { throw DynamicStoreError.unsupportedProfile }
        try requireQuiescence(evidence)
        guard let profile = try listProfiles().first(where: { $0.id == profileID && !$0.archived }), profile.provider == evidence.provider else { throw DynamicStoreError.invalidMetadata }
        guard !(try hasPendingOperations(provider: profile.provider)) else { throw DynamicStoreError.recoveryRequired }
        var next = profile
        let id = UUID()
        next.receipt = nil; next.pending = nil; next.launchAtLogin = false; next.archiveID = id
        if reset { next.storage = .generated(UUID()); next.storageGeneration = UUID() }
        else { next.archived = true; next.favorite = false; next.shortcut = nil }
        let sourceParts = profile.storage == .legacySecond ? ["Profiles", "b"] : ["Profiles", profile.provider.rawValue, pathsFor(profile).base.lastPathComponent]
        let operation = ArchiveOperation(id: id, before: profile, after: next, hadStorage: try directoryExists(sourceParts))
        try write(operation, ["Metadata", "operations", id.uuidString.lowercased() + ".json"])
        return try finishArchive(operation)
    }
    private func finishArchive(_ operation: ArchiveOperation) throws -> ArchiveResult2 {
        try validate(operation.before); try validate(operation.after)
        guard operation.before.provider.managedProfilesEnabled else { throw DynamicStoreError.unsupportedProfile }
        guard operation.before.id == operation.after.id, operation.before.provider == operation.after.provider,
              operation.before.receipt == nil, operation.before.pending == nil else { throw DynamicStoreError.invalidMetadata }
        var expected = operation.before
        expected.receipt = nil; expected.pending = nil; expected.launchAtLogin = false; expected.archiveID = operation.id
        if operation.after.archived {
            expected.archived = true; expected.favorite = false; expected.shortcut = nil
        } else {
            guard case .generated = operation.after.storage, operation.after.storage != operation.before.storage,
                  operation.after.storageGeneration != operation.before.storageGeneration else { throw DynamicStoreError.invalidMetadata }
            expected.storage = operation.after.storage; expected.storageGeneration = operation.after.storageGeneration
        }
        guard operation.after == expected,
              let current = try listProfiles().first(where: { $0.id == operation.before.id }),
              current == operation.before || current == operation.after else { throw DynamicStoreError.recoveryRequired }
        let source = pathsFor(operation.before).base
        let archiveRoot = root.appendingPathComponent("Profiles/Archived", isDirectory: true)
        guard let archiveDescriptor = try directory(["Profiles", "Archived"], create: true) else { throw DynamicStoreError.unsafePath }
        close(archiveDescriptor)
        let destination = archiveRoot.appendingPathComponent(operation.id.uuidString.lowercased())
        if operation.hadStorage {
            let sourceParts = operation.before.storage == .legacySecond ? ["Profiles", "b"] : ["Profiles", operation.before.provider.rawValue, source.lastPathComponent]
            let destinationParts = ["Profiles", "Archived", destination.lastPathComponent]
            let sourceExists = try directoryExists(sourceParts), destinationExists = try directoryExists(destinationParts)
            guard sourceExists != destinationExists else { throw DynamicStoreError.recoveryRequired }
            if sourceExists {
                // Validate every ancestor, then rename the opaque directory on the same filesystem.
                let parentParts = operation.before.storage == .legacySecond ? ["Profiles"] : ["Profiles", operation.before.provider.rawValue]
                guard let sourceParent = try directory(parentParts, create: false) else { throw DynamicStoreError.unsafePath }
                guard let destinationParent = try directory(["Profiles", "Archived"], create: false) else {
                    close(sourceParent)
                    throw DynamicStoreError.unsafePath
                }
                defer { close(sourceParent); close(destinationParent) }
                guard renameat(sourceParent, source.lastPathComponent, destinationParent, destination.lastPathComponent) == 0,
                      fsync(sourceParent) == 0, fsync(destinationParent) == 0 else { throw DynamicStoreError.writeFailed }
            } else {
                guard let sourceParent = try directory(operation.before.storage == .legacySecond ? ["Profiles"] : ["Profiles", operation.before.provider.rawValue], create: false) else {
                    throw DynamicStoreError.unsafePath
                }
                guard let destinationParent = try directory(["Profiles", "Archived"], create: false) else {
                    close(sourceParent)
                    throw DynamicStoreError.unsafePath
                }
                defer { close(sourceParent); close(destinationParent) }
                guard fsync(sourceParent) == 0, fsync(destinationParent) == 0 else { throw DynamicStoreError.writeFailed }
            }
        } else if try directoryExists(operation.before.storage == .legacySecond ? ["Profiles", "b"] : ["Profiles", operation.before.provider.rawValue, source.lastPathComponent]) ||
                    directoryExists(["Profiles", "Archived", destination.lastPathComponent]) {
            throw DynamicStoreError.recoveryRequired
        }
        try saveProfile(operation.after)
        try removeMetadata(["Metadata", "operations", operation.id.uuidString.lowercased() + ".json"])
        return ArchiveResult2(profile: operation.after, archiveURL: operation.hadStorage ? destination : nil)
    }
    public func recoverArchives(evidence: ProviderQuiescence2) throws {
        guard evidence.provider.managedProfilesEnabled else { throw DynamicStoreError.unsupportedProfile }
        try requireQuiescence(evidence)
        for operation in try operations() where operation.before.provider == evidence.provider { _ = try finishArchive(operation) }
    }
}
