import AppKit
import Foundation
import Darwin
import ProcessIdentity
import SwitcherCore

enum ProcessObservation {
    case observed(ProcessStamp)
    case absent
    case unavailable
}

struct RunningInstance {
    let pid: Int32
    let appURL: URL?
}

struct ProviderInspection {
    let identity: OfficialAppIdentity
    let fingerprint: String?
    let managedLaunchAllowed: Bool
    let detail: String
}

protocol ProviderInspecting {
    func identity(provider: ProviderID2, at url: URL) async throws -> OfficialAppIdentity
    func inspect(provider: ProviderID2, at url: URL) async throws -> ProviderInspection
}

struct InstalledProviderInspector: ProviderInspecting {
    func identity(provider: ProviderID2, at url: URL) async throws -> OfficialAppIdentity {
        try await Task.detached(priority: .userInitiated) {
            switch provider {
            case .codex: return try Compatibility.inspectOfficialIdentity(url)
            case .claude: return try ClaudeCompatibility.inspectOfficialIdentity(url)
            }
        }.value
    }

    func inspect(provider: ProviderID2, at url: URL) async throws -> ProviderInspection {
        try await Task.detached(priority: .userInitiated) {
            switch provider {
            case .codex:
                let report = try Compatibility.inspect(url)
                return ProviderInspection(identity: OfficialAppIdentity(app: report.app, executable: report.executable,
                    version: report.version), fingerprint: report.fingerprint, managedLaunchAllowed: true,
                    detail: "Static compatibility checked; account separation requires live acceptance.")
            case .claude:
                let report = try ClaudeCompatibility.inspect(url)
                return ProviderInspection(identity: report.identity, fingerprint: report.fingerprint,
                    managedLaunchAllowed: report.managedLaunchAllowed,
                    detail: "Managed Claude profiles require signed-in Chat and Code acceptance.")
            }
        }.value
    }
}

struct ProviderLaunchRequest {
    let app: URL
    let arguments: [String]
    let environment: [String: String]
    let createsNewInstance: Bool

    static func baseEnvironment(home: URL = FileManager.default.homeDirectoryForCurrentUser,
                                username: String = NSUserName(), temporaryDirectory: String = NSTemporaryDirectory()) -> [String: String] {
        ["HOME": home.path, "USER": username, "LOGNAME": username,
         "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": temporaryDirectory]
    }

    static func current(app: URL, hasManagedInstances: Bool) -> Self {
        Self(app: app, arguments: [], environment: [:], createsNewInstance: hasManagedInstances)
    }

    static func codex(app: URL, electron: URL, codexHome: URL) -> Self {
        var environment = baseEnvironment()
        environment["CODEX_HOME"] = codexHome.path
        environment["CODEX_ELECTRON_USER_DATA_PATH"] = electron.path
        return Self(app: app, arguments: ["--user-data-dir=" + electron.path],
                    environment: environment, createsNewInstance: true)
    }
}

@MainActor
protocol ApplicationRuntime {
    func running(provider: ProviderID2) -> [RunningInstance]
    func observe(pid: Int32) -> ProcessObservation
    func open(_ request: ProviderLaunchRequest) async throws -> Int32
    func verifyLiveIdentity(_ stamp: ProcessStamp, provider: ProviderID2, identity: OfficialAppIdentity) -> Bool
    func activate(_ stamp: ProcessStamp, provider: ProviderID2) -> Bool
    func terminate(_ stamp: ProcessStamp, provider: ProviderID2) -> Bool
    func pause() async
    var now: Date { get }
    var uid: UInt32 { get }
}

@MainActor
final class NativeApplicationRuntime: ApplicationRuntime {
    var now: Date { Date() }
    var uid: UInt32 { getuid() }

    private func bundleID(_ provider: ProviderID2) -> String {
        provider == .codex ? Compatibility.bundleIdentifier : "com.anthropic.claudefordesktop"
    }

    func running(provider: ProviderID2) -> [RunningInstance] {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleID(provider)).filter { !$0.isTerminated }.map { app in
            RunningInstance(pid: app.processIdentifier, appURL: app.bundleURL)
        }
    }

    func observe(pid: Int32) -> ProcessObservation {
        var snapshot = DAProcessSnapshot()
        let result = da_observe(pid, &snapshot)
        guard result == 1 else { return result == 0 ? .absent : .unavailable }
        let executable = withUnsafePointer(to: &snapshot.executable) {
            $0.withMemoryRebound(to: CChar.self, capacity: 4096) { String(cString: $0) }
        }
        return .observed(ProcessStamp(pid: pid, uid: snapshot.uid, seconds: snapshot.seconds,
            microseconds: snapshot.microseconds, executable: executable))
    }

    private func exactApplication(_ stamp: ProcessStamp, provider: ProviderID2) -> NSRunningApplication? {
        guard case .observed(let live) = observe(pid: stamp.pid), live == stamp,
              live.uid == uid, let application = NSRunningApplication(processIdentifier: stamp.pid),
              !application.isTerminated, application.bundleIdentifier == bundleID(provider),
              application.executableURL?.resolvingSymlinksInPath().path == stamp.executable else { return nil }
        return application
    }

    func verifyLiveIdentity(_ stamp: ProcessStamp, provider: ProviderID2, identity: OfficialAppIdentity) -> Bool {
        guard stamp.executable == identity.executable.path,
              let application = exactApplication(stamp, provider: provider),
              application.bundleURL?.resolvingSymlinksInPath() == identity.app else { return false }
        return LiveCodeIdentity.matches(stamp, provider: provider, identity: identity)
    }

    func activate(_ stamp: ProcessStamp, provider: ProviderID2) -> Bool {
        guard let app = exactApplication(stamp, provider: provider) else { return false }
        return app.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
    }

    func terminate(_ stamp: ProcessStamp, provider: ProviderID2) -> Bool {
        guard let app = exactApplication(stamp, provider: provider) else { return false }
        return app.terminate()
    }

    func pause() async { try? await Task.sleep(nanoseconds: 200_000_000) }

    func open(_ request: ProviderLaunchRequest) async throws -> Int32 {
        let configuration = NSWorkspace.OpenConfiguration()
        // Focus is allowed only after the controller verifies the returned process and receipt.
        configuration.activates = false
        configuration.createsNewApplicationInstance = request.createsNewInstance
        configuration.allowsRunningApplicationSubstitution = false
        configuration.arguments = request.arguments
        if !request.environment.isEmpty { configuration.environment = request.environment }
        return try await withCheckedThrowingContinuation { continuation in
            let gate = CompletionGate<Int32> { continuation.resume(with: $0) }
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                gate.complete(.failure(SwitcherError.message("launch_timeout")))
            }
            NSWorkspace.shared.openApplication(at: request.app, configuration: configuration) { app, error in
                if error != nil { gate.complete(.failure(SwitcherError.message("launch_failed"))) }
                else if let app { gate.complete(.success(app.processIdentifier)) }
                else { gate.complete(.failure(SwitcherError.message("launch_missing_process"))) }
            }
        }
    }
}
