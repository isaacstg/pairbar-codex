import AppKit
import Foundation

struct ProviderLaunchRequest {
    let app: URL
    let arguments: [String]
    let environment: [String: String]
    let createsNewInstance: Bool

    @MainActor func openConfiguration() -> NSWorkspace.OpenConfiguration {
        let configuration = NSWorkspace.OpenConfiguration()
        // Focus remains subject to the controller's returned-process verification.
        configuration.activates = false
        configuration.createsNewApplicationInstance = createsNewInstance
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = arguments
        if !environment.isEmpty { configuration.environment = environment }
        return configuration
    }

    static func baseEnvironment(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                username: String = NSUserName(), temporaryDirectory: String = NSTemporaryDirectory()) -> [String: String] {
        ["HOME": home.path, "USER": username, "LOGNAME": username,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporaryDirectory]
    }

    static func current(app: URL, hasManagedInstances: Bool,
                        currentEnvironment: CurrentCodexLaunchEnvironment) -> Self {
        Self(app: app, arguments: [], environment: currentEnvironment.environment,
             createsNewInstance: hasManagedInstances)
    }

    static func currentClaude(app: URL, hasManagedInstances: Bool) -> Self {
        Self(app: app, arguments: [], environment: [:], createsNewInstance: hasManagedInstances)
    }

    static func codex(app: URL, electron: URL, codexHome: URL,
                      home: URL = FileManager.default.homeDirectoryForCurrentUser,
                      username: String = NSUserName(), temporaryDirectory: String = NSTemporaryDirectory()) -> Self {
        var environment = baseEnvironment(home: home, username: username, temporaryDirectory: temporaryDirectory)
        environment["CODEX_HOME"] = codexHome.path
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = electron.path
        return Self(app: app, arguments: ["--user-data-dir=" + electron.path],
                    environment: environment, createsNewInstance: true)
    }
}
