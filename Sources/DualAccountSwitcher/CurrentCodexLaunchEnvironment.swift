import Foundation

/// Resolved once at startup and passed by value to every new Codex Current launch.
struct CurrentCodexLaunchEnvironment {
    let environment: [String: String]

    enum ResolutionError: Error { case unsafeDefault }

    init(environment: [String: String], pairbarRoot: URL, home: URL,
         username: String, temporaryDirectory: String) throws {
        var resolved = ProviderLaunchRequest.baseEnvironment(home: home, username: username,
                                                             temporaryDirectory: temporaryDirectory)
        let defaults = ["CODEX_HOME": home.appendingPathComponent(".codex").path,
                        "CODEX_ELECTRON_USER_DATA_PATH": home.appendingPathComponent("Library/Application Support/Codex").path]
        for key in PairbarInheritedEnvironmentSanitizer.codexKeys {
            switch PairbarCodexEnvironmentValue.classify(environment[key], pairbarRoot: pairbarRoot) {
            case .external(let custom): resolved[key] = custom
            case .missing, .managed, .unresolved:
                // Invalid/relative values cannot establish a reliable Current path.
                guard let fallback = defaults[key],
                      case .external = PairbarCodexEnvironmentValue.classify(fallback, pairbarRoot: pairbarRoot)
                else { throw ResolutionError.unsafeDefault }
                resolved[key] = fallback
            }
        }
        self.environment = resolved
    }
}
