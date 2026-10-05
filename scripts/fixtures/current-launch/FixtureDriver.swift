import AppKit
import Darwin

@main
struct FixtureDriver {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        guard root.path.hasPrefix("/private/tmp/pairbar-current-launch.") else { fatalError("Unsafe fixture root") }
        let appURL = root.appendingPathComponent("EnvironmentFixture.app")
        let pairbarRoot = root.appendingPathComponent("pairbar")
        let home = root.appendingPathComponent("current-home")
        let workHome = pairbarRoot.appendingPathComponent("Profiles/b/codex")
        let workElectron = pairbarRoot.appendingPathComponent("Profiles/b/electron")
        let workEnvironment = ["CODEX_HOME": workHome.path, "CODEX_ELECTRON_USER_DATA_PATH": workElectron.path]
        var apps: [NSRunningApplication] = []
        func waitForExit() async throws {
            for application in apps { _ = application.terminate() }
            for _ in 0..<100 {
                if apps.allSatisfy({ $0.isTerminated }) { return }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NSError(domain: "FixtureCleanup", code: 1)
        }
        func launch(_ request: ProviderLaunchRequest, label: String) async throws -> [String: Any] {
            let application: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                NSWorkspace.shared.openApplication(at: request.app, configuration: request.openConfiguration()) { app, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let app { continuation.resume(returning: app) }
                    else { continuation.resume(throwing: NSError(domain: "FixtureLaunch", code: 1)) }
                }
            }
            apps.append(application)
            let path = root.appendingPathComponent("records/\(application.processIdentifier).json")
            for _ in 0..<100 {
                if let data = try? Data(contentsOf: path),
                   let record = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let text = String(data: try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]), encoding: .utf8)!
                    print("\(label): \(text)")
                    return record
                }
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            throw NSError(domain: "FixtureRecord", code: 1)
        }
        func verify(_ record: [String: Any], expected: [String: String]) throws {
            for key in PairbarInheritedEnvironmentSanitizer.codexKeys {
                guard record[key] as? String == expected[key],
                      PairbarCodexEnvironmentValue.classify(record[key] as? String, pairbarRoot: pairbarRoot) != .managed
                else { throw NSError(domain: "FixtureIsolation", code: 1) }
            }
        }
        do {
            let managed = ProviderLaunchRequest.codex(app: appURL, electron: workElectron, codexHome: workHome,
                home: home, username: "fixture", temporaryDirectory: root.path)
            let work = try await launch(managed, label: "A managed")
            guard work["CODEX_HOME"] as? String == workHome.path,
                  work["CODEX_ELECTRON_USER_DATA_PATH"] as? String == workElectron.path
            else { throw NSError(domain: "FixtureManaged", code: 1) }
            let old = ProviderLaunchRequest(app: appURL, arguments: [], environment: [:], createsNewInstance: true)
            let oldRecord = try await launch(old, label: "B old Current")
            print("B observed synthetic Work inheritance: \(oldRecord["CODEX_HOME"] as? String == workHome.path || oldRecord["CODEX_ELECTRON_USER_DATA_PATH"] as? String == workElectron.path)")
            for (label, startup) in [
                ("C fixed defaults", workEnvironment),
                ("D fixed custom", ["CODEX_HOME": root.path + "/custom/codex", "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/custom/electron"]),
                ("E fixed mixed", ["CODEX_HOME": root.path + "/custom/codex", "CODEX_ELECTRON_USER_DATA_PATH": workElectron.path])
            ] {
                let current = try PairbarStartup.run(environment: startup, pairbarRoot: pairbarRoot,
                    home: home, username: "fixture", temporaryDirectory: root.path, unset: { _ in }) { $0 }
                let request = ProviderLaunchRequest.current(app: appURL, hasManagedInstances: true, currentEnvironment: current)
                let record = try await launch(request, label: label)
                try verify(record, expected: current.environment)
            }
            guard Set(apps.map(\.processIdentifier)).count == apps.count else { throw NSError(domain: "FixtureInstances", code: 1) }
            try await waitForExit()
            print("PASS: five distinct instances; explicit defaults/custom verified; every fixture process terminated normally.")
        } catch {
            try await waitForExit()
            throw error
        }
    }
}
