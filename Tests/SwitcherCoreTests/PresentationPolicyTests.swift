import XCTest
@testable import SwitcherCore

final class PresentationPolicyTests: XCTestCase {
    func testRenamingCannotApproveAnUpdateOrChangeAccountSetup() throws {
        var settings = Settings()
        settings.appPath = "/Applications/Selected.app"
        settings.approvedFingerprint = "previously-approved-build"
        settings.setupComplete = true
        let renamed = try settings.renamingAccounts(current: " Personal ", second: " Work ")
        var expected = settings
        expected.nameA = "Personal"
        expected.nameB = "Work"
        XCTAssertEqual(renamed, expected)
        XCTAssertEqual(IsolationReadiness.inspected(version: "new", fingerprint: "changed", settings: renamed),
                       .confirmationRequired(version: "new", isUpdate: true))
    }

    func testRenamingBeforeSetupCannotEnableSecondAccount() throws {
        let renamed = try Settings().renamingAccounts(current: "One", second: "Two")
        XCTAssertFalse(renamed.setupComplete)
        XCTAssertNil(renamed.approvedFingerprint)
        XCTAssertEqual(IsolationReadiness.inspected(version: "1", fingerprint: "build", settings: renamed),
                       .confirmationRequired(version: "1", isUpdate: false))
    }

    func testInvalidNamesAreRejected() {
        let invalidPairs = [("", "Second"), ("   ", "Second"), ("Same", " Same "),
                            (String(repeating: "a", count: 41), "Second"),
                            ("First\nName", "Second"), ("First\tName", "Second"),
                            ("First", "Second\u{0000}Name"), ("First\u{2028}Name", "Second")]
        for pair in invalidPairs {
            XCTAssertThrowsError(try Settings().renamingAccounts(current: pair.0, second: pair.1))
        }
    }

    func testReadinessRequiresBothSetupAndMatchingApproval() {
        var settings = Settings()
        settings.approvedFingerprint = "same"
        XCTAssertEqual(IsolationReadiness.inspected(version: "1", fingerprint: "same", settings: settings),
                       .confirmationRequired(version: "1", isUpdate: true))
        settings.setupComplete = true
        XCTAssertEqual(IsolationReadiness.inspected(version: "1", fingerprint: "same", settings: settings),
                       .ready(version: "1"))
        XCTAssertEqual(IsolationReadiness.inspected(version: "2", fingerprint: "new", settings: settings),
                       .confirmationRequired(version: "2", isUpdate: true))
    }

    func testUnavailableOrUncheckedBuildNeverOffersConfirmation() {
        XCTAssertFalse(IsolationReadiness.notChecked.requiresConfirmation)
        XCTAssertFalse(IsolationReadiness.checking.requiresConfirmation)
        XCTAssertFalse(IsolationReadiness.unavailable(reason: "Invalid official signature").requiresConfirmation)
        XCTAssertFalse(IsolationReadiness.ready(version: "1").requiresConfirmation)
        XCTAssertTrue(IsolationReadiness.confirmationRequired(version: "2", isUpdate: true).requiresConfirmation)
    }

    func testUpdateConfirmationCannotBypassRecoveryOrAnInFlightLifecycle() {
        XCTAssertTrue(SecondaryAccountState.stopped.allowsBuildConfirmation)
        XCTAssertTrue(SecondaryAccountState.runningVerified(pid: 42).allowsBuildConfirmation)
        for state in [SecondaryAccountState.launching, .quitting, .ownershipUncertain, .unverifiedLiveProcess] {
            XCTAssertFalse(state.allowsBuildConfirmation)
        }
    }
}
