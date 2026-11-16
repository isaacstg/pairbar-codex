import Foundation
import Security
import CryptoKit

public struct OfficialAppIdentity: Equatable {
    public let app: URL
    public let executable: URL
    public let version: String
    public init(app: URL, executable: URL, version: String) {
        self.app = app; self.executable = executable; self.version = version
    }
}

public struct CompatibilityReport {
    public let app: URL
    public let executable: URL
    public let version: String
    public let fingerprint: String
    public var summary: String {
        "OpenAI signature verified · version \(version)\nElectron profile override found · CODEX_HOME support found\nBuild fingerprint: \(fingerprint)\nThese static checks cannot prove account isolation. Verify both accounts in the official app."
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
            throw SwitcherError.message("Select the official Electron-based ChatGPT/Codex app (bundle ID \(bundleIdentifier)).")
        }
        try verifyOpenAISignature(app)
        let version = (bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown") +
                      " (" + (bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown") + ")"
        return OfficialAppIdentity(app: app, executable: executable.resolvingSymlinksInPath(), version: version)
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
        return CompatibilityReport(app: app, executable: executable, version: identity.version, fingerprint: fingerprint)
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

    private static func verifyOpenAISignature(_ app: URL) throws {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else {
            throw SwitcherError.message("Cannot inspect the app signature. Reinstall ChatGPT from OpenAI.")
        }
        var requirement: SecRequirement?
        let expression = "anchor apple generic and certificate leaf[subject.OU] = \"\(expectedTeamIdentifier)\" and identifier \"\(bundleIdentifier)\""
        guard SecRequirementCreateWithString(expression as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures | SecCSFlags.noNetworkAccess.rawValue), requirement) == errSecSuccess else {
            throw SwitcherError.message("App signature is invalid or does not match OpenAI's expected signing identity. No launch was attempted. Reinstall the official app; a legitimate signing change requires a reviewed switcher update.")
        }
    }

    // Inspect packaged program code only. Never inspect profile files, process argv, or environment.
    // Available to SwitcherCoreTests with synthetic ASAR fixtures.
    static func bootstrapIndicators(_ archive: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: archive)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: 16), header.count == 16 else {
            throw SwitcherError.message("Electron archive header is unreadable.")
        }
        func u32(_ offset: Int) -> UInt64 {
            (0..<4).reduce(UInt64(0)) { $0 | (UInt64(header[offset + $1]) << ($1 * 8)) }
        }

        let jsonSize = u32(12), headerSize = u32(4), archiveSize = try handle.seekToEnd()
        // The first 16 bytes are the ASAR pickle header. Keep all offsets bounded
        // by the actual file size before reading any entry described by the index.
        guard jsonSize > 0, jsonSize <= 8_388_608,
              headerSize >= 8, headerSize <= archiveSize - min(archiveSize, 8),
              headerSize <= UInt64.max - 8,
              let rootData = try readArchive(handle, at: 16, length: Int(jsonSize), archiveSize: archiveSize),
              let root = try JSONSerialization.jsonObject(with: rootData) as? [String: Any],
              let files = root["files"] as? [String: Any] else {
            throw SwitcherError.message("Electron archive layout changed; compatibility review required.")
        }
        let payloadBase = headerSize + 8

        struct Candidate {
            let path: String
            let offset: UInt64
            let length: Int
        }
        var candidates: [Candidate] = []
        var invalidCandidates = false
        func visit(_ nodes: [String: Any], path: String, depth: Int) {
            guard depth <= 32, candidates.count <= 64 else { invalidCandidates = true; return }
            for name in nodes.keys.sorted() {
                guard let child = nodes[name] as? [String: Any] else { continue }
                let next = path + name
                if let descendants = child["files"] as? [String: Any] {
                    visit(descendants, path: next + "/", depth: depth + 1)
                } else if next.hasPrefix(".vite/build/"), next.hasSuffix(".js"),
                    next == ".vite/build/early-bootstrap.js" ||
                    next == ".vite/build/bootstrap.js" ||
                    next.hasPrefix(".vite/build/early-bootstrap-") ||
                    next.hasPrefix(".vite/build/bootstrap-") {
                    guard child["link"] == nil, child["unpacked"] == nil,
                          let offsetString = child["offset"] as? String,
                          !offsetString.isEmpty, offsetString.allSatisfy({ $0 >= "0" && $0 <= "9" }),
                          let offset = UInt64(offsetString),
                          let length = child["size"] as? Int, length > 0, length <= 4_194_304,
                          offset <= UInt64.max - payloadBase,
                          payloadBase + offset <= archiveSize,
                          UInt64(length) <= archiveSize - payloadBase - offset else {
                        invalidCandidates = true
                        continue
                    }
                    candidates.append(Candidate(path: next, offset: payloadBase + offset, length: length))
                }
            }
        }
        visit(files, path: "", depth: 0)
        guard !invalidCandidates, !candidates.isEmpty, candidates.count <= 64 else {
            throw SwitcherError.message("No readable Electron bootstrap module was found. The installed app may use a different layout.")
        }

        // A canonical bootstrap entry is stronger evidence than an unrelated
        // bundled worker that happens to quote the same environment variables.
        // Older builds used bootstrap-<hash>.js; current builds use early-bootstrap.js.
        let canonical = candidates.filter {
            $0.path == ".vite/build/early-bootstrap.js" || $0.path == ".vite/build/bootstrap.js"
        }
        let selected = canonical.isEmpty ? candidates : canonical
        for candidate in selected.sorted(by: { $0.path < $1.path }) {
            guard let data = try readArchive(handle, at: candidate.offset,
                                             length: candidate.length, archiveSize: archiveSize),
                  let source = String(data: data, encoding: .utf8) else {
                throw SwitcherError.message("Cannot inspect Electron bootstrap module.")
            }
            if source.contains("CODEX_ELECTRON_USER_DATA_PATH") && source.contains("userData") {
                return source
            }
        }
        throw SwitcherError.message("This ChatGPT build does not expose the expected Electron profile override in its bootstrap. Managed profile opening remains blocked.")
    }

    private static func readArchive(_ handle: FileHandle, at offset: UInt64,
                                    length: Int, archiveSize: UInt64) throws -> Data? {
        guard length > 0, length <= 8_388_608,
              offset <= archiveSize, UInt64(length) <= archiveSize - offset else { return nil }
        try handle.seek(toOffset: offset)
        let bytes = try handle.read(upToCount: length)
        return bytes?.count == length ? bytes : nil
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
