import AppKit
import Darwin
import SwitcherCore

// Explicit opt-in acceptance helper. Run only from a disposable macOS user or
// dedicated machine. It never controls the one pre-existing Current process.
@main
struct SmokeTest {
    @MainActor static func main() async {
        guard CommandLine.arguments.count == 4,
              CommandLine.arguments[3] == "--disposable-macos-user" else {
            fputs("Usage: swift run SwitcherSmokeTest /path/to/ChatGPT.app /absolute/NEW/scratch/root --disposable-macos-user\nRun only in a disposable macOS user or dedicated machine with exactly one normal Current instance. The helper never reads provider storage or credentials.\n", stderr)
            exit(2)
        }
        let candidate = URL(fileURLWithPath: CommandLine.arguments[1])
        let root = URL(fileURLWithPath: CommandLine.arguments[2])
        guard root.path.hasPrefix("/"), !FileManager.default.fileExists(atPath: root.path) else {
            fputs("Use a new absolute scratch root. Existing data is never accepted.\n", stderr)
            exit(2)
        }

        _ = NSApplication.shared
        let before = NSRunningApplication.runningApplications(withBundleIdentifier: Compatibility.bundleIdentifier)
            .filter { !$0.isTerminated }
        guard before.count == 1, let currentStamp = ProcessStamp.read(pid: before[0].processIdentifier) else {
            fputs("Refusing: exactly one normal Current instance must already be running.\n", stderr)
            exit(2)
        }

        var managedApp: NSRunningApplication?
        var managedReceipt: LaunchReceipt2?
        var managedProfile: ProfileRecord2?
        var managedPaths: Paths2?
        var identity: OfficialAppIdentity?
        var failure: Error?
        do {
            let report = try Compatibility.inspect(candidate)
            identity = OfficialAppIdentity(app: report.app, executable: report.executable, version: report.version)
            guard let identity,
                  currentStamp.uid == getuid(), currentStamp.executable == identity.executable.path,
                  before[0].bundleURL?.resolvingSymlinksInPath() == identity.app,
                  LiveCodeIdentity.matches(currentStamp, provider: .codex, identity: identity) else {
                throw SwitcherError.message("The pre-existing Current process does not match the selected official build.")
            }

            let store = try DynamicStore(root: root)
            try store.acquireLock()
            try store.migrateIfNeeded()
            var settings = try store.loadProvider(.codex)
            settings.appPath = identity.app.path
            settings.approvedFingerprint = report.fingerprint
            settings.setupComplete = true
            try store.saveProvider(settings)
            var profile = try store.createProfile(provider: .codex, name: "Disposable acceptance")
            let paths = try store.prepareStorage(for: profile)
            managedPaths = paths
            let intent = PendingLaunch2(fingerprint: report.fingerprint)
            profile.pending = intent
            try store.saveProfile(profile)

            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = false
            configuration.createsNewApplicationInstance = true
            configuration.allowsRunningApplicationSubstitution = false
            configuration.arguments = ["--user-data-dir=" + paths.electron.path]
            configuration.environment = [
                "HOME": FileManager.default.homeDirectoryForCurrentUser.path,
                "USER": NSUserName(), "LOGNAME": NSUserName(),
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": NSTemporaryDirectory(),
                "CODEX_HOME": paths.codexHome.path,
                "CODEX_ELECTRON_USER_DATA_PATH": paths.electron.path
            ]
            let existing = Set(before.map(\.processIdentifier))
            let app: NSRunningApplication = try await withCheckedThrowingContinuation { continuation in
                let gate = CompletionGate<NSRunningApplication> { continuation.resume(with: $0) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 20) {
                    gate.complete(.failure(SwitcherError.message("Disposable launch timed out; an unverified late process is left alone.")))
                }
                NSWorkspace.shared.openApplication(at: identity.app, configuration: configuration) { app, error in
                    if error != nil { gate.complete(.failure(SwitcherError.message("Disposable launch failed."))) }
                    else if let app { gate.complete(.success(app)) }
                    else { gate.complete(.failure(SwitcherError.message("Disposable launch returned no process."))) }
                }
            }
            guard let stamp = ProcessStamp.read(pid: app.processIdentifier),
                  LaunchReceipt.canAdopt(stamp, launchedAfter: intent.startedAt.timeIntervalSince1970,
                                         executable: identity.executable.path, uid: getuid(), existingPIDs: existing),
                  app.bundleURL?.resolvingSymlinksInPath() == identity.app,
                  LiveCodeIdentity.matches(stamp, provider: .codex, identity: identity) else {
                throw SwitcherError.message("The returned process did not prove live ownership and was left alone.")
            }
            let receipt = LaunchReceipt2(provider: .codex, profileID: profile.id,
                storageGeneration: profile.storageGeneration, launchID: intent.launchID,
                stamp: stamp, paths: paths, fingerprint: report.fingerprint)
            profile.receipt = receipt
            try store.saveProfile(profile)
            let after = try Compatibility.inspect(identity.app)
            guard after.fingerprint == report.fingerprint,
                  ProcessStamp.read(pid: stamp.pid) == stamp,
                  LiveCodeIdentity.matches(stamp, provider: .codex, identity: identity) else {
                throw SwitcherError.message("The build or process changed after launch; recovery metadata was retained.")
            }
            profile.pending = nil
            try store.saveProfile(profile)
            managedApp = app; managedReceipt = receipt; managedProfile = profile

            guard secureDirectory(paths.base), secureDirectory(paths.electron), secureDirectory(paths.codexHome) else {
                throw SwitcherError.message("Private directories were not created with safe ownership and permissions.")
            }
            guard ProcessStamp.read(pid: currentStamp.pid) == currentStamp else {
                throw SwitcherError.message("Current changed during the disposable launch.")
            }
            print("AUTOMATED PASS: Current preserved; disposable PID, live signature, receipt and opaque directories verified.")
            print("Visually verify that Current and Disposable show the intended separate test accounts. Type PASS to request a graceful close of Disposable only:")
            guard readLine() == "PASS" else { throw SwitcherError.message("Visual account-separation acceptance was not confirmed.") }
        } catch { failure = error }

        if let app = managedApp, let receipt = managedReceipt, let profile = managedProfile,
           let paths = managedPaths, let identity,
           let stamp = ProcessStamp.read(pid: app.processIdentifier),
           receipt.owns(stamp, profile: profile, paths: paths, uid: getuid()),
           LiveCodeIdentity.matches(stamp, provider: .codex, identity: identity) {
            if !app.terminate() { failure = SwitcherError.message("Disposable declined graceful close; close it manually.") }
            for _ in 0..<100 where !app.isTerminated { try? await Task.sleep(nanoseconds: 200_000_000) }
            if !app.isTerminated { failure = SwitcherError.message("Disposable remains open; it was not force-closed.") }
        }
        guard ProcessStamp.read(pid: currentStamp.pid) == currentStamp else {
            fputs("FAIL: Current was not preserved.\n", stderr); exit(1)
        }
        if let failure { fputs("FAIL: \(failure.localizedDescription)\n", stderr); exit(1) }
        print("ACCEPTANCE PASS: Current was preserved and only the verified disposable profile was closed. Scratch data remains at the supplied location for review.")
    }

    private static func secureDirectory(_ url: URL) -> Bool {
        var info = stat()
        return lstat(url.path, &info) == 0 && info.st_uid == getuid() &&
            info.st_mode & S_IFMT == S_IFDIR && info.st_mode & 0o077 == 0
    }
}
