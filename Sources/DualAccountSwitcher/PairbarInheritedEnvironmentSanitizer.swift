import Darwin
import Foundation

/// Shared lexical policy. Never resolves symlinks or reads provider storage.
enum PairbarCodexEnvironmentValue: Equatable {
    case missing
    case external(String)
    case managed
    case unresolved

    private static func components(_ path: String) -> [String]? {
        guard path.hasPrefix("/") else { return nil }
        var result: [String] = []
        for part in path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !result.isEmpty { result.removeLast() }; continue }
            result.append(String(part))
        }
        return result
    }

    static func classify(_ value: String?, pairbarRoot: URL) -> Self {
        guard let value else { return .missing }
        guard let root = components(pairbarRoot.path), let path = components(value) else { return .unresolved }
        let profiles = root + ["Profiles"]
        if path.count >= profiles.count && Array(path.prefix(profiles.count)) == profiles { return .managed }
        guard !value.contains("\0") else { return .unresolved }
        return .external(value)
    }
}

enum PairbarInheritedEnvironmentSanitizer {
    static let codexKeys = ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"]

    static func keysToRemove(environment: [String: String], pairbarRoot: URL) -> Set<String> {
        Set(codexKeys.filter {
            PairbarCodexEnvironmentValue.classify(environment[$0], pairbarRoot: pairbarRoot) == .managed
        })
    }

    static func apply(environment: [String: String], pairbarRoot: URL,
                      unset: (String) -> Void) {
        for key in keysToRemove(environment: environment, pairbarRoot: pairbarRoot) { unset(key) }
    }
}

enum PairbarStartup {
    static func run<T>(environment: [String: String], pairbarRoot: URL,
                       home: URL = FileManager.default.homeDirectoryForCurrentUser,
                       username: String = NSUserName(), temporaryDirectory: String = NSTemporaryDirectory(),
                       unset: (String) -> Void, start: (CurrentCodexLaunchEnvironment) -> T) throws -> T {
        // Capture the original custom Current values before sanitizing Pairbar itself.
        let current = try CurrentCodexLaunchEnvironment(environment: environment, pairbarRoot: pairbarRoot,
            home: home, username: username, temporaryDirectory: temporaryDirectory)
        PairbarInheritedEnvironmentSanitizer.apply(
            environment: environment, pairbarRoot: pairbarRoot, unset: unset)
        return start(current)
    }
}
