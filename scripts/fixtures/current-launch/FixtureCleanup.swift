import AppKit
let root = URL(fileURLWithPath: CommandLine.arguments[1])
guard root.path.hasPrefix("/private/tmp/pairbar-current-launch.") else { fatalError("Unsafe cleanup root") }
let id = try String(contentsOf: root.appendingPathComponent("bundle-id"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
let expected = root.appendingPathComponent("EnvironmentFixture.app")
for _ in 0..<140 {
    let apps = NSRunningApplication.runningApplications(withBundleIdentifier: id).filter { !$0.isTerminated && $0.bundleURL?.path == expected.path }
    if apps.isEmpty { exit(0) }
    for app in apps { _ = app.terminate() }
    RunLoop.current.run(until: Date().addingTimeInterval(0.5))
}
fatalError("Fixture still running; preserved scratch for safe cleanup")
