import Foundation

/// Resolved once at startup and passed by value to every new Codex Current launch.
/// Both environment entries are built from these immutable resolved paths.
struct CurrentCodexLaunchEnvironment {
    let codexHome: String
    let electronUserDataPath: String
    let environment: [String: String]

    enum ResolutionError: Error { case unsafeDefault }

    init(environment: [String: String], pairbarRoot: URL, home: URL,
         username: String, temporaryDirectory: String) throws {
        var resolved = ProviderLaunchRequest.baseEnvironment(home: home, username: username,
                                                             temporaryDirectory: temporaryDirectory)
        func resolve(_ key: String, fallback: String) throws -> String {
            switch PairbarCodexEnvironmentValue.classify(environment[key], pairbarRoot: pairbarRoot) {
            case .external(let custom): return custom
            case .missing, .managed, .unresolved:
                // Invalid/relative values cannot establish a reliable Current path.
                guard case .external = PairbarCodexEnvironmentValue.classify(fallback, pairbarRoot: pairbarRoot)
                else { throw ResolutionError.unsafeDefault }
                return fallback
            }
        }
        let codexHome = try resolve("CODEX_HOME", fallback: home.appendingPathComponent(".codex").path)
        let electronUserDataPath = try resolve("CODEX_ELECTRON_USER_DATA_PATH",
            fallback: home.appendingPathComponent("Library/Application Support/Codex").path)
        resolved["CODEX_HOME"] = codexHome
        resolved["CODEX_ELECTRON_USER_DATA_PATH"] = electronUserDataPath
        self.codexHome = codexHome
        self.electronUserDataPath = electronUserDataPath
        self.environment = resolved
    }
}
