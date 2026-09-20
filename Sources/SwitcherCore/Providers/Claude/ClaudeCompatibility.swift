import Foundation
import Security
import CryptoKit
import Darwin

public enum ClaudeCapability: String, Codable, CaseIterable, Sendable {
    case chat, code, cowork
}

public struct ClaudeCapabilityStatus: Equatable, Sendable {
    public let capability: ClaudeCapability
    public let status: String
    public let evidenceRequired: String
}

/// Codes, not extracted provider source, paths, account identifiers, or arbitrary errors.
public enum ClaudeSafetyFinding: String, Codable, CaseIterable, Sendable {
    case runtimeSeparationUnproven
    case userDataOverrideMarkerMissing
    case configOverrideMarkerMissing
    case secureStorageOverrideMarkerMissing
    case userDataOverrideDeletedByEntrypoint
    case localPairingAffectedByRelocation
    case configurationAndAuthenticationMayBeShared
    case oauthRoutingUnproven
    case coworkIsolationUnproven
    case prohibitedLaunchArguments
    case unreviewedEnvironmentKeys
}

public struct ClaudeCompatibilityReport {
    public let identity: OfficialAppIdentity
    public let fingerprint: String
    public let findings: [ClaudeSafetyFinding]
    public var app: URL { identity.app }
    public var executable: URL { identity.executable }
    public var version: String { identity.version }
    /// Deliberately not persisted or user-overridable. Static checks cannot establish isolation.
    public var managedLaunchAllowed: Bool { false }
    public var capabilities: [ClaudeCapabilityStatus] { ClaudeCompatibility.capabilities }
    public var summary: String {
        "Anthropic signature verified · version \(version)\nManaged Claude profiles are unavailable: signed-in Chat and Code separation has not been demonstrated. Cowork remains unvalidated.\nBuild fingerprint: \(fingerprint)"
    }
}

public enum ClaudeCompatibility {
    public static let bundleIdentifier = "com.anthropic.claudefordesktop"
    public static let expectedTeamIdentifier = "Q6L2SF6YDW"
    public static let launchPolicyVersion = 1
    public static let capabilities: [ClaudeCapabilityStatus] = [
        .init(capability: .chat, status: "unvalidated", evidenceRequired: "Separate signed-in sessions, persistence, logout independence and OAuth routing."),
        .init(capability: .code, status: "unvalidated", evidenceRequired: "Desktop Code account separation, configuration propagation and independent resume."),
        .init(capability: .cowork, status: "unvalidated", evidenceRequired: "Local/cloud state, credentials, connectors, pairing and any Chat integration.")
    ]

    /// Current needs genuine app identity only. It receives no private paths or ownership receipt.
    public static func inspectOfficialIdentity(_ candidate: URL) throws -> OfficialAppIdentity {
        let app = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard app.pathExtension == "app", let bundle = Bundle(url: app),
              bundle.bundleIdentifier == bundleIdentifier, let executable = bundle.executableURL else {
            throw ClaudeInspectionError.unrecognizedApplication
        }
        try verifySignature(app)
        let checkedExecutable = executable.standardizedFileURL.resolvingSymlinksInPath()
        guard checkedExecutable.path.hasPrefix(app.path + "/") else { throw ClaudeInspectionError.unsafeCodeAsset }
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") +
            " (" + (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") + ")"
        return OfficialAppIdentity(app: app, executable: checkedExecutable, version: version)
    }

    /// Reads signed, packaged program assets only. Does not launch the provider or inspect its data.
    public static func inspect(_ candidate: URL) throws -> ClaudeCompatibilityReport {
        let identity = try inspectOfficialIdentity(candidate)
        let archiveURL = identity.app.appendingPathComponent("Contents/Resources/app.asar")
        let archive = try ClaudeASARReader(url: archiveURL, containing: identity.app)
        let entrypoint = try archive.entrypoint()
        let markers = try archive.markersPresent(ClaudePackagedCodeReview.requiredMarkers)
        let findings = ClaudePackagedCodeReview.findings(entrypoint: entrypoint, archiveMarkers: markers)
        let fingerprint = try fingerprint(identity: identity)
        // An update during inspection must not make the report appear to validate the earlier build.
        let after = try inspectOfficialIdentity(candidate)
        guard identity == after else { throw ClaudeInspectionError.applicationChanged }
        try archive.verifyUnchanged()
        return ClaudeCompatibilityReport(identity: identity, fingerprint: fingerprint, findings: findings)
    }

    public static func standardCandidates(preferred: URL?) -> [URL] {
        var result = [URL]()
        if let preferred { result.append(preferred.standardizedFileURL) }
        result.append(URL(fileURLWithPath: "/Applications/Claude.app"))
        result.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Claude.app"))
        var seen = Set<String>()
        return result.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    private static func verifySignature(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw ClaudeInspectionError.signatureUnverifiable
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\" and identifier \"\(bundleIdentifier)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | SecCSFlags.noNetworkAccess.rawValue), requirement) == errSecSuccess else {
            throw ClaudeInspectionError.signatureUnverifiable
        }
    }

    private static func fingerprint(identity: OfficialAppIdentity) throws -> String {
        var hash = SHA256()
        hash.update(data: Data("pairbar-claude-code-v1\0".utf8))
        let assets = [identity.app.appendingPathComponent("Contents/Info.plist"), identity.executable,
                      identity.app.appendingPathComponent("Contents/Resources/app.asar")]
        var opened: [ClaudeCodeAsset] = []
        for file in assets {
            let asset = try ClaudeCodeAsset(url: file, containing: identity.app)
            opened.append(asset)
            var length = UInt64(asset.size).littleEndian
            hash.update(data: withUnsafeBytes(of: &length) { Data($0) })
            try asset.forEachChunk { hash.update(data: $0) }
        }
        // Retain every descriptor until all bytes have been hashed. This rejects a
        // same-version bundle replacement instead of producing a mixed fingerprint.
        for asset in opened { try asset.verifyUnchanged() }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

public enum ClaudeInspectionError: String, Error, LocalizedError {
    case unrecognizedApplication, signatureUnverifiable, unsafeCodeAsset, malformedArchive
    case entrypointUnavailable, applicationChanged, unreadableCodeAsset
    public var errorDescription: String? {
        switch self {
        case .unrecognizedApplication: return "Select the official Claude.app. Current Account remains unmanaged."
        case .signatureUnverifiable: return "Claude's official signature could not be verified offline. No launch was attempted."
        case .unsafeCodeAsset: return "Claude's packaged code layout requires a compatibility review."
        case .malformedArchive: return "Claude's Electron archive is malformed or outside inspection bounds."
        case .entrypointUnavailable: return "Claude's packaged entrypoint could not be inspected safely."
        case .applicationChanged: return "Claude changed during inspection. Repeat the compatibility check."
        case .unreadableCodeAsset: return "Claude's packaged code could not be read. No profile data was accessed."
        }
    }
}

/// These findings are conservative hints for a reviewer, never proof of execution semantics.
enum ClaudePackagedCodeReview {
    static let requiredMarkers: Set<String> = ["CLAUDE_USER_DATA_DIR", "CLAUDE_CONFIG_DIR", "CLAUDE_SECURESTORAGE_CONFIG_DIR"]
    static func findings(entrypoint: String, archiveMarkers: Set<String>) -> [ClaudeSafetyFinding] {
        var result: [ClaudeSafetyFinding] = [.runtimeSeparationUnproven, .configurationAndAuthenticationMayBeShared,
                                           .oauthRoutingUnproven, .coworkIsolationUnproven]
        for (marker, finding) in [("CLAUDE_USER_DATA_DIR", ClaudeSafetyFinding.userDataOverrideMarkerMissing),
                                  ("CLAUDE_CONFIG_DIR", .configOverrideMarkerMissing),
                                  ("CLAUDE_SECURESTORAGE_CONFIG_DIR", .secureStorageOverrideMarkerMissing)] {
            if !archiveMarkers.contains(marker) { result.append(finding) }
        }
        let deletion = #"delete\s+(?:process|[A-Za-z_$][A-Za-z0-9_$]*)\s*\.\s*env\s*(?:\.\s*CLAUDE_USER_DATA_DIR|\[\s*["']CLAUDE_USER_DATA_DIR["']\s*\])"#
        if entrypoint.range(of: deletion, options: .regularExpression) != nil {
            result.append(.userDataOverrideDeletedByEntrypoint)
        }
        if entrypoint.contains("localPairingDisabledReason") { result.append(.localPairingAffectedByRelocation) }
        return result
    }
}

/// Review-only scaffold. This type intentionally has no launching API and cannot grant support.
/// Inputs are a proposed recipe written by a developer, never another process's arguments/environment.
public enum ClaudeIsolationPreflight {
    public static func findings(proposedArguments: [String], proposedEnvironmentKeys: Set<String>) -> [ClaudeSafetyFinding] {
        var result: [ClaudeSafetyFinding] = [.runtimeSeparationUnproven]
        // No command-line switches have a reviewed safe recipe, including --user-data-dir.
        if !proposedArguments.isEmpty { result.append(.prohibitedLaunchArguments) }
        if !proposedEnvironmentKeys.isSubset(of: ClaudePackagedCodeReview.requiredMarkers.union(["CODEX_HOME"])) {
            result.append(.unreviewedEnvironmentKeys)
        }
        return result
    }
    public static var managedLaunchAllowed: Bool { false }
}
