import XCTest
import Darwin
@testable import SwitcherCore

final class CoreTests: XCTestCase {
    private func temporaryRoot() throws -> URL {
        let base = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("work")
            .appendingPathComponent("dual-account-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base.appendingPathComponent("private")
    }

    func testSecondAccountLaunchPlanIsIsolatedAndAllowlisted() {
        let root = URL(fileURLWithPath: "/Users/test/Library/Application Support/Switcher")
        let paths = ProfilePaths(root: root, id: .b)
        let plan = LaunchPlan(paths: paths, userHome: URL(fileURLWithPath: "/Users/test"), username: "test", temporaryDirectory: "/tmp/test")
        XCTAssertEqual(plan.environment["CODEX_HOME"], paths.home.path)
        XCTAssertEqual(plan.environment["CODEX_ELECTRON_USER_DATA_PATH"], paths.electron.path)
        XCTAssertEqual(plan.arguments, ["--user-data-dir=" + paths.electron.path])
        XCTAssertEqual(Set(plan.environment.keys), Set(["HOME", "USER", "LOGNAME", "PATH", "TMPDIR", "CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"]))
        XCTAssertNil(plan.environment["OPENAI_API_KEY"])
        XCTAssertNil(plan.environment["NODE_OPTIONS"])
        XCTAssertFalse(plan.environment.keys.contains { $0.hasPrefix("DYLD_") })
    }

    func testSecondaryOwnershipRejectsPIDReuseWrongUIDExecutableAndProfilePaths() {
        let root = URL(fileURLWithPath: "/Users/test/private")
        let paths = ProfilePaths(root: root, id: .b)
        let stamp = ProcessStamp(pid: 42, uid: 501, seconds: 100, microseconds: 1,
                                 executable: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
        let receipt = LaunchReceipt(profile: .b, stamp: stamp, paths: paths)
        XCTAssertTrue(receipt.owns(stamp, paths: paths, uid: 501))
        XCTAssertFalse(receipt.owns(nil, paths: paths, uid: 501))
        XCTAssertFalse(receipt.owns(stamp, paths: paths, uid: 502))
        XCTAssertFalse(receipt.owns(stamp, paths: ProfilePaths(root: root, id: .a), uid: 501))
        for changed in [
            ProcessStamp(pid: 42, uid: 501, seconds: 101, microseconds: 1, executable: stamp.executable),
            ProcessStamp(pid: 42, uid: 501, seconds: 100, microseconds: 2, executable: stamp.executable),
            ProcessStamp(pid: 42, uid: 502, seconds: 100, microseconds: 1, executable: stamp.executable),
            ProcessStamp(pid: 42, uid: 501, seconds: 100, microseconds: 1, executable: "/tmp/FakeChatGPT")
        ] {
            XCTAssertFalse(receipt.owns(changed, paths: paths, uid: 501))
        }
    }

    func testLegacyCurrentReceiptCanDecodeButCanNeverOwnAProcess() {
        let paths = ProfilePaths(root: URL(fileURLWithPath: "/Users/test/private"), id: .a)
        let stamp = ProcessStamp(pid: 42, uid: 501, seconds: 100, microseconds: 1, executable: "/official")
        let receipt = LaunchReceipt(profile: .a, stamp: stamp, paths: paths)
        XCTAssertFalse(receipt.owns(stamp, paths: paths, uid: 501))
    }

    func testLaunchCannotAdoptNormallyLaunchedOrOldInstance() {
        let stamp = ProcessStamp(pid: 42, uid: 501, seconds: 100, microseconds: 1, executable: "/official")
        XCTAssertTrue(LaunchReceipt.canAdopt(stamp, launchedAfter: 99, executable: "/official", uid: 501, existingPIDs: []))
        XCTAssertFalse(LaunchReceipt.canAdopt(stamp, launchedAfter: 101, executable: "/official", uid: 501, existingPIDs: []))
        XCTAssertFalse(LaunchReceipt.canAdopt(stamp, launchedAfter: 99, executable: "/official", uid: 501, existingPIDs: [42]))
        XCTAssertFalse(LaunchReceipt.canAdopt(stamp, launchedAfter: 99, executable: "/other", uid: 501, existingPIDs: []))
    }

    func testMetadataRoundtripAndPrivatePermissions() throws {
        let root = try temporaryRoot()
        let store = try PrivateStore(root: root)
        try store.acquireLock()
        try store.save(Settings(), name: "settings.json")
        let settings = try XCTUnwrap(store.load(Settings.self, name: "settings.json"))
        XCTAssertFalse(settings.setupComplete)
        XCTAssertEqual(settings.schemaVersion, Settings.currentSchemaVersion)

        let paths = try store.prepareSecondary()
        for url in [root, paths.home, paths.electron] {
            let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
            XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        }
        let attrs = try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("settings.json").path)
        XCTAssertEqual((attrs[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testStoreRefusesToCreatePrivateCurrentProfile() throws {
        let store = try PrivateStore(root: temporaryRoot())
        XCTAssertThrowsError(try store.prepare(.a))
        XCTAssertFalse(store.legacyCurrentProfileExists)
    }

    func testLegacySettingsWithoutSchemaDecodeWithSafeDefaults() throws {
        let json = #"{"appPath":"/Applications/ChatGPT.app","nameA":"Personal","nameB":"Work","approvedFingerprint":"abc","setupComplete":true}"#
        let settings = try JSONDecoder().decode(Settings.self, from: Data(json.utf8))
        XCTAssertEqual(settings.schemaVersion, 1)
        XCTAssertTrue(settings.needsSchemaRewrite)
        XCTAssertEqual(settings.nameA, "Personal")
        XCTAssertEqual(settings.nameB, "Work")
        XCTAssertEqual(settings.approvedFingerprint, "abc")
        XCTAssertTrue(settings.setupComplete)

        let encoded = try JSONEncoder().encode(settings)
        let rewritten = try JSONDecoder().decode(Settings.self, from: encoded)
        XCTAssertEqual(rewritten.schemaVersion, Settings.currentSchemaVersion)
        XCTAssertFalse(rewritten.needsSchemaRewrite)
    }

    func testMissingSettingsFieldsReceiveDefaults() throws {
        let settings = try JSONDecoder().decode(Settings.self, from: Data("{}".utf8))
        XCTAssertEqual(settings.appPath, "/Applications/ChatGPT.app")
        XCTAssertEqual(settings.nameA, "Current account")
        XCTAssertEqual(settings.nameB, "Second account")
        XCTAssertFalse(settings.setupComplete)
    }

    func testSecondAccountResetArchivesDirectoryWithoutDeletingContents() throws {
        let root = try temporaryRoot()
        let store = try PrivateStore(root: root)
        let paths = try store.prepareSecondary()
        let marker = paths.home.appendingPathComponent("marker.txt")
        try Data("keep-me".utf8).write(to: marker)
        XCTAssertTrue(store.secondaryProfileExists)

        let archived = try XCTUnwrap(store.archiveSecondaryProfile())
        XCTAssertFalse(store.secondaryProfileExists)
        XCTAssertTrue(FileManager.default.fileExists(atPath: archived.appendingPathComponent("codex/marker.txt").path))
        XCTAssertEqual(try String(contentsOf: archived.appendingPathComponent("codex/marker.txt")), "keep-me")

        let fresh = try store.prepareSecondary()
        XCTAssertNotEqual(fresh.home.standardizedFileURL.path, archived.appendingPathComponent("codex").standardizedFileURL.path)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fresh.home.appendingPathComponent("marker.txt").path))
    }

    func testSecondControllerCannotAcquireLock() throws {
        let root = try temporaryRoot()
        let first = try PrivateStore(root: root)
        try first.acquireLock()
        let second = try PrivateStore(root: root)
        XCTAssertThrowsError(try second.acquireLock())
    }

    func testSymlinkAndHardlinkMetadataRejectedWithoutTouchingDestination() throws {
        let root = try temporaryRoot()
        let store = try PrivateStore(root: root)
        let target = root.deletingLastPathComponent().appendingPathComponent("sentinel")
        try Data("untouched".utf8).write(to: target)
        let metadata = root.appendingPathComponent("settings.json")
        try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: target)
        XCTAssertThrowsError(try store.save(Settings(), name: "settings.json"))
        XCTAssertEqual(try String(contentsOf: target), "untouched")
        try FileManager.default.removeItem(at: metadata)
        try FileManager.default.linkItem(at: target, to: metadata)
        XCTAssertThrowsError(try store.load(Settings.self, name: "settings.json"))
    }

    func testRedirectedSecondaryProfileDirectoryRejected() throws {
        let root = try temporaryRoot()
        let store = try PrivateStore(root: root)
        let outside = root.deletingLastPathComponent().appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("Profiles"), withDestinationURL: outside)
        XCTAssertThrowsError(try store.prepareSecondary())
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
    }

    func testCorruptMetadataIsNotSilentlyReset() throws {
        let root = try temporaryRoot()
        let store = try PrivateStore(root: root)
        let file = root.appendingPathComponent("settings.json")
        try Data("broken".utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        XCTAssertThrowsError(try store.load(Settings.self, name: "settings.json"))
    }

    func testUnknownMetadataFileCannotReadProfileCredentials() throws {
        let store = try PrivateStore(root: temporaryRoot())
        XCTAssertThrowsError(try store.load(Settings.self, name: "Profiles/b/codex/auth.json"))
        XCTAssertThrowsError(try store.save(Settings(), name: "../elsewhere"))
    }

    func testOversizedMetadataCannotBeSaved() throws {
        let root = try temporaryRoot()
        let store = try PrivateStore(root: root)
        let huge = Array(repeating: ProfileID.b, count: 70_000)
        XCTAssertThrowsError(try store.save(huge, name: "pending.json"))
    }

    func testUnsignedAppRejectedByIdentityAndIsolationChecks() throws {
        let root = try temporaryRoot().deletingLastPathComponent()
        let app = root.appendingPathComponent("Fake.app/Contents")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        let plist: [String: String] = [
            "CFBundleIdentifier": "com.openai.codex",
            "CFBundleExecutable": "Fake",
            "CFBundlePackageType": "APPL"
        ]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertThrowsError(try Compatibility.inspectOfficialIdentity(root.appendingPathComponent("Fake.app")))
        XCTAssertThrowsError(try Compatibility.inspect(root.appendingPathComponent("Fake.app")))
    }

    func testStandardCompatibilityCandidatesAreDeduplicated() {
        let preferred = URL(fileURLWithPath: "/Applications/ChatGPT.app")
        let candidates = Compatibility.standardCandidates(preferred: preferred)
        XCTAssertEqual(candidates.map(\.path).filter { $0 == "/Applications/ChatGPT.app" }.count, 1)
        XCTAssertTrue(candidates.contains { $0.path.hasSuffix("Applications/ChatGPT.app") })
    }

    func testInvalidPIDHasNoSnapshot() {
        XCTAssertNil(ProcessStamp.read(pid: -1))
        XCTAssertNil(ProcessStamp.read(pid: 0))
    }

    func testPendingSecondLaunchSurvivesControllerRestart() throws {
        let root = try temporaryRoot()
        let first = try PrivateStore(root: root)
        try first.save([ProfileID.b], name: "pending.json")
        let restored = try PrivateStore(root: root)
        XCTAssertEqual(try restored.load([ProfileID].self, name: "pending.json"), [.b])
    }

    func testCompletionGateResolvesExactlyOnceUnderConcurrentCallbacks() {
        let lock = NSLock(); var count = 0
        let gate = CompletionGate<Int> { _ in
            lock.lock(); count += 1; lock.unlock()
        }
        DispatchQueue.concurrentPerform(iterations: 1000) { number in gate.complete(.success(number)) }
        gate.complete(.failure(SwitcherError.message("late timeout")))
        XCTAssertEqual(count, 1)
    }

    func testKernelSnapshotOfThisProcessIsStable() throws {
        let first = try XCTUnwrap(ProcessStamp.read(pid: getpid()))
        XCTAssertEqual(first.uid, getuid())
        XCTAssertEqual(first.pid, getpid())
        XCTAssertGreaterThan(first.seconds, 0)
        XCTAssertTrue(first.executable.hasPrefix("/"))
        XCTAssertEqual(ProcessStamp.read(pid: getpid()), first)
    }
}
