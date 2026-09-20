import Foundation

/// Provider identity is independent of installation paths, profile names and processes.
public enum ProviderID2: String, Codable, CaseIterable, Hashable {
    case codex, claude
    public var bundleIdentifier: String { self == .codex ? "com.openai.codex" : "com.anthropic.claudefordesktop" }
    public var teamIdentifier: String { self == .codex ? "2DC432GLL2" : "Q6L2SF6YDW" }
    public var defaultAppPath: String { self == .codex ? "/Applications/ChatGPT.app" : "/Applications/Claude.app" }
    /// Central production gate for every managed-profile action. Claude stays
    /// Current-only until its real Chat, Code and Cowork acceptance gates pass.
    public var managedProfilesEnabled: Bool { self == .codex }
}

public struct ManagedProfileID: Codable, Hashable, Identifiable, CustomStringConvertible {
    public let rawValue: UUID
    public init(_ rawValue: UUID = UUID()) { self.rawValue = rawValue }
    public var id: UUID { rawValue }
    public var description: String { rawValue.uuidString.lowercased() }
    public static let legacySecond = ManagedProfileID(UUID(uuidString: "00000000-0000-4000-8000-000000000002")!)
}

/// Current has no profile record, private directory or ownership receipt.
public enum AccountTarget2: Codable, Hashable {
    case current(ProviderID2)
    case managed(ManagedProfileID)
}

public struct Shortcut2: Codable, Equatable, Hashable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    public var isValid: Bool {
        let supported: UInt32 = 0x1B00 // command, shift, option, control
        let required: UInt32 = 0x1900 // command, option, or control
        return keyCode <= 127 && keyCode != 53 && modifiers & ~supported == 0 && modifiers & required != 0
    }
    // Carbon's constants are intentionally represented without importing UI frameworks into core.
    public static let legacyCurrent = Shortcut2(keyCode: 18, modifiers: 2304)
    public static let legacySecond = Shortcut2(keyCode: 19, modifiers: 2304)
}

public struct Preferences2: Codable, Equatable {
    public static let currentSchemaVersion = 3
    public var schemaVersion = Self.currentSchemaVersion
    public var language: String = "system"
    public var launchSelectedAtLogin = false
    public var welcomeDismissed = false
    public init() {}
}

public struct ProviderSettings2: Codable, Equatable {
    public var provider: ProviderID2
    public var currentName = "Current account"
    public var currentFavorite = true
    public var currentOrder = 0
    public var currentShortcut: Shortcut2?
    public var currentLaunchAtLogin = false
    public var appPath: String
    public var approvedFingerprint: String?
    public var setupComplete = false
    public init(provider: ProviderID2) {
        self.provider = provider; self.appPath = provider.defaultAppPath
        if provider == .codex { currentShortcut = .legacyCurrent }
    }
}

public enum StorageLocator2: Codable, Equatable, Hashable {
    case legacySecond
    case generated(UUID)
}

public struct Paths2: Equatable {
    public let base: URL
    public let electron: URL
    public let codexHome: URL
    public let claudeConfig: URL
    public let claudeSecureStorage: URL
    public var home: URL { codexHome }
    public init(root: URL, provider: ProviderID2, storage: StorageLocator2) {
        switch storage {
        case .legacySecond: base = root.appendingPathComponent("Profiles/b", isDirectory: true)
        case .generated(let id):
            base = root.appendingPathComponent("Profiles/\(provider.rawValue)/\(id.uuidString.lowercased())", isDirectory: true)
        }
        electron = base.appendingPathComponent("electron", isDirectory: true)
        codexHome = base.appendingPathComponent("codex", isDirectory: true)
        claudeConfig = base.appendingPathComponent("claude-config", isDirectory: true)
        claudeSecureStorage = base.appendingPathComponent("claude-secure-storage", isDirectory: true)
    }
}

public enum ReceiptProvenance2: String, Codable { case runtime, legacy }

public struct LaunchReceipt2: Codable, Equatable {
    public var schemaVersion = 1
    public let provider: ProviderID2
    public let profileID: ManagedProfileID
    public let storageGeneration: UUID
    public let launchID: UUID
    public let stamp: ProcessStamp
    public let electron: String
    public let codexHome: String
    public let bundleIdentifier: String
    public let teamIdentifier: String
    public let fingerprint: String?
    public let launchPolicyVersion: Int
    public let provenance: ReceiptProvenance2
    public init(provider: ProviderID2, profileID: ManagedProfileID, storageGeneration: UUID,
                launchID: UUID = UUID(), stamp: ProcessStamp, paths: Paths2,
                fingerprint: String?, launchPolicyVersion: Int = 1, provenance: ReceiptProvenance2 = .runtime) {
        self.provider = provider; self.profileID = profileID; self.storageGeneration = storageGeneration
        self.launchID = launchID; self.stamp = stamp; electron = paths.electron.path; codexHome = paths.codexHome.path
        bundleIdentifier = provider.bundleIdentifier; teamIdentifier = provider.teamIdentifier
        self.fingerprint = fingerprint; self.launchPolicyVersion = launchPolicyVersion; self.provenance = provenance
    }

    public func owns(_ stamp: ProcessStamp, profile: ProfileRecord2, paths: Paths2, uid: UInt32) -> Bool {
        schemaVersion == 1 && launchPolicyVersion == 1 && profileID == profile.id && provider == profile.provider &&
        storageGeneration == profile.storageGeneration && self.stamp == stamp && stamp.pid > 0 && stamp.uid == uid &&
        electron == paths.electron.path && codexHome == paths.codexHome.path &&
        bundleIdentifier == provider.bundleIdentifier && teamIdentifier == provider.teamIdentifier
    }
}

public struct PendingLaunch2: Codable, Equatable {
    public let launchID: UUID
    public let startedAt: Date
    public let fingerprint: String?
    public let launchPolicyVersion: Int
    public let legacy: Bool
    public init(launchID: UUID = UUID(), startedAt: Date = Date(), fingerprint: String?,
                launchPolicyVersion: Int = 1, legacy: Bool = false) {
        self.launchID = launchID; self.startedAt = startedAt; self.fingerprint = fingerprint
        self.launchPolicyVersion = launchPolicyVersion; self.legacy = legacy
    }
}

public struct ProfileRecord2: Codable, Equatable, Identifiable {
    public var schemaVersion = 1
    public let id: ManagedProfileID
    public let provider: ProviderID2
    public var name: String
    public var favorite = false
    public var order = 0
    public var shortcut: Shortcut2?
    public var launchAtLogin = false
    public var storage: StorageLocator2
    public var storageGeneration: UUID
    public var receipt: LaunchReceipt2?
    public var pending: PendingLaunch2?
    public var archived = false
    public var archiveID: UUID?
    public init(id: ManagedProfileID = ManagedProfileID(), provider: ProviderID2, name: String,
                storage: StorageLocator2? = nil, storageGeneration: UUID = UUID()) {
        self.id = id; self.provider = provider; self.name = name
        self.storage = storage ?? .generated(UUID()); self.storageGeneration = storageGeneration
    }
}

/// No optional process identity is used: inability to inspect cannot be mistaken for absence.
public enum ProcessObservation2: Equatable {
    case absent
    case unreadable
    case verified(ProcessStamp)
}

public enum ManagedState2: Equatable {
    case stopped, launching, quitting, ownershipUncertain, unverifiedLiveProcess, archived
    case runningVerified(pid: Int32)
    public var needsRecovery: Bool {
        self == .ownershipUncertain || self == .unverifiedLiveProcess
    }
    public var verifiedPID: Int32? { if case .runningVerified(let pid) = self { return pid }; return nil }
}

public enum CurrentState2: Equatable {
    case stopped, launching
    case running(pid: Int32)
    case ambiguous(count: Int)
    case blockedByRecovery
}

public struct ProviderState2: Equatable {
    public let current: CurrentState2
    public let profiles: [ManagedProfileID: ManagedState2]
    public let needsRecovery: Bool
}

/// Only the caller can observe running apps. This narrowly scoped, expiring evidence is required
/// in addition to clean durable receipts/pending records before a whole directory is archived.
public struct ProviderQuiescence2 {
    public let provider: ProviderID2
    public let observedAt: Date
    public let officialProcessCount: Int
    public let hasUnverifiableProcesses: Bool
    public init(provider: ProviderID2, observedAt: Date = Date(), officialProcessCount: Int,
                hasUnverifiableProcesses: Bool) {
        self.provider = provider; self.observedAt = observedAt; self.officialProcessCount = officialProcessCount
        self.hasUnverifiableProcesses = hasUnverifiableProcesses
    }
}

public struct ArchiveResult2 {
    public let profile: ProfileRecord2
    public let archiveURL: URL?
}

/// Export deliberately has no paths, process receipts, journals, fingerprints or private data.
public struct ConfigurationExport2: Codable, Equatable {
    public struct Provider: Codable, Equatable {
        public let provider: ProviderID2
        public let currentName: String
        public let favorite: Bool
        public let order: Int
        public let shortcut: Shortcut2?
        public let launchAtLogin: Bool
    }
    public struct Profile: Codable, Equatable {
        public let provider: ProviderID2
        public let name: String
        public let favorite: Bool
        public let order: Int
        public let shortcut: Shortcut2?
        public let launchAtLogin: Bool
    }
    public let exportVersion: Int
    public let language: String
    public let launchSelectedAtLogin: Bool
    public let providers: [Provider]
    public let profiles: [Profile]
    public init(preferences: Preferences2, providers: [ProviderSettings2], profiles: [ProfileRecord2]) {
        exportVersion = 1; language = preferences.language; launchSelectedAtLogin = preferences.launchSelectedAtLogin
        self.providers = providers.map { Provider(provider: $0.provider, currentName: $0.currentName,
            favorite: $0.currentFavorite, order: $0.currentOrder, shortcut: $0.currentShortcut, launchAtLogin: $0.currentLaunchAtLogin) }
        self.profiles = profiles.filter { !$0.archived }.map { Profile(provider: $0.provider, name: $0.name,
            favorite: $0.favorite, order: $0.order, shortcut: $0.shortcut, launchAtLogin: $0.launchAtLogin) }
    }
    public func jsonData() throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(self)
    }
}
