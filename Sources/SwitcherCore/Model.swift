import Foundation
import Darwin
import ProcessIdentity

public enum SwitcherError: LocalizedError {
    case message(String)
    public var errorDescription: String? { if case let .message(text) = self { return text }; return nil }
}

/// Kept Codable for backwards-compatible metadata. `.a` means the existing/default account;
/// `.b` means the switcher-isolated secondary account.
public enum ProfileID: String, Codable, CaseIterable { case a, b }

public extension ProfileID {
    var isCurrent: Bool { self == .a }
    var isSecondary: Bool { self == .b }
}

/// Private paths are meaningful only for the isolated secondary account. The type still accepts
/// an ID so legacy receipts can be decoded/migrated without touching their directories.
public struct ProfilePaths: Equatable {
    public let home: URL
    public let electron: URL
    public init(root: URL, id: ProfileID) {
        let base = root.appendingPathComponent("Profiles/" + id.rawValue, isDirectory: true)
        home = base.appendingPathComponent("codex", isDirectory: true)
        electron = base.appendingPathComponent("electron", isDirectory: true)
    }
}

/// Launch plan for an isolated account. Current/default ChatGPT must be launched without this plan.
public struct LaunchPlan {
    public let arguments: [String]
    public let environment: [String: String]
    public init(paths: ProfilePaths, userHome: URL, username: String, temporaryDirectory: String) {
        arguments = ["--user-data-dir=" + paths.electron.path]
        // Explicit allowlist: never forward API keys, tokens, CODEX_HOME, NODE_OPTIONS,
        // DYLD_* or Electron debugging flags from the switcher's environment.
        environment = ["HOME": userHome.path, "USER": username, "LOGNAME": username,
                       "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporaryDirectory,
                       "CODEX_HOME": paths.home.path,
                       "CODEX_ELECTRON_USER_DATA_PATH": paths.electron.path]
    }
}

public struct ProcessStamp: Codable, Equatable {
    public let pid: Int32
    public let uid: UInt32
    public let seconds: UInt64
    public let microseconds: UInt64
    public let executable: String
    public init(pid: Int32, uid: UInt32, seconds: UInt64, microseconds: UInt64, executable: String) {
        self.pid = pid; self.uid = uid; self.seconds = seconds
        self.microseconds = microseconds; self.executable = executable
    }
    public var startTime: TimeInterval { Double(seconds) + Double(microseconds) / 1_000_000 }
    public static func read(pid: Int32) -> ProcessStamp? {
        var snapshot = DAProcessSnapshot()
        guard da_snapshot(pid, &snapshot) == 1 else { return nil }
        let path = withUnsafePointer(to: &snapshot.executable) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
        }
        return ProcessStamp(pid: pid, uid: snapshot.uid, seconds: snapshot.seconds,
                            microseconds: snapshot.microseconds, executable: path)
    }
}

public struct LaunchReceipt: Codable, Equatable {
    public let profile: ProfileID
    public let stamp: ProcessStamp
    public let home: String
    public let electron: String
    public init(profile: ProfileID, stamp: ProcessStamp, paths: ProfilePaths) {
        self.profile = profile; self.stamp = stamp; home = paths.home.path; electron = paths.electron.path
    }
    public func owns(_ current: ProcessStamp?, paths: ProfilePaths, uid: UInt32) -> Bool {
        guard profile == .b, let current, stamp.pid > 0, stamp.uid == uid else { return false }
        return current == stamp && home == paths.home.path && electron == paths.electron.path
    }
    public static func canAdopt(_ stamp: ProcessStamp, launchedAfter: TimeInterval,
                                executable: String, uid: UInt32, existingPIDs: Set<Int32>) -> Bool {
        stamp.pid > 0 && stamp.uid == uid && stamp.executable == executable &&
        stamp.startTime >= launchedAfter && !existingPIDs.contains(stamp.pid)
    }
}

/// Settings use an explicit decoder instead of synthesized Codable so adding optional/defaulted
/// fields in future releases does not make an older settings.json unreadable.
public struct Settings: Codable, Equatable {
    public static let currentSchemaVersion = 2

    public var schemaVersion: Int
    public var appPath: String
    public var nameA: String
    public var nameB: String
    public var approvedFingerprint: String?
    public var setupComplete: Bool

    public init() {
        schemaVersion = Self.currentSchemaVersion
        appPath = "/Applications/ChatGPT.app"
        nameA = "Current account"
        nameB = "Second account"
        approvedFingerprint = nil
        setupComplete = false
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, appPath, nameA, nameB, approvedFingerprint, setupComplete
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        appPath = try container.decodeIfPresent(String.self, forKey: .appPath) ?? "/Applications/ChatGPT.app"
        nameA = try container.decodeIfPresent(String.self, forKey: .nameA) ?? "Current account"
        nameB = try container.decodeIfPresent(String.self, forKey: .nameB) ?? "Second account"
        approvedFingerprint = try container.decodeIfPresent(String.self, forKey: .approvedFingerprint)
        setupComplete = try container.decodeIfPresent(Bool.self, forKey: .setupComplete) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(Self.currentSchemaVersion, forKey: .schemaVersion)
        try container.encode(appPath, forKey: .appPath)
        try container.encode(nameA, forKey: .nameA)
        try container.encode(nameB, forKey: .nameB)
        try container.encodeIfPresent(approvedFingerprint, forKey: .approvedFingerprint)
        try container.encode(setupComplete, forKey: .setupComplete)
    }

    public func name(_ id: ProfileID) -> String { id == .a ? nameA : nameB }

    public var needsSchemaRewrite: Bool { schemaVersion < Self.currentSchemaVersion }
    public var isFromFutureVersion: Bool { schemaVersion > Self.currentSchemaVersion }
}
