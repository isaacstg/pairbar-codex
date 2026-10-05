import Foundation
import XCTest
@testable import DualAccountSwitcher

final class CurrentCodexLaunchEnvironmentTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/private/tmp/pairbar-current-test")
    private let home = URL(fileURLWithPath: "/private/tmp/pairbar-current-home")
    private var codexDefault: String { home.path + "/.codex" }
    private var electronDefault: String { home.path + "/Library/Application Support/Codex" }

    private func resolve(_ environment: [String: String]) throws -> CurrentCodexLaunchEnvironment {
        try CurrentCodexLaunchEnvironment(environment: environment, pairbarRoot: root, home: home,
                                         username: "fixture", temporaryDirectory: "/private/tmp/fixture-temp/")
    }

    private func assertPaths(_ initial: [String: String], codex: String? = nil, electron: String? = nil,
                             file: StaticString = #filePath, line: UInt = #line) throws {
        let context = try resolve(initial)
        XCTAssertEqual(Array(context.codexHome.utf8), Array((codex ?? codexDefault).utf8), file: file, line: line)
        XCTAssertEqual(Array(context.electronUserDataPath.utf8), Array((electron ?? electronDefault).utf8), file: file, line: line)
        XCTAssertEqual(context.environment["CODEX_HOME"], context.codexHome, file: file, line: line)
        XCTAssertEqual(context.environment["CODEX_ELECTRON_USER_DATA_PATH"], context.electronUserDataPath, file: file, line: line)
        for separate in [false, true] {
            let request = ProviderLaunchRequest.current(app: root.appendingPathComponent("Fixture.app"),
                hasManagedInstances: separate, currentEnvironment: context)
            XCTAssertEqual(request.environment, ["HOME": home.path, "USER": "fixture", "LOGNAME": "fixture",
                "PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "TMPDIR": "/private/tmp/fixture-temp/",
                "CODEX_HOME": codex ?? codexDefault, "CODEX_ELECTRON_USER_DATA_PATH": electron ?? electronDefault],
                file: file, line: line)
            XCTAssertEqual(request.arguments.map { Array($0.utf8) }, [Array(("--user-data-dir=" + (electron ?? electronDefault)).utf8)],
                           file: file, line: line)
            XCTAssertEqual(request.arguments, request.environment["CODEX_ELECTRON_USER_DATA_PATH"].map { ["--user-data-dir=" + $0] },
                           file: file, line: line)
            XCTAssertNotEqual(PairbarCodexEnvironmentValue.classify(String(request.arguments[0].dropFirst("--user-data-dir=".count)),
                pairbarRoot: root), .managed, file: file, line: line)
            XCTAssertEqual(request.createsNewInstance, separate, file: file, line: line)
            XCTAssertFalse(request.environment.isEmpty, file: file, line: line)
            XCTAssertTrue(PairbarInheritedEnvironmentSanitizer.keysToRemove(environment: request.environment,
                pairbarRoot: root).isEmpty, file: file, line: line)
        }
    }

    func testMissingStartupEnvironmentUsesExplicitDefaults() throws { try assertPaths([:]) }
    func testBothExternalCustomPathsArePreserved() throws {
        try assertPaths(["CODEX_HOME": "/private/custom/codex", "CODEX_ELECTRON_USER_DATA_PATH": "/private/custom/electron"],
                        codex: "/private/custom/codex", electron: "/private/custom/electron")
    }
    func testOnlyCustomCodexHomeUsesElectronDefault() throws {
        try assertPaths(["CODEX_HOME": "/private/custom/codex"], codex: "/private/custom/codex")
    }
    func testOnlyCustomElectronUsesCodexDefault() throws {
        try assertPaths(["CODEX_ELECTRON_USER_DATA_PATH": "/private/custom/electron"], electron: "/private/custom/electron")
    }
    func testManagedCodexHomeUsesDefault() throws {
        try assertPaths(["CODEX_HOME": root.path + "/Profiles/b/codex"])
    }
    func testManagedElectronUsesDefault() throws {
        try assertPaths(["CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/x/electron"])
    }
    func testBothManagedPathsUseDefaults() throws {
        try assertPaths(["CODEX_HOME": root.path + "/Profiles/b/codex",
                         "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/b/electron"])
    }
    func testManagedHomeWithCustomElectronKeepsOnlyCustom() throws {
        try assertPaths(["CODEX_HOME": root.path + "/Profiles/b/codex",
                         "CODEX_ELECTRON_USER_DATA_PATH": "/private/custom/electron"], electron: "/private/custom/electron")
    }
    func testCustomHomeWithManagedElectronKeepsOnlyCustom() throws {
        try assertPaths(["CODEX_HOME": "/private/custom/codex",
                         "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/b/electron"], codex: "/private/custom/codex")
    }
    func testProfilesEvilIsExternalAtComponentBoundary() throws {
        let path = root.path + "/Profiles-evil/codex"
        try assertPaths(["CODEX_HOME": path, "CODEX_ELECTRON_USER_DATA_PATH": path], codex: path, electron: path)
    }
    func testDotComponentsShareSanitizerPolicy() throws {
        for path in [root.path + "/Profiles/foo/../bar/", root.path + "/./Profiles/b/codex", root.path + "/Profiles"] {
            XCTAssertEqual(PairbarInheritedEnvironmentSanitizer.keysToRemove(environment: ["CODEX_HOME": path],
                pairbarRoot: root), ["CODEX_HOME"])
            try assertPaths(["CODEX_HOME": path, "CODEX_ELECTRON_USER_DATA_PATH": path])
        }
        let outside = root.path + "/Profiles/../outside"
        try assertPaths(["CODEX_HOME": outside, "CODEX_ELECTRON_USER_DATA_PATH": outside], codex: outside, electron: outside)
    }
    func testExternalValuesArePreservedByteForByte() throws {
        let path = "/private/custom//with space/./child/../cafe\u{301}/"
        try assertPaths(["CODEX_HOME": path, "CODEX_ELECTRON_USER_DATA_PATH": path], codex: path, electron: path)
    }
    func testUnresolvableValuesUseDefaultsWithoutChangingStartupSanitizer() throws {
        for path in ["", "relative/Profiles/b", "~/.codex", "weird:value", "/private/custom\0invalid"] {
            try assertPaths(["CODEX_HOME": path, "CODEX_ELECTRON_USER_DATA_PATH": path])
            XCTAssertTrue(PairbarInheritedEnvironmentSanitizer.keysToRemove(environment: ["CODEX_HOME": path],
                                                                          pairbarRoot: root).isEmpty)
        }
    }
    func testUnsafeInjectedDefaultFailsClosed() {
        XCTAssertThrowsError(try CurrentCodexLaunchEnvironment(environment: [:], pairbarRoot: root,
            home: root.appendingPathComponent("Profiles/b"), username: "fixture", temporaryDirectory: "/private/tmp/"))
    }
    func testCurrentLaunchDoesNotReuseManagedCodexEnvironment() throws {
        let workHome = root.appendingPathComponent("Profiles/b/codex")
        let workElectron = root.appendingPathComponent("Profiles/b/electron")
        let context = try resolve(["CODEX_HOME": workHome.path, "CODEX_ELECTRON_USER_DATA_PATH": workElectron.path])
        let app = root.appendingPathComponent("Fixture.app")
        let work = ProviderLaunchRequest.codex(app: app, electron: workElectron, codexHome: workHome,
            home: home, username: "fixture", temporaryDirectory: "/private/tmp/")
        let current = ProviderLaunchRequest.current(app: app, hasManagedInstances: true, currentEnvironment: context)
        XCTAssertEqual(current.arguments, ["--user-data-dir=" + context.electronUserDataPath])
        XCTAssertNotEqual(current.environment["CODEX_HOME"], work.environment["CODEX_HOME"])
        XCTAssertNotEqual(current.environment["CODEX_ELECTRON_USER_DATA_PATH"], work.environment["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertEqual(current.environment["CODEX_HOME"], codexDefault)
        XCTAssertEqual(current.environment["CODEX_ELECTRON_USER_DATA_PATH"], electronDefault)
        XCTAssertTrue(PairbarInheritedEnvironmentSanitizer.keysToRemove(environment: current.environment, pairbarRoot: root).isEmpty)
    }
    func testManagedRequestKeepsExactIsolatedRecipe() {
        let electron = root.appendingPathComponent("Profiles/b/electron")
        let codex = root.appendingPathComponent("Profiles/b/codex")
        let request = ProviderLaunchRequest.codex(app: root.appendingPathComponent("Fixture.app"), electron: electron, codexHome: codex,
            home: home, username: "fixture", temporaryDirectory: "/private/tmp/")
        var expected = ProviderLaunchRequest.baseEnvironment(home: home, username: "fixture", temporaryDirectory: "/private/tmp/")
        expected["CODEX_HOME"] = codex.path
        expected["CODEX_ELECTRON_USER_DATA_PATH"] = electron.path
        XCTAssertEqual(request.environment, expected)
        XCTAssertEqual(request.arguments, ["--user-data-dir=" + electron.path])
        XCTAssertTrue(request.createsNewInstance)
    }
    func testClaudeCurrentRequestKeepsEmptyEnvironmentAndInstanceSemantics() {
        for separate in [false, true] {
            let request = ProviderLaunchRequest.currentClaude(app: root.appendingPathComponent("ClaudeFixture.app"), hasManagedInstances: separate)
            XCTAssertEqual(request.environment, [:])
            XCTAssertEqual(request.arguments, [])
            XCTAssertEqual(request.createsNewInstance, separate)
        }
    }
    func testStartupCapturesImmutableContextBeforeSanitizing() throws {
        var original = ["CODEX_HOME": "/private/custom/codex",
                        "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/b/electron"]
        let context = try PairbarStartup.run(environment: original, pairbarRoot: root, home: home,
            username: "fixture", temporaryDirectory: "/private/tmp/", unset: { original.removeValue(forKey: $0) }) { context in
                XCTAssertNil(original["CODEX_ELECTRON_USER_DATA_PATH"])
                return context
            }
        original["CODEX_HOME"] = root.path + "/Profiles/b/codex"
        XCTAssertEqual(context.environment["CODEX_HOME"], "/private/custom/codex")
        XCTAssertEqual(context.environment["CODEX_ELECTRON_USER_DATA_PATH"], electronDefault)
    }
    func testUnrelatedStartupVariablesAreNotForwarded() throws {
        let context = try resolve(["NODE_OPTIONS": "fixture", "UNRELATED": "sentinel", "PATH": "/private/custom/bin"])
        XCTAssertNil(context.environment["NODE_OPTIONS"])
        XCTAssertNil(context.environment["UNRELATED"])
        XCTAssertEqual(context.environment["PATH"], "/usr/bin:/bin:/usr/sbin:/sbin")
    }
}
