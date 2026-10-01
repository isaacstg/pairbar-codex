import Foundation
import XCTest
@testable import DualAccountSwitcher

final class InheritedEnvironmentSanitizerTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/private/tmp/pairbar-sanitizer-test")

    private func selected(_ environment: [String: String]) -> Set<String> {
        PairbarInheritedEnvironmentSanitizer.keysToRemove(environment: environment, pairbarRoot: root)
    }

    func testEachManagedCodexOverrideIsSelected() {
        XCTAssertEqual(selected(["CODEX_HOME": root.path + "/Profiles/b/codex"]), ["CODEX_HOME"])
        XCTAssertEqual(selected(["CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/codex/id/electron"]),
                       ["CODEX_ELECTRON_USER_DATA_PATH"])
    }

    func testBothManagedOverridesAreSelected() {
        XCTAssertEqual(selected(["CODEX_HOME": root.path + "/Profiles/b/codex",
                                 "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/codex/id/electron"]),
                       ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"])
    }

    func testManagedAndExternalCustomSelectsOnlyManaged() {
        XCTAssertEqual(selected(["CODEX_HOME": root.path + "/Profiles/b/codex",
                                 "CODEX_ELECTRON_USER_DATA_PATH": "/Volumes/Data/my-codex-electron"]),
                       ["CODEX_HOME"])
        XCTAssertEqual(selected(["CODEX_HOME": "/Users/foo/my-codex-home",
                                 "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/b/electron"]),
                       ["CODEX_ELECTRON_USER_DATA_PATH"])
    }

    func testExternalCustomAndMissingValuesArePreserved() {
        XCTAssertTrue(selected(["CODEX_HOME": "/Users/foo/my-codex-home"]).isEmpty)
        XCTAssertTrue(selected(["CODEX_ELECTRON_USER_DATA_PATH": "/Volumes/Data/my-codex-electron"]).isEmpty)
        XCTAssertTrue(selected([:]).isEmpty)
    }

    func testEmptyRelativeAndUnrecognizedValuesArePreserved() {
        XCTAssertTrue(selected(["CODEX_HOME": "", "CODEX_ELECTRON_USER_DATA_PATH": "relative/Profiles/b"]).isEmpty)
        XCTAssertTrue(selected(["CODEX_HOME": "~/.codex", "CODEX_ELECTRON_USER_DATA_PATH": "weird:value"]).isEmpty)
    }

    func testComponentBoundaryAndStandardizedPaths() {
        XCTAssertTrue(selected(["CODEX_HOME": root.path + "/Profiles-evil/codex"]).isEmpty)
        XCTAssertEqual(selected(["CODEX_HOME": root.path + "/Profiles/foo/../bar/"]), ["CODEX_HOME"])
        XCTAssertEqual(selected(["CODEX_HOME": root.path + "/Profiles/"]), ["CODEX_HOME"])
        XCTAssertEqual(selected(["CODEX_HOME": root.path + "/Profiles"]), ["CODEX_HOME"])
        XCTAssertTrue(selected(["CODEX_HOME": root.path + "/Profiles/../outside"]).isEmpty)
    }

    func testExistingRootAndMissingDescendantUseSameLexicalComponents() {
        // /private/tmp exists and may resolve to /tmp, while the fake profile does not.
        let root = URL(fileURLWithPath: "/private/tmp")
        XCTAssertEqual(PairbarInheritedEnvironmentSanitizer.keysToRemove(
            environment: ["CODEX_HOME": "/private/tmp/Profiles/codex/fake/codex"],
            pairbarRoot: root), ["CODEX_HOME"])
    }

    func testOnlyTwoCodexKeysCanBeRemoved() {
        let values = ["CODEX_HOME": root.path + "/Profiles/b/codex",
                      "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/b/electron",
                      "PAIRBAR_ENV_TEST": root.path + "/Profiles/b",
                      "PATH": root.path + "/Profiles/b", "HOME": root.path + "/Profiles/b",
                      "USER": root.path + "/Profiles/b", "TMPDIR": root.path + "/Profiles/b",
                      "CLAUDE_CONFIG_DIR": root.path + "/Profiles/b"]
        var removed: [String] = []
        PairbarInheritedEnvironmentSanitizer.apply(environment: values, pairbarRoot: root) { removed.append($0) }
        XCTAssertEqual(Set(removed), ["CODEX_HOME", "CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertEqual(removed.count, 2)
    }

    func testStartupSanitizesBeforeConstructingLaunchCapableObjects() {
        var events: [String] = []
        let constructed = PairbarStartup.run(
            environment: ["CODEX_HOME": root.path + "/Profiles/b/codex"], pairbarRoot: root,
            unset: { events.append("unset:\($0)") }, start: {
                events.append("construct runtime/controller")
                return true
            })
        XCTAssertTrue(constructed)
        XCTAssertEqual(events, ["unset:CODEX_HOME", "construct runtime/controller"])
    }

    func testManagedEnvironmentCannotLeakIntoNewCurrent() {
        var inherited = ["PAIRBAR_ENV_TEST": "sentinel",
                         "CODEX_HOME": root.path + "/Profiles/codex/fake/codex",
                         "CODEX_ELECTRON_USER_DATA_PATH": root.path + "/Profiles/codex/fake/electron"]
        PairbarInheritedEnvironmentSanitizer.apply(environment: inherited, pairbarRoot: root) {
            inherited.removeValue(forKey: $0)
        }
        let request = ProviderLaunchRequest.current(app: URL(fileURLWithPath: "/tmp/Fixture.app"),
                                                    hasManagedInstances: true)
        XCTAssertEqual(request.arguments, [])
        XCTAssertTrue(request.environment.isEmpty)
        XCTAssertTrue(request.createsNewInstance)
        XCTAssertNil(inherited["CODEX_HOME"])
        XCTAssertNil(inherited["CODEX_ELECTRON_USER_DATA_PATH"])
        XCTAssertEqual(inherited["PAIRBAR_ENV_TEST"], "sentinel")
    }

    func testCurrentManagedAndClaudeRequestsKeepTheirRecipes() {
        let app = URL(fileURLWithPath: "/tmp/Fixture.app")
        let ordinary = ProviderLaunchRequest.current(app: app, hasManagedInstances: false)
        let separate = ProviderLaunchRequest.current(app: app, hasManagedInstances: true)
        for request in [ordinary, separate] {
            XCTAssertEqual(request.arguments, [])
            XCTAssertTrue(request.environment.isEmpty)
        }
        XCTAssertFalse(ordinary.createsNewInstance)
        XCTAssertTrue(separate.createsNewInstance)
        // Claude Current uses this same request factory; it has no provider-specific overrides.
        let claudeCurrent = ProviderLaunchRequest.current(app: URL(fileURLWithPath: "/tmp/Claude.app"),
                                                         hasManagedInstances: false)
        XCTAssertEqual(claudeCurrent.arguments, [])
        XCTAssertTrue(claudeCurrent.environment.isEmpty)
        XCTAssertFalse(claudeCurrent.createsNewInstance)

        let electron = root.appendingPathComponent("Profiles/codex/id/electron")
        let home = root.appendingPathComponent("Profiles/codex/id/codex")
        let managed = ProviderLaunchRequest.codex(app: app, electron: electron, codexHome: home)
        XCTAssertEqual(managed.environment["CODEX_HOME"], home.path)
        XCTAssertEqual(managed.environment["CODEX_ELECTRON_USER_DATA_PATH"], electron.path)
        XCTAssertEqual(managed.arguments, ["--user-data-dir=" + electron.path])
        XCTAssertTrue(managed.createsNewInstance)
    }
}
