import Foundation
import CryptoKit
import Darwin

/// Version 1: SHA-256 over a sorted, length-framed tree of directories, files and links.
/// File contents and link targets are hashed; filesystem copy metadata is deliberately absent.
public enum CanonicalBundleDigest {
    public struct Result: Equatable {
        public let sha256: String
        public let entries: Int
    }

    public static func calculate(_ root: URL) throws -> Result {
        let root = root.standardizedFileURL
        var rootStat = stat()
        guard lstat(root.path, &rootStat) == 0, rootStat.st_mode & S_IFMT == S_IFDIR,
              let rootReal = realpath(root.path, nil) else { throw Failure.unsafeTree }
        defer { free(rootReal) }
        let rootPath = String(cString: rootReal)
        var records: [(String, UInt8, URL, Int64, String?)] = []
        var seen = Set<String>()

        func visit(_ directory: URL, _ prefix: String) throws {
            let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            for name in names {
                guard !name.isEmpty, name != ".", name != "..", !name.contains("/"),
                      name == name.precomposedStringWithCanonicalMapping,
                      let nameData = name.data(using: .utf8), !nameData.contains(0) else { throw Failure.unsafeTree }
                let relative = prefix.isEmpty ? name : prefix + "/" + name
                guard seen.insert(relative.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))).inserted else {
                    throw Failure.unsafeTree
                }
                let url = directory.appendingPathComponent(name)
                var info = stat()
                guard lstat(url.path, &info) == 0 else { throw Failure.unsafeTree }
                switch info.st_mode & S_IFMT {
                case S_IFDIR:
                    records.append((relative, 0x44, url, 0, nil))
                    try visit(url, relative)
                case S_IFREG:
                    guard info.st_size >= 0 else { throw Failure.unsafeTree }
                    records.append((relative, 0x46, url, info.st_size, nil))
                case S_IFLNK:
                    var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN) + 1)
                    let length = readlink(url.path, &buffer, buffer.count - 1)
                    guard length > 0, length < buffer.count - 1,
                          let target = String(bytes: buffer.prefix(length).map(UInt8.init), encoding: .utf8),
                          !target.hasPrefix("/"), !target.contains("\0"),
                          let resolved = realpath(url.path, nil) else { throw Failure.unsafeTree }
                    defer { free(resolved) }
                    let destination = String(cString: resolved)
                    guard destination.hasPrefix(rootPath + "/") else { throw Failure.unsafeTree }
                    records.append((relative, 0x4c, url, 0, target))
                default: throw Failure.unsafeTree
                }
            }
        }
        try visit(root, "")
        records.sort { $0.0.utf8.lexicographicallyPrecedes($1.0.utf8) }
        var hash = SHA256()
        hash.update(data: Data("Pairbar canonical bundle v1\0".utf8))
        func length(_ value: UInt64) { var big = value.bigEndian; withUnsafeBytes(of: &big) { hash.update(data: Data($0)) } }
        func bytes(_ value: Data) { length(UInt64(value.count)); hash.update(data: value) }
        for (path, kind, url, size, target) in records {
            hash.update(data: Data([kind]))
            bytes(Data(path.utf8))
            if kind == 0x4c { bytes(Data(target!.utf8)) }
            if kind == 0x46 {
                length(UInt64(size))
                let fd = open(url.path, O_RDONLY | O_NOFOLLOW)
                guard fd >= 0 else { throw Failure.unsafeTree }
                defer { close(fd) }
                var before = stat(), after = stat()
                guard fstat(fd, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
                      before.st_size == size else { throw Failure.unsafeTree }
                var remaining = size
                var buffer = [UInt8](repeating: 0, count: 1_048_576)
                while remaining > 0 {
                    let count = read(fd, &buffer, min(buffer.count, Int(remaining)))
                    guard count > 0 else { throw Failure.unsafeTree }
                    hash.update(data: Data(buffer.prefix(count)))
                    remaining -= Int64(count)
                }
                guard fstat(fd, &after) == 0, before.st_dev == after.st_dev,
                      before.st_ino == after.st_ino, before.st_size == after.st_size,
                      before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
                      before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec else { throw Failure.unsafeTree }
            }
        }
        return Result(sha256: hash.finalize().map { String(format: "%02x", $0) }.joined(), entries: records.count)
    }

    public enum Failure: Error { case unsafeTree }
}
