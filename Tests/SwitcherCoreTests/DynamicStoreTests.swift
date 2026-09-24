import XCTest
import Foundation
import Darwin
@testable import SwitcherCore

final class DynamicStoreTests: XCTestCase {
    func testNumericShortcutPolicyReusesFirstFreePhysicalDigitAndStopsAtZero() {
        let slots = NumericShortcutPolicy.keyCodes.map { Shortcut2(keyCode: $0, modifiers: 2304) }
        XCTAssertEqual(slots.count, 10)
        XCTAssertEqual(slots[0], .legacyCurrent)
        XCTAssertEqual(slots[1], .legacySecond)
        XCTAssertEqual(NumericShortcutPolicy.firstAvailable(occupied: Set(slots.prefix(2))), slots[2])
        XCTAssertEqual(NumericShortcutPolicy.firstAvailable(occupied: Set(slots.filter { $0 != slots[1] })), slots[1])
        XCTAssertEqual(slots.last?.keyCode, 29) // physical 0, not a nonexistent ⌥⌘10 chord
        XCTAssertNil(NumericShortcutPolicy.firstAvailable(occupied: Set(slots)))
    }
    private var scratch: URL!
    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("DynamicStoreTests-" + UUID().uuidString, isDirectory: true)
        try PrivateStore.prepareDirectory(scratch)
    }
    override func tearDownWithError() throws {
        // This is exclusively synthetic test data below the repository's ignored work directory.
        if let scratch { try FileManager.default.removeItem(at: scratch) }
    }
    private func openStore(migrate: Bool = true) throws -> DynamicStore {
        let store = try DynamicStore(root: scratch)
        try store.acquireLock()
        if migrate { try store.migrateIfNeeded() }
        return store
    }
    private func openStore(root: URL, failingOnceAt point: ArchiveDurabilityPoint) throws -> DynamicStore {
        var failed = false
        let store = try DynamicStore(root: root) { observed in
            if observed == point, !failed {
                failed = true
                throw DynamicStoreError.writeFailed
            }
        }
        try store.acquireLock()
        try store.migrateIfNeeded()
        return store
    }
    private func fixture<T: Encodable>(_ value: T, at path: String) throws {
        try rawFixture(JSONEncoder().encode(value), at: path)
    }
    private func rawFixture(_ data: Data, at path: String) throws {
        let url = scratch.appendingPathComponent(path)
        try PrivateStore.prepareDirectory(url.deletingLastPathComponent())
        try data.write(to: url)
        XCTAssertEqual(chmod(url.path, 0o600), 0)
    }
    private func path(_ profile: ProfileRecord2) -> String {
        "Metadata/profiles/\(profile.provider.rawValue)/\(profile.id.description).json"
    }
    private func stamp(_ pid: Int32 = 42) -> ProcessStamp {
        ProcessStamp(pid: pid, uid: getuid(), seconds: 1_234, microseconds: 50,
                     executable: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
    }
    private func receipt(for profile: ProfileRecord2, pid: Int32 = 42) -> LaunchReceipt2 {
        LaunchReceipt2(provider: profile.provider, profileID: profile.id, storageGeneration: profile.storageGeneration,
                       stamp: stamp(pid), paths: Paths2(root: scratch, provider: profile.provider, storage: profile.storage),
                       fingerprint: "test-fingerprint")
    }
    private func quiescence(provider: ProviderID2 = .codex) -> ProviderQuiescence2 {
        ProviderQuiescence2(provider: provider, officialProcessCount: 0, hasUnverifiableProcesses: false)
    }

    func testLockIsRequiredAndCompetingControllerCannotAcquireIt() throws {
        let store = try DynamicStore(root: scratch)
        XCTAssertThrowsError(try store.migrateIfNeeded())
        try store.acquireLock()
        let competing = try DynamicStore(root: scratch)
        XCTAssertThrowsError(try competing.acquireLock())
        XCTAssertThrowsError(try store.acquireLock())
    }

    func testFreshMigrationCreatesCurrentConfigurationWithoutPrivateProfileStorage() throws {
        let store = try openStore()
        XCTAssertTrue(try store.listProfiles().isEmpty)
        XCTAssertEqual(try store.loadProvider(.codex).currentShortcut, .legacyCurrent)
        XCTAssertNil(try store.loadProvider(.claude).currentShortcut)
        XCTAssertFalse(try store.loadPreferences().launchSelectedAtLogin)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Profiles").path))
        try store.migrateIfNeeded()
        XCTAssertTrue(try store.listProfiles().isEmpty)
    }

    func testLegacyInvalidProviderPathNeverCommitsSchemaThreeSentinel() throws {
        var legacy = Settings()
        legacy.appPath = "relative/ChatGPT.app"
        try fixture(legacy, at: "settings.json")
        let store = try openStore(migrate: false)
        XCTAssertThrowsError(try store.migrateIfNeeded())
        let sentinel = try Data(contentsOf: scratch.appendingPathComponent("settings.json"))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: sentinel).schemaVersion, Settings.currentSchemaVersion)
        XCTAssertThrowsError(try store.migrateIfNeeded())
    }

    func testLegacyDuplicateCurrentAndSecondNamesNeverCommitMigration() throws {
        var legacy = Settings()
        legacy.nameA = "Same account"
        legacy.nameB = "Same account"
        try fixture(legacy, at: "settings.json")
        try PrivateStore.prepareDirectory(scratch.appendingPathComponent("Profiles/b"))
        let store = try openStore(migrate: false)
        XCTAssertThrowsError(try store.migrateIfNeeded())
        let sentinel = try Data(contentsOf: scratch.appendingPathComponent("settings.json"))
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: sentinel).schemaVersion, Settings.currentSchemaVersion)
    }

    func testLegacyMigrationPreservesOpaqueDirectoriesAndReceiptProvenance() throws {
        var settings = Settings()
        settings.nameA = "Personal"; settings.nameB = "Work"
        settings.approvedFingerprint = "legacy-approved"; settings.setupComplete = true
        try fixture(settings, at: "settings.json")
        let legacyPaths = ProfilePaths(root: scratch, id: .b)
        try fixture([LaunchReceipt(profile: .b, stamp: stamp(), paths: legacyPaths)], at: "receipts.json")
        try fixture([ProfileID.a, .b], at: "pending.json")
        // An unreadable provider file must not be opened or decoded by migration.
        let opaque = scratch.appendingPathComponent("Profiles/b/electron/provider-opaque-data")
        try PrivateStore.prepareDirectory(opaque.deletingLastPathComponent())
        try Data("opaque synthetic marker".utf8).write(to: opaque)
        XCTAssertEqual(chmod(opaque.path, 0o000), 0)
        defer { _ = chmod(opaque.path, 0o600) }
        let legacyA = scratch.appendingPathComponent("Profiles/a")
        try PrivateStore.prepareDirectory(legacyA)

        let store = try openStore()
        let profile = try XCTUnwrap(store.listProfiles().first)
        XCTAssertEqual(profile.id, .legacySecond)
        XCTAssertEqual(profile.storage, .legacySecond)
        XCTAssertEqual(profile.name, "Work")
        XCTAssertEqual(profile.shortcut, .legacySecond)
        XCTAssertFalse(profile.launchAtLogin)
        XCTAssertEqual(profile.receipt?.provenance, .legacy)
        XCTAssertEqual(profile.receipt?.fingerprint, "legacy-approved")
        XCTAssertEqual(profile.receipt?.stamp, stamp())
        XCTAssertEqual(profile.pending?.launchID, profile.receipt?.launchID)
        XCTAssertTrue(profile.pending?.legacy == true)
        XCTAssertEqual(store.paths(for: profile).electron, legacyPaths.electron)
        XCTAssertEqual(store.paths(for: profile).codexHome, legacyPaths.home)
        XCTAssertTrue(FileManager.default.fileExists(atPath: opaque.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacyA.path))
        let migratedSettings = try store.loadProvider(.codex)
        XCTAssertEqual(migratedSettings.currentName, "Personal")
        XCTAssertEqual(migratedSettings.approvedFingerprint, "legacy-approved")
        XCTAssertTrue(migratedSettings.setupComplete)
        XCTAssertFalse(migratedSettings.currentLaunchAtLogin)
        XCTAssertFalse(try store.loadPreferences().launchSelectedAtLogin)
        XCTAssertEqual(try JSONDecoder().decode(Settings.self, from: Data(contentsOf: scratch.appendingPathComponent("Metadata/legacy/settings.json"))), settings)
        try store.migrateIfNeeded()
        XCTAssertEqual(try store.listProfiles(), [profile])
        let sentinel = try JSONDecoder().decode(Settings.self, from: Data(contentsOf: scratch.appendingPathComponent("settings.json")))
        XCTAssertTrue(sentinel.isFromFutureVersion)
    }

    func testSchemaOneWithoutExplicitVersionMigrates() throws {
        try rawFixture(Data(#"{"nameA":"Home","nameB":"Business","setupComplete":false}"#.utf8), at: "settings.json")
        let store = try openStore()
        XCTAssertEqual(try store.loadProvider(.codex).currentName, "Home")
        XCTAssertEqual(try store.listProfiles().first?.name, "Business")
    }

    func testFutureSchemaStopsWithoutWritingMetadata() throws {
        let bytes = Data(#"{"schemaVersion":99,"futureOption":"preserve"}"#.utf8)
        try rawFixture(bytes, at: "settings.json")
        let store = try openStore(migrate: false)
        XCTAssertThrowsError(try store.migrateIfNeeded())
        XCTAssertEqual(try Data(contentsOf: scratch.appendingPathComponent("settings.json")), bytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Metadata").path))
    }

    func testDuplicateLegacyReceiptsAndWrongPathsCannotMigrate() throws {
        try fixture(Settings(), at: "settings.json")
        let legacy = LaunchReceipt(profile: .b, stamp: stamp(), paths: ProfilePaths(root: scratch, id: .b))
        try fixture([legacy, legacy], at: "receipts.json")
        let store = try openStore(migrate: false)
        XCTAssertThrowsError(try store.migrateIfNeeded())
        try fixture([LaunchReceipt(profile: .b, stamp: stamp(), paths: ProfilePaths(root: scratch.appendingPathComponent("elsewhere"), id: .b))], at: "receipts.json")
        XCTAssertThrowsError(try store.migrateIfNeeded())
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Metadata/preferences.json").path))
    }

    func testInterruptedMigrationResumesFromJournalAndKeepsIdentity() throws {
        try fixture(Settings(), at: "settings.json")
        try PrivateStore.prepareDirectory(scratch.appendingPathComponent("Metadata"))
        let blocker = scratch.appendingPathComponent("Metadata/providers")
        let elsewhere = scratch.appendingPathComponent("elsewhere")
        try PrivateStore.prepareDirectory(elsewhere)
        try FileManager.default.createSymbolicLink(at: blocker, withDestinationURL: elsewhere)
        let store = try openStore(migrate: false)
        XCTAssertThrowsError(try store.migrateIfNeeded())
        XCTAssertTrue(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Metadata/migration.json").path))
        let staged = try Data(contentsOf: scratch.appendingPathComponent("Metadata/migration.json"))
        let journal = try XCTUnwrap(JSONSerialization.jsonObject(with: staged) as? [String: Any])
        let stagedProfiles = try XCTUnwrap(journal["profiles"] as? [[String: Any]])
        let generation = try XCTUnwrap(stagedProfiles.first?["storageGeneration"] as? String)
        try FileManager.default.removeItem(at: blocker)
        try store.migrateIfNeeded()
        XCTAssertEqual(try store.listProfiles().first?.storageGeneration.uuidString, generation)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Metadata/migration.json").path))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    func testCreateAndRenameDoNotPrepareOrMoveProviderStorage() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "  Work  ")
        XCTAssertEqual(profile.name, "Work")
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths(for: profile).base.path))
        let oldPaths = store.paths(for: profile)
        profile.name = "Renamed"; profile.favorite = true
        try store.saveProfile(profile)
        XCTAssertEqual(store.paths(for: profile), oldPaths)
        XCTAssertEqual(try store.listProfiles().first, profile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldPaths.base.path))
        XCTAssertThrowsError(try store.createProfile(provider: .claude, name: "Unvalidated"))
    }

    func testNamesAreValidatedAgainstCurrentAndUnicodeEquivalentProfiles() throws {
        let store = try openStore()
        _ = try store.createProfile(provider: .codex, name: "Café")
        for invalid in ["", "\n", "tab\tname", String(repeating: "a", count: 41), "Current account", "CAFE\u{301}"] {
            XCTAssertThrowsError(try store.createProfile(provider: .codex, name: invalid), invalid)
        }
        var current = try store.loadProvider(.codex)
        current.currentName = "CAFÉ"
        XCTAssertThrowsError(try store.saveProvider(current))
    }

    func testDuplicatePIDsAndStorageCannotBeSaved() throws {
        let store = try openStore()
        var first = try store.createProfile(provider: .codex, name: "One")
        first.receipt = receipt(for: first)
        try store.saveProfile(first)
        var second = try store.createProfile(provider: .codex, name: "Two")
        second.receipt = receipt(for: second)
        XCTAssertThrowsError(try store.saveProfile(second))
        second.receipt = nil; second.storage = first.storage
        XCTAssertThrowsError(try store.saveProfile(second))
    }

    func testReceiptGenerationAndPendingLaunchMustMatchRecord() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "Work")
        profile.receipt = receipt(for: profile)
        profile.pending = PendingLaunch2(fingerprint: "test-fingerprint")
        XCTAssertThrowsError(try store.saveProfile(profile))
        profile.pending = nil
        profile.storageGeneration = UUID()
        XCTAssertThrowsError(try store.saveProfile(profile))
    }

    func testUnknownLaunchPoliciesAndMalformedRuntimeAuthorityFailClosed() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "Policy")
        profile.receipt = LaunchReceipt2(provider: profile.provider, profileID: profile.id,
            storageGeneration: profile.storageGeneration, stamp: stamp(),
            paths: Paths2(root: scratch, provider: profile.provider, storage: profile.storage),
            fingerprint: "test-fingerprint", launchPolicyVersion: 2)
        XCTAssertThrowsError(try store.saveProfile(profile))

        profile.receipt = LaunchReceipt2(provider: profile.provider, profileID: profile.id,
            storageGeneration: profile.storageGeneration, stamp: stamp(),
            paths: Paths2(root: scratch, provider: profile.provider, storage: profile.storage),
            fingerprint: nil)
        XCTAssertThrowsError(try store.saveProfile(profile))

        profile.receipt = nil
        profile.pending = PendingLaunch2(fingerprint: "test-fingerprint", launchPolicyVersion: 2)
        XCTAssertThrowsError(try store.saveProfile(profile))
    }

    func testPersistedDuplicateNamesAndInvalidShortcutsFailClosedOnLoad() throws {
        let store = try openStore()
        let first = try store.createProfile(provider: .codex, name: "First")
        var second = try store.createProfile(provider: .codex, name: "Second")
        second.name = first.name
        try fixture(second, at: path(second))
        XCTAssertThrowsError(try store.listProfiles())

        second.name = "Second"
        second.shortcut = Shortcut2(keyCode: 200, modifiers: 0)
        try fixture(second, at: path(second))
        XCTAssertThrowsError(try store.listProfiles())
    }

    func testArchiveRefusesUnknownProviderStorageAndExtremeOrdering() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "Bounded")
        profile.order = Int.max
        XCTAssertThrowsError(try store.saveProfile(profile))

        profile = try XCTUnwrap(try store.listProfiles().first { $0.name == "Bounded" })
        let orphan = scratch.appendingPathComponent("Profiles/codex/orphan", isDirectory: true)
        try PrivateStore.prepareDirectory(orphan)
        XCTAssertThrowsError(try store.archive(profileID: profile.id, reset: false, evidence: quiescence()))
        XCTAssertThrowsError(try store.recoverArchives(evidence: quiescence()))
        XCTAssertFalse(try XCTUnwrap(try store.listProfiles().first { $0.id == profile.id }).archived)
    }

    func testUnsafeProfileMetadataIsRejectedOnRead() throws {
        let store = try openStore()
        let profile = try store.createProfile(provider: .codex, name: "One")
        let file = scratch.appendingPathComponent(path(profile))
        XCTAssertEqual(chmod(file.path, 0o644), 0)
        XCTAssertThrowsError(try store.listProfiles())
        XCTAssertEqual(chmod(file.path, 0o600), 0)
        let hardlink = scratch.appendingPathComponent("hardlinked-copy")
        XCTAssertEqual(link(file.path, hardlink.path), 0)
        XCTAssertThrowsError(try store.listProfiles())
        try FileManager.default.removeItem(at: hardlink)
        try FileManager.default.removeItem(at: file)
        let outside = scratch.appendingPathComponent("external-metadata")
        try fixture(profile, at: "external-metadata")
        try FileManager.default.createSymbolicLink(at: file, withDestinationURL: outside)
        XCTAssertThrowsError(try store.listProfiles())
    }

    func testReplacedOrExposedRootCannotBeUsedUnderOldControllerLock() throws {
        let store = try openStore()
        XCTAssertEqual(chmod(scratch.path, 0o755), 0)
        XCTAssertThrowsError(try store.loadPreferences())
        XCTAssertEqual(chmod(scratch.path, 0o700), 0)
        let moved = scratch.appendingPathExtension("moved")
        try FileManager.default.moveItem(at: scratch, to: moved)
        defer { try? FileManager.default.removeItem(at: moved) }
        try PrivateStore.prepareDirectory(scratch)
        try fixture(Preferences2(), at: "Metadata/preferences.json")
        XCTAssertThrowsError(try store.loadPreferences())
        XCTAssertThrowsError(try store.savePreferences(Preferences2()))
    }

    func testInvalidPersistedPreferencesAndProviderPathsFailClosed() throws {
        let store = try openStore()
        var preferences = Preferences2(); preferences.language = "unsupported-language"
        try fixture(preferences, at: "Metadata/preferences.json")
        XCTAssertThrowsError(try store.loadPreferences())
        try fixture(Preferences2(), at: "Metadata/preferences.json")
        var provider = ProviderSettings2(provider: .codex); provider.appPath = "relative/ChatGPT.app"
        try fixture(provider, at: "Metadata/providers/codex.json")
        XCTAssertThrowsError(try store.loadProvider(.codex))
    }

    func testMetadataLimitAppliesPerRecordAndRejectsOversizedReadAndWrite() throws {
        let store = try openStore()
        let profile = try store.createProfile(provider: .codex, name: "One")
        try rawFixture(Data(repeating: 0x20, count: 65_537), at: path(profile))
        XCTAssertThrowsError(try store.listProfiles())
        try fixture(profile, at: path(profile))
        var provider = try store.loadProvider(.codex)
        provider.approvedFingerprint = String(repeating: "x", count: 65_537)
        XCTAssertThrowsError(try store.saveProvider(provider))
        XCTAssertNil(try store.loadProvider(.codex).approvedFingerprint)
    }

    func testStoragePreparationRejectsRedirectedAncestor() throws {
        let store = try openStore()
        let profile = try store.createProfile(provider: .codex, name: "One")
        let redirect = scratch.appendingPathComponent("outside")
        try PrivateStore.prepareDirectory(redirect)
        try FileManager.default.createSymbolicLink(at: scratch.appendingPathComponent("Profiles"), withDestinationURL: redirect)
        XCTAssertThrowsError(try store.prepareStorage(for: profile))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: redirect.path).isEmpty)
    }

    func testArchiveRejectsProcessesPendingReceiptsAndStaleEvidence() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "One")
        _ = try store.prepareStorage(for: profile)
        for evidence in [
            ProviderQuiescence2(provider: .codex, officialProcessCount: 1, hasUnverifiableProcesses: false),
            ProviderQuiescence2(provider: .codex, officialProcessCount: 0, hasUnverifiableProcesses: true),
            ProviderQuiescence2(provider: .codex, observedAt: Date(timeIntervalSinceNow: -60), officialProcessCount: 0, hasUnverifiableProcesses: false),
            ProviderQuiescence2(provider: .codex, observedAt: Date(timeIntervalSinceNow: 60), officialProcessCount: 0, hasUnverifiableProcesses: false),
            quiescence(provider: .claude)
        ] { XCTAssertThrowsError(try store.archive(profileID: profile.id, reset: true, evidence: evidence)) }
        profile.pending = PendingLaunch2(fingerprint: "test-fingerprint")
        try store.saveProfile(profile)
        XCTAssertThrowsError(try store.archive(profileID: profile.id, reset: true, evidence: quiescence()))
        profile.pending = nil; profile.receipt = receipt(for: profile)
        try store.saveProfile(profile)
        XCTAssertThrowsError(try store.archive(profileID: profile.id, reset: true, evidence: quiescence()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths(for: profile).base.path))
    }

    func testStoppedResidualClaudeProfilesCannotBeArchivedOrResetOrMoveStorage() throws {
        let store = try openStore()
        for (index, reset) in [false, true].enumerated() {
            let profile = ProfileRecord2(provider: .claude, name: reset ? "Claude reset" : "Claude archive")
            try store.saveProfile(profile)
            let paths = store.paths(for: profile)
            try PrivateStore.prepareDirectory(paths.electron)
            let marker = paths.electron.appendingPathComponent("opaque-marker-\(index)")
            try Data("must stay in place".utf8).write(to: marker)

            XCTAssertThrowsError(try store.archive(profileID: profile.id, reset: reset,
                evidence: quiescence(provider: .claude)))

            let durable = try XCTUnwrap(try store.listProfiles(provider: .claude).first { $0.id == profile.id })
            XCTAssertEqual(durable, profile)
            XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        }
    }

    func testResetArchivesOpaqueContentsAndAllocatesNewStorageGeneration() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "One")
        profile.favorite = true; profile.shortcut = .legacySecond; profile.launchAtLogin = true
        try store.saveProfile(profile)
        let paths = try store.prepareStorage(for: profile)
        let synthetic = paths.electron.appendingPathComponent("synthetic-opaque")
        try Data("preserve me".utf8).write(to: synthetic)
        XCTAssertEqual(chmod(synthetic.path, 0o000), 0)
        let result = try store.archive(profileID: profile.id, reset: true, evidence: quiescence())
        let archive = try XCTUnwrap(result.archiveURL)
        let moved = archive.appendingPathComponent("electron/synthetic-opaque")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        XCTAssertEqual(chmod(moved.path, 0o600), 0)
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "preserve me")
        XCTAssertEqual(result.profile.id, profile.id)
        XCTAssertEqual(result.profile.name, profile.name)
        XCTAssertTrue(result.profile.favorite)
        XCTAssertEqual(result.profile.shortcut, profile.shortcut)
        XCTAssertFalse(result.profile.launchAtLogin)
        XCTAssertNotEqual(result.profile.storageGeneration, profile.storageGeneration)
        XCTAssertNotEqual(result.profile.storage, profile.storage)
        XCTAssertFalse(result.profile.archived)
        XCTAssertFalse(FileManager.default.fileExists(atPath: paths.base.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.paths(for: result.profile).base.path))
        XCTAssertFalse(try store.hasPendingOperations(provider: .codex))
        XCTAssertEqual(try store.listProfiles(), [result.profile])
    }

    func testDeleteArchivesInsteadOfDeletingAndDisablesEntryPoints() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "One")
        profile.favorite = true; profile.shortcut = .legacySecond; profile.launchAtLogin = true
        try store.saveProfile(profile)
        _ = try store.prepareStorage(for: profile)
        let result = try store.archive(profileID: profile.id, reset: false, evidence: quiescence())
        XCTAssertTrue(result.profile.archived)
        XCTAssertFalse(result.profile.favorite)
        XCTAssertFalse(result.profile.launchAtLogin)
        XCTAssertNil(result.profile.shortcut)
        XCTAssertTrue(FileManager.default.fileExists(atPath: try XCTUnwrap(result.archiveURL).path))
        XCTAssertThrowsError(try store.prepareStorage(for: result.profile))
        XCTAssertThrowsError(try store.archive(profileID: profile.id, reset: false, evidence: quiescence()))
    }

    func testArchiveWithoutStorageStillProducesDurableArchivedMetadata() throws {
        let store = try openStore()
        let profile = try store.createProfile(provider: .codex, name: "Unused")
        let result = try store.archive(profileID: profile.id, reset: false, evidence: quiescence())
        XCTAssertNil(result.archiveURL)
        XCTAssertTrue(result.profile.archived)
        XCTAssertEqual(try store.listProfiles(), [result.profile])
    }

    private struct ArchiveFixture: Codable {
        let id: UUID
        let before: ProfileRecord2
        let after: ProfileRecord2
        let hadStorage: Bool
    }
    private func archiveJournal(before: ProfileRecord2, hadStorage: Bool) -> ArchiveFixture {
        let operationID = UUID()
        var next = before
        next.receipt = nil; next.pending = nil; next.launchAtLogin = false; next.archiveID = operationID
        next.storage = .generated(UUID()); next.storageGeneration = UUID()
        return ArchiveFixture(id: operationID, before: before, after: next, hadStorage: hadStorage)
    }
    private func journalPath(_ operation: ArchiveFixture) -> String {
        "Metadata/operations/" + operation.id.uuidString.lowercased() + ".json"
    }

    func testArchiveRecoveryAfterRenameAndAfterMetadataCommitIsIdempotent() throws {
        let store = try openStore()
        let profile = try store.createProfile(provider: .codex, name: "One")
        let original = try store.prepareStorage(for: profile)
        let journal = archiveJournal(before: profile, hadStorage: true)
        try fixture(journal, at: journalPath(journal))
        let archive = scratch.appendingPathComponent("Profiles/Archived/" + journal.id.uuidString.lowercased())
        try PrivateStore.prepareDirectory(archive.deletingLastPathComponent())
        try FileManager.default.moveItem(at: original.base, to: archive)
        // Simulates a process interruption after rename but before committing profile metadata.
        XCTAssertTrue(try store.hasPendingOperations(provider: .codex))
        try store.recoverArchives(evidence: quiescence())
        XCTAssertEqual(try store.listProfiles(), [journal.after])
        XCTAssertFalse(try store.hasPendingOperations(provider: .codex))
        // Simulates an interruption after durable metadata and before journal cleanup.
        try fixture(journal, at: journalPath(journal))
        try store.recoverArchives(evidence: quiescence())
        XCTAssertEqual(try store.listProfiles(), [journal.after])
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(try store.hasPendingOperations(provider: .codex))
    }

    func testInjectedArchiveDurabilityFailuresRemainRecoverable() throws {
        for point in ArchiveDurabilityPoint.allCases {
            let caseRoot = scratch.appendingPathComponent(String(describing: point), isDirectory: true)
            try PrivateStore.prepareDirectory(caseRoot)

            let store = try openStore(root: caseRoot, failingOnceAt: point)
            let profile = try store.createProfile(provider: .codex, name: "Durability fixture")
            let paths = try store.prepareStorage(for: profile)
            let marker = paths.codexHome.appendingPathComponent("opaque-marker")
            try Data("preserve".utf8).write(to: marker)
            XCTAssertThrowsError(try store.archive(profileID: profile.id, reset: true, evidence: quiescence()), "\(point)")
            XCTAssertTrue(try store.hasPendingOperations(provider: .codex), "\(point)")

            try store.recoverArchives(evidence: quiescence())
            let recovered = try XCTUnwrap(store.listProfiles().first)
            XCTAssertEqual(recovered.id, profile.id, "\(point)")
            XCTAssertNotEqual(recovered.storage, profile.storage, "\(point)")
            XCTAssertFalse(try store.hasPendingOperations(provider: .codex), "\(point)")
            let archives = try FileManager.default.contentsOfDirectory(
                at: caseRoot.appendingPathComponent("Profiles/Archived"),
                includingPropertiesForKeys: nil
            )
            XCTAssertEqual(archives.count, 1, "\(point)")
            XCTAssertEqual(try String(contentsOf: archives[0].appendingPathComponent("codex/opaque-marker"), encoding: .utf8), "preserve", "\(point)")
        }
    }

    func testArchiveRecoveryDoesNotOverwriteDivergentProfileMetadata() throws {
        let store = try openStore()
        var profile = try store.createProfile(provider: .codex, name: "One")
        let journal = archiveJournal(before: profile, hadStorage: false)
        try fixture(journal, at: journalPath(journal))
        profile.name = "Changed since the journal"
        try fixture(profile, at: path(profile))
        XCTAssertThrowsError(try store.recoverArchives(evidence: quiescence()))
        XCTAssertEqual(try store.listProfiles(), [profile])
        XCTAssertTrue(try store.hasPendingOperations(provider: .codex))
    }

    func testArchiveRecoveryRejectsForgedTransitionAndBothExistingLocations() throws {
        let store = try openStore()
        let profile = try store.createProfile(provider: .codex, name: "One")
        _ = try store.prepareStorage(for: profile)
        let valid = archiveJournal(before: profile, hadStorage: true)
        var forgedAfter = valid.after; forgedAfter.name = "Unauthorized rename"
        let forged = ArchiveFixture(id: valid.id, before: profile, after: forgedAfter, hadStorage: true)
        try fixture(forged, at: journalPath(forged))
        XCTAssertThrowsError(try store.recoverArchives(evidence: quiescence()))
        XCTAssertEqual(try store.listProfiles(), [profile])
        try fixture(valid, at: journalPath(valid))
        let archive = scratch.appendingPathComponent("Profiles/Archived/" + valid.id.uuidString.lowercased())
        try PrivateStore.prepareDirectory(archive)
        XCTAssertThrowsError(try store.recoverArchives(evidence: quiescence()))
        XCTAssertTrue(FileManager.default.fileExists(atPath: store.paths(for: profile).base.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
    }

    func testOrphanDetectionEnumeratesDirectoryNamesOnly() throws {
        let store = try openStore()
        let profile = try store.createProfile(provider: .codex, name: "One")
        _ = try store.prepareStorage(for: profile)
        XCTAssertFalse(try store.hasOrphanStorage(provider: .codex, records: [profile]))
        try PrivateStore.prepareDirectory(scratch.appendingPathComponent("Profiles/codex/" + UUID().uuidString.lowercased()))
        XCTAssertTrue(try store.hasOrphanStorage(provider: .codex, records: [profile]))
        XCTAssertFalse(try store.hasOrphanStorage(provider: .claude, records: [profile]))
    }

    func testExportContainsOnlyConfigurationWithoutRuntimeAuthority() throws {
        var preferences = Preferences2(); preferences.language = "spanish"
        var provider = ProviderSettings2(provider: .codex)
        provider.appPath = "/Users/Sensitive/Secret.app"; provider.approvedFingerprint = "PRIVATE-FINGERPRINT"
        var profile = ProfileRecord2(provider: .codex, name: "Display name")
        profile.receipt = receipt(for: profile)
        profile.pending = PendingLaunch2(fingerprint: "SECRET-PENDING")
        var archived = ProfileRecord2(provider: .codex, name: "Archived secret label")
        archived.archived = true
        let export = ConfigurationExport2(preferences: preferences, providers: [provider], profiles: [profile, archived])
        let text = String(decoding: try export.jsonData(), as: UTF8.self)
        XCTAssertTrue(text.contains("Display name"))
        for excluded in ["Sensitive", "PRIVATE-FINGERPRINT", "SECRET-PENDING", "Archived secret label", "receipt", "pending", "storageGeneration", "appPath", "stamp", "executable", "codexHome", scratch.path] {
            XCTAssertFalse(text.contains(excluded), excluded)
        }
        XCTAssertEqual(try JSONDecoder().decode(ConfigurationExport2.self, from: export.jsonData()), export)
    }

    func testOneThousandIndependentProfilesExceedLegacyAggregateSizeWithoutCountLimit() throws {
        let store = try openStore()
        var totalBytes = 0
        // Fixture injection avoids benchmarking 1,000 UI writes; it exercises the persisted layout,
        // bounded decoder, duplicate checks, ordering and subsequent mutation of a large library.
        for index in 0..<1_000 {
            var profile = ProfileRecord2(provider: .codex, name: "Synthetic \(index)")
            profile.order = index
            let data = try JSONEncoder().encode(profile)
            totalBytes += data.count
            try rawFixture(data, at: path(profile))
        }
        XCTAssertGreaterThan(totalBytes, 65_536)
        let profiles = try store.listProfiles()
        XCTAssertEqual(profiles.count, 1_000)
        XCTAssertEqual(Set(profiles.map(\.id)).count, 1_000)
        XCTAssertEqual(profiles.first?.order, 0)
        XCTAssertEqual(profiles.last?.order, 999)
        var last = try XCTUnwrap(profiles.last); last.name = "Updated final entry"
        try store.saveProfile(last)
        XCTAssertEqual(try store.listProfiles().last?.name, last.name)
        XCTAssertFalse(FileManager.default.fileExists(atPath: scratch.appendingPathComponent("Profiles").path))
    }
}
