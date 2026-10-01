import Darwin
import Foundation

enum PairbarInheritedEnvironmentSanitizer {
    private static let codexKeys = ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"]

    /// Lexical containment only: normalize dot components without traversing symlinks or reading storage.
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

    static func keysToRemove(environment: [String: String], pairbarRoot: URL) -> Set<String> {
        guard let root = components(pairbarRoot.path) else { return [] }
        let profiles = root + ["Profiles"]
        return Set(codexKeys.filter { key in
            guard let value = environment[key], let valueComponents = components(value) else { return false }
            return valueComponents.count >= profiles.count &&
                Array(valueComponents.prefix(profiles.count)) == profiles
        })
    }

    static func apply(environment: [String: String], pairbarRoot: URL,
                      unset: (String) -> Void) {
        for key in keysToRemove(environment: environment, pairbarRoot: pairbarRoot) {
            unset(key)
        }
    }
}

enum PairbarStartup {
    static func run<T>(environment: [String: String], pairbarRoot: URL,
                       unset: (String) -> Void, start: () -> T) -> T {
        PairbarInheritedEnvironmentSanitizer.apply(
            environment: environment, pairbarRoot: pairbarRoot, unset: unset)
        return start()
    }
}
