import Foundation
import Darwin
import CoreFoundation

/// Bounded reads of official program assets; this reader has no profile-data fallback.
final class ClaudeCodeAsset {
    let size: Int64
    private let url: URL
    private let handle: FileHandle
    private let snapshot: stat
    private static let maximumSize: Int64 = 2_147_483_648

    init(url: URL, containing root: URL) throws {
        let normalized = url.standardizedFileURL
        let canonical = normalized.resolvingSymlinksInPath()
        guard normalized == canonical, canonical.path.hasPrefix(root.standardizedFileURL.resolvingSymlinksInPath().path + "/") else {
            throw ClaudeInspectionError.unsafeCodeAsset
        }
        let descriptor = Darwin.open(canonical.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ClaudeInspectionError.unreadableCodeAsset }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_nlink == 1,
              info.st_size > 0, info.st_size <= Self.maximumSize else {
            close(descriptor)
            throw ClaudeInspectionError.unsafeCodeAsset
        }
        self.url = canonical
        self.handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        self.snapshot = info
        self.size = info.st_size
    }

    func read(offset: UInt64, count: Int) throws -> Data {
        guard count >= 0, count <= 8_388_608, offset <= UInt64(size), UInt64(count) <= UInt64(size) - offset else {
            throw ClaudeInspectionError.malformedArchive
        }
        do {
            try handle.seek(toOffset: offset)
            guard let bytes = try handle.read(upToCount: count), bytes.count == count else { throw ClaudeInspectionError.unreadableCodeAsset }
            return bytes
        } catch let error as ClaudeInspectionError { throw error }
        catch { throw ClaudeInspectionError.unreadableCodeAsset }
    }

    func forEachChunk(_ body: (Data) throws -> Void) throws {
        var offset: UInt64 = 0
        while offset < UInt64(size) {
            let bytes = try read(offset: offset, count: Int(min(1_048_576, UInt64(size) - offset)))
            try body(bytes)
            offset += UInt64(bytes.count)
        }
    }

    func verifyUnchanged() throws {
        var opened = stat(), named = stat()
        guard fstat(handle.fileDescriptor, &opened) == 0, lstat(url.path, &named) == 0,
              matches(opened), matches(named) else { throw ClaudeInspectionError.applicationChanged }
    }

    private func matches(_ info: stat) -> Bool {
        info.st_dev == snapshot.st_dev && info.st_ino == snapshot.st_ino && info.st_size == snapshot.st_size &&
        info.st_mode == snapshot.st_mode && info.st_nlink == snapshot.st_nlink &&
        info.st_mtimespec.tv_sec == snapshot.st_mtimespec.tv_sec && info.st_mtimespec.tv_nsec == snapshot.st_mtimespec.tv_nsec &&
        info.st_ctimespec.tv_sec == snapshot.st_ctimespec.tv_sec && info.st_ctimespec.tv_nsec == snapshot.st_ctimespec.tv_nsec
    }
}

final class ClaudeASARReader {
    private let asset: ClaudeCodeAsset
    private let files: [String: Any]
    private let payloadOffset: UInt64
    private static let maximumHeader = 8_388_608
    private static let maximumEntrypoint = 8_388_608

    init(url: URL, containing root: URL) throws {
        asset = try ClaudeCodeAsset(url: url, containing: root)
        let prefix = try asset.read(offset: 0, count: 16)
        func u32(_ start: Int) -> UInt64 {
            (0..<4).reduce(UInt64(0)) { $0 | UInt64(prefix[start + $1]) << ($1 * 8) }
        }
        let sizePicklePayload = u32(0), headerPickleSize = u32(4), headerPayloadSize = u32(8), jsonSize = u32(12)
        guard sizePicklePayload == 4, headerPickleSize >= 8,
              headerPickleSize <= UInt64(Self.maximumHeader) + 8, headerPickleSize % 4 == 0,
              headerPayloadSize + 4 == headerPickleSize, jsonSize > 0, jsonSize <= UInt64(Self.maximumHeader),
              jsonSize + 4 <= headerPayloadSize, headerPayloadSize - (jsonSize + 4) < 4,
              headerPickleSize + 8 <= UInt64(asset.size) else { throw ClaudeInspectionError.malformedArchive }
        payloadOffset = headerPickleSize + 8
        let data = try asset.read(offset: 16, count: Int(jsonSize))
        guard let object = try? JSONSerialization.jsonObject(with: data), let rootObject = object as? [String: Any],
              let files = rootObject["files"] as? [String: Any] else { throw ClaudeInspectionError.malformedArchive }
        self.files = files
    }

    func entrypoint() throws -> String {
        let packageData = try readFile("package.json", maximumSize: 65_536)
        guard let package = (try? JSONSerialization.jsonObject(with: packageData)) as? [String: Any],
              let main = package["main"] as? String, main.utf8.count <= 512,
              main.hasSuffix(".js") || main.hasSuffix(".cjs") || main.hasSuffix(".mjs") else {
            throw ClaudeInspectionError.entrypointUnavailable
        }
        let bytes = try readFile(main, maximumSize: Self.maximumEntrypoint)
        guard let source = String(data: bytes, encoding: .utf8) else { throw ClaudeInspectionError.entrypointUnavailable }
        return source
    }

    /// Presence in the archive is intentionally weaker than reachable entrypoint support.
    func markersPresent(_ markers: Set<String>) throws -> Set<String> {
        guard markers.count <= 16, markers.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 }) else {
            throw ClaudeInspectionError.malformedArchive
        }
        var found = Set<String>(), tail = Data()
        let overlap = max(0, (markers.map { $0.utf8.count }.max() ?? 1) - 1)
        try asset.forEachChunk { chunk in
            let combined = tail + chunk
            for marker in markers where !found.contains(marker) {
                if combined.range(of: Data(marker.utf8)) != nil { found.insert(marker) }
            }
            tail = Data(combined.suffix(overlap))
        }
        return found
    }

    func verifyUnchanged() throws { try asset.verifyUnchanged() }

    private func readFile(_ path: String, maximumSize: Int) throws -> Data {
        let clean = path.hasPrefix("./") ? String(path.dropFirst(2)) : path
        let parts = clean.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !parts.isEmpty, parts.count <= 32, parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains("\\") && !$0.contains("\0") }) else {
            throw ClaudeInspectionError.entrypointUnavailable
        }
        var directory = files
        var selected: [String: Any]?
        for (index, name) in parts.enumerated() {
            guard let entry = directory[name] as? [String: Any], entry["link"] == nil,
                  entry["unpacked"] == nil || (entry["unpacked"] as? Bool) == false else {
                throw ClaudeInspectionError.entrypointUnavailable
            }
            if index == parts.count - 1 { selected = entry }
            else {
                guard let children = entry["files"] as? [String: Any] else { throw ClaudeInspectionError.entrypointUnavailable }
                directory = children
            }
        }
        guard let entry = selected, entry["files"] == nil,
              let offsetText = entry["offset"] as? String, !offsetText.isEmpty,
              offsetText.allSatisfy({ $0 >= "0" && $0 <= "9" }), let offset = UInt64(offsetText),
              let number = entry["size"] as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.rounded(.towardZero) == number.doubleValue,
              number.doubleValue > 0, number.doubleValue <= Double(maximumSize),
              offset <= UInt64(asset.size) - payloadOffset else { throw ClaudeInspectionError.entrypointUnavailable }
        return try asset.read(offset: payloadOffset + offset, count: number.intValue)
    }
}
