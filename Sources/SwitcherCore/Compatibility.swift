import Foundation
import Security
import CryptoKit

public struct OfficialAppIdentity: Equatable {
    public let app: URL
    public let executable: URL
    public let version: String
    public let verification: OfficialVerification
    public init(app: URL, executable: URL, version: String, verification: OfficialVerification = .codeSigning) {
        self.app = app; self.executable = executable; self.version = version; self.verification = verification
    }
}

public enum OfficialVerification: Equatable { case codeSigning, reviewedArtifact }

public struct CompatibilityReport {
    public let app: URL
    public let executable: URL
    public let version: String
    public let fingerprint: String
    public let verification: OfficialVerification
    public var summary: String {
        "\(verification == .codeSigning ? "OpenAI signature verified" : "Reviewed official artifact verified") · version \(version)\nElectron profile override found · CODEX_HOME support found\nBuild fingerprint: \(fingerprint)\nThese static checks cannot prove account isolation. Verify both accounts in the official app."
    }
}

public enum Compatibility {
    public static let bundleIdentifier = "com.openai.codex"
    public static let expectedTeamIdentifier = "2DC432GLL2"

    /// Performs only the checks required to safely identify the genuine official app.
    /// Current Account may use this even when the stricter isolation compatibility gate
    /// has not yet been approved, because Current launches with no profile overrides.
    public static func inspectOfficialIdentity(_ candidate: URL) throws -> OfficialAppIdentity {
        let app = candidate.standardizedFileURL.resolvingSymlinksInPath()
        guard FileManager.default.fileExists(atPath: app.path) else {
            throw SwitcherError.message("The official app is missing or moved. Use Settings → App details → Choose app… to select its new location. Account data is preserved.")
        }
        guard app.pathExtension == "app", let bundle = Bundle(url: app),
              bundle.bundleIdentifier == bundleIdentifier, let executable = bundle.executableURL else {
            throw SwitcherError.message("Pairbar no puede verificar esta app.")
        }
        let verification = try verifyOpenAISignature(app, bundle: bundle, executable: executable)
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") +
                      " (" + (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") + ")"
        return OfficialAppIdentity(app: app, executable: executable.resolvingSymlinksInPath(), version: version, verification: verification)
    }

    /// Performs the stronger checks required before creating an isolated Second Account.
    public static func inspect(_ candidate: URL) throws -> CompatibilityReport {
        let identity = try inspectOfficialIdentity(candidate)
        let app = identity.app
        let executable = identity.executable
        let archive = app.appendingPathComponent("Contents/Resources/app.asar")

        let indicators = try bootstrapIndicators(archive)
        guard indicators.contains("CODEX_ELECTRON_USER_DATA_PATH"), indicators.contains("userData") else {
            throw SwitcherError.message("This build lacks the expected Electron profile override. Second Account launch is blocked. Current Account can still use the normal official app.")
        }
        guard try archiveContains(archive, marker: "CODEX_HOME") else {
            throw SwitcherError.message("This build lacks expected CODEX_HOME support. Second Account launch is blocked; Current Account is unaffected.")
        }

        var hash = SHA256()
        for file in [app.appendingPathComponent("Contents/Info.plist"), executable, archive] {
            let handle = try FileHandle(forReadingFrom: file)
            defer { try? handle.close() }
            while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty { hash.update(data: chunk) }
        }
        let fingerprint = hash.finalize().map { String(format: "%02x", $0) }.joined()
        return CompatibilityReport(app: app, executable: executable, version: identity.version, fingerprint: fingerprint, verification: identity.verification)
    }

    /// Conservative convenience lookup. Only standard install locations are considered;
    /// the switcher never scans arbitrary disks or application data.
    public static func standardCandidates(preferred: URL?) -> [URL] {
        var values: [URL] = []
        if let preferred { values.append(preferred.standardizedFileURL) }
        values.append(URL(fileURLWithPath: "/Applications/ChatGPT.app"))
        values.append(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/ChatGPT.app"))
        var seen = Set<String>()
        return values.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    struct ArtifactPin {
        let version: String
        let build: String
        let sha256: String
        let entries: Int
    }
    // Reviewed against the Apple-signed production DMG and the Ed25519-verified
    // Sparkle ZIP; see VALIDATION.md. A future build requires a new review.
    private static let reviewedArtifact = ArtifactPin(version: "26.917.71314", build: "10954",
        sha256: "830b61866b65323b8c0f4546dc07d5950b37cc3b0e8c4fc109886df2e1eb72a5", entries: 5326)

    static func decideOfficialVerification(signatureValid: Bool, version: String?, build: String?,
                                           team: String?, identifier: String?, arm64: Bool,
                                           pin: ArtifactPin, digest: () throws -> CanonicalBundleDigest.Result) throws -> OfficialVerification {
        if signatureValid { return .codeSigning }
        guard team == expectedTeamIdentifier, identifier == bundleIdentifier, arm64 else {
            throw SwitcherError.message("Pairbar no puede verificar esta app.")
        }
        guard version == pin.version, build == pin.build else {
            throw SwitcherError.message("Esta versión de ChatGPT necesita una actualización/revisión de Pairbar antes de usar perfiles adicionales.")
        }
        let actual = try? digest()
        guard actual?.sha256 == pin.sha256, actual?.entries == pin.entries else {
            throw SwitcherError.message("Pairbar no puede verificar esta app.")
        }
        return .reviewedArtifact
    }

    private static func verifyOpenAISignature(_ app: URL, bundle: Bundle, executable: URL) throws -> OfficialVerification {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw SwitcherError.message("Pairbar no puede verificar esta app.")
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\" and identifier \"\(bundleIdentifier)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess, let requirement else {
            throw SwitcherError.message("Pairbar no puede verificar esta app.")
        }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | SecCSFlags.noNetworkAccess.rawValue), requirement)
        if status == errSecSuccess { return .codeSigning }

        let version = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String
        var signing: CFDictionary?
        guard SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &signing) == errSecSuccess else {
            throw SwitcherError.message("Pairbar no puede verificar esta app.")
        }
        let info = (signing as? [String: Any]) ?? [:]
        return try decideOfficialVerification(signatureValid: false, version: version, build: build,
            team: info[kSecCodeInfoTeamIdentifier as String] as? String,
            identifier: info[kSecCodeInfoIdentifier as String] as? String,
            arm64: isArm64MachO(executable), pin: reviewedArtifact) {
            try CanonicalBundleDigest.calculate(app)
        }
    }

    private static func isArm64MachO(_ executable: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
        return Array(header) == [0xcf, 0xfa, 0xed, 0xfe, 0x0c, 0x00, 0x00, 0x01]
    }

    // Inspect packaged program code only. Never inspect profile files, process argv, or environment.
    private static func bootstrapIndicators(_ archive: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 16), header.count == 16 else {
            throw SwitcherError.message("Electron archive header is unreadable.")
        }
        func u32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(UInt32(0)) { $0 | (UInt32(header[offset + $1]) << ($1 * 8)) }
        }
        let size = Int(u32(12)); let base = UInt64(u32(4)) + 8
        guard size > 0, size <= 8_388_608, let json = try handle.read(upToCount: size), json.count == size,
              let root = try JSONSerialization.jsonObject(with: json) as? [String: Any] else {
            throw SwitcherError.message("Electron archive layout changed; compatibility review required.")
        }
        var selected: [String: Any]?
        func visit(_ node: [String: Any], path: String) {
            guard let files = node["files"] as? [String: [String: Any]] else { return }
            for (name, child) in files {
                let next = path + name
                if child["files"] != nil { visit(child, path: next + "/") }
                else if next.hasPrefix(".vite/build/bootstrap-"), next.hasSuffix(".js") { selected = child }
            }
        }
        visit(root, path: "")
        guard let selected, let offsetText = selected["offset"] as? String, let offset = UInt64(offsetText),
              let length = selected["size"] as? Int, length > 0, length <= 4_194_304,
              base <= UInt64.max - offset else {
            throw SwitcherError.message("Expected Electron bootstrap code was not found. Update compatibility checks after reviewing the new app.")
        }
        try handle.seek(toOffset: base + offset)
        guard let data = try handle.read(upToCount: length), data.count == length,
              let text = String(data: data, encoding: .utf8) else {
            throw SwitcherError.message("Cannot inspect Electron bootstrap.")
        }
        return text
    }

    private static func archiveContains(_ file: URL, marker: String) throws -> Bool {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let needle = Data(marker.utf8); var tail = Data()
        while let chunk = try handle.read(upToCount: 1_048_576), !chunk.isEmpty {
            let combined = tail + chunk
            if combined.range(of: needle) != nil { return true }
            tail = Data(combined.suffix(max(0, needle.count - 1)))
        }
        return false
    }
}
