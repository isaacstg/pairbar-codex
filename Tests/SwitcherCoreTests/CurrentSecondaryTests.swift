import XCTest
@testable import SwitcherCore

final class CurrentSecondaryTests: XCTestCase {
    private let secondaryPaths = ProfilePaths(root: URL(fileURLWithPath: "/Users/test/private"), id: .b)

    func testCurrentAbsent() {
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [], verifiedSecondaryPID: nil), .stopped)
    }

    func testCurrentExactlyOne() {
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [42], verifiedSecondaryPID: nil), .running(pid: 42))
    }

    func testVerifiedSecondaryIsExcludedFromCurrentCandidates() {
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [42, 84], verifiedSecondaryPID: 84), .running(pid: 42))
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [84], verifiedSecondaryPID: 84), .stopped)
    }

    func testUnverifiedSecondaryIsNotBlindlyExcludedFromCurrentCandidates() {
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [42, 84], verifiedSecondaryPID: nil), .ambiguous(count: 2))
    }

    func testCurrentDiscoveryBlocksWhileSecondaryOwnershipIsUncertain() {
        XCTAssertEqual(
            AccountStateResolver.current(officialPIDs: [42], verifiedSecondaryPID: nil,
                                         secondaryOwnershipUncertain: true),
            .blockedBySecondaryRecovery(count: 1)
        )
        XCTAssertEqual(
            AccountStateResolver.current(officialPIDs: [], verifiedSecondaryPID: nil,
                                         secondaryOwnershipUncertain: true),
            .blockedBySecondaryRecovery(count: 0)
        )
    }

    func testMultipleDefaultInstancesAreAmbiguousAndNeverGuessed() {
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [10, 20, 30], verifiedSecondaryPID: 30), .ambiguous(count: 2))
    }

    func testCurrentPIDListIsDeduplicatedAndInvalidPIDsIgnored() {
        XCTAssertEqual(AccountStateResolver.currentCandidatePIDs(officialPIDs: [42, 42, -1, 0], verifiedSecondaryPID: nil), [42])
    }

    func testCurrentLaunchingOnlyWhenNoResolvedCandidate() {
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [], verifiedSecondaryPID: nil, launching: true), .launching)
        XCTAssertEqual(AccountStateResolver.current(officialPIDs: [42], verifiedSecondaryPID: nil, launching: true), .running(pid: 42))
    }

    func testSecondaryVerifiedOwnership() {
        let stamp = ProcessStamp(pid: 84, uid: 501, seconds: 100, microseconds: 1, executable: "/official")
        let receipt = LaunchReceipt(profile: .b, stamp: stamp, paths: secondaryPaths)
        XCTAssertEqual(
            AccountStateResolver.secondary(receipt: receipt, currentStamp: stamp, paths: secondaryPaths, uid: 501,
                                           pending: false, launching: false, quitting: false, recordedPIDIsLive: true),
            .runningVerified(pid: 84)
        )
    }

    func testSecondaryPIDReuseOrWrongIdentityIsNeverOwned() {
        let original = ProcessStamp(pid: 84, uid: 501, seconds: 100, microseconds: 1, executable: "/official")
        let reused = ProcessStamp(pid: 84, uid: 501, seconds: 101, microseconds: 1, executable: "/official")
        let receipt = LaunchReceipt(profile: .b, stamp: original, paths: secondaryPaths)
        XCTAssertEqual(
            AccountStateResolver.secondary(receipt: receipt, currentStamp: reused, paths: secondaryPaths, uid: 501,
                                           pending: false, launching: false, quitting: false, recordedPIDIsLive: true),
            .unverifiedLiveProcess
        )
    }

    func testSecondaryStaleReceiptBecomesStoppedWhenRecordedPIDIsGone() {
        let stamp = ProcessStamp(pid: 84, uid: 501, seconds: 100, microseconds: 1, executable: "/official")
        let receipt = LaunchReceipt(profile: .b, stamp: stamp, paths: secondaryPaths)
        XCTAssertEqual(
            AccountStateResolver.secondary(receipt: receipt, currentStamp: nil, paths: secondaryPaths, uid: 501,
                                           pending: false, launching: false, quitting: false, recordedPIDIsLive: false),
            .stopped
        )
    }

    func testPendingSecondaryTakesPrecedenceAndBlocksOwnershipAssumptions() {
        let stamp = ProcessStamp(pid: 84, uid: 501, seconds: 100, microseconds: 1, executable: "/official")
        let receipt = LaunchReceipt(profile: .b, stamp: stamp, paths: secondaryPaths)
        XCTAssertEqual(
            AccountStateResolver.secondary(receipt: receipt, currentStamp: stamp, paths: secondaryPaths, uid: 501,
                                           pending: true, launching: false, quitting: false, recordedPIDIsLive: true),
            .ownershipUncertain
        )
    }

    func testQuittingAndLaunchingStatesAreExplicit() {
        XCTAssertEqual(
            AccountStateResolver.secondary(receipt: nil, currentStamp: nil, paths: secondaryPaths, uid: 501,
                                           pending: false, launching: true, quitting: false, recordedPIDIsLive: false),
            .launching
        )
        XCTAssertEqual(
            AccountStateResolver.secondary(receipt: nil, currentStamp: nil, paths: secondaryPaths, uid: 501,
                                           pending: false, launching: false, quitting: true, recordedPIDIsLive: false),
            .quitting
        )
    }

    func testCapabilitiesKeepCurrentIndependentFromSecondarySetup() {
        let caps = AccountCapabilities(current: .stopped, secondary: .stopped,
                                       secondarySetupComplete: false, compatibilityBusy: false)
        XCTAssertTrue(caps.canOpenCurrent)
        XCTAssertFalse(caps.canOpenSecond)
        XCTAssertFalse(caps.canOpenBoth)
    }

    func testCapabilitiesAllowFocusAndLifecycleOnlyForVerifiedSecond() {
        let caps = AccountCapabilities(current: .running(pid: 1), secondary: .runningVerified(pid: 2),
                                       secondarySetupComplete: true, compatibilityBusy: false)
        XCTAssertTrue(caps.canOpenCurrent)
        XCTAssertTrue(caps.canOpenSecond)
        XCTAssertTrue(caps.canOpenBoth)
        XCTAssertTrue(caps.canQuitSecond)
        XCTAssertTrue(caps.canRestartSecond)
        XCTAssertFalse(caps.canRecoverSecond)
    }

    func testCapabilitiesFailClosedForAmbiguousCurrentAndUncertainSecond() {
        let caps = AccountCapabilities(current: .ambiguous(count: 2), secondary: .ownershipUncertain,
                                       secondarySetupComplete: true, compatibilityBusy: false)
        XCTAssertFalse(caps.canOpenCurrent)
        XCTAssertFalse(caps.canOpenSecond)
        XCTAssertFalse(caps.canOpenBoth)
        XCTAssertFalse(caps.canQuitSecond)
        XCTAssertFalse(caps.canRestartSecond)
        XCTAssertTrue(caps.canRecoverSecond)
    }

    func testCapabilitiesBlockCurrentDuringSecondaryRecovery() {
        let caps = AccountCapabilities(current: .blockedBySecondaryRecovery(count: 1), secondary: .ownershipUncertain,
                                       secondarySetupComplete: true, compatibilityBusy: false)
        XCTAssertFalse(caps.canOpenCurrent)
        XCTAssertFalse(caps.canOpenSecond)
        XCTAssertFalse(caps.canOpenBoth)
        XCTAssertTrue(caps.canRecoverSecond)
    }

    func testCompatibilityBusyOnlyBlocksSecondAccountActions() {
        let caps = AccountCapabilities(current: .running(pid: 1), secondary: .runningVerified(pid: 2),
                                       secondarySetupComplete: true, compatibilityBusy: true)
        XCTAssertTrue(caps.canOpenCurrent)
        XCTAssertFalse(caps.canOpenSecond)
        XCTAssertTrue(caps.canQuitSecond)
        XCTAssertFalse(caps.canRestartSecond)
    }

    func testLegacyMetadataMigrationDropsAWithoutTouchingB() throws {
        let aPaths = ProfilePaths(root: URL(fileURLWithPath: "/private"), id: .a)
        let bPaths = ProfilePaths(root: URL(fileURLWithPath: "/private"), id: .b)
        let a = LaunchReceipt(profile: .a,
                              stamp: ProcessStamp(pid: 1, uid: 501, seconds: 1, microseconds: 0, executable: "/official"),
                              paths: aPaths)
        let b = LaunchReceipt(profile: .b,
                              stamp: ProcessStamp(pid: 2, uid: 501, seconds: 2, microseconds: 0, executable: "/official"),
                              paths: bPaths)
        XCTAssertEqual(try MetadataMigration.keepSecondaryReceipts([a, b]), [b])
        XCTAssertEqual(MetadataMigration.keepSecondaryPending([.a, .b]), [.b])
        XCTAssertEqual(MetadataMigration.keepSecondaryPending([.a]), [])
    }

    func testDuplicateSecondaryReceiptsAreRejected() {
        let stamp = ProcessStamp(pid: 2, uid: 501, seconds: 2, microseconds: 0, executable: "/official")
        let b = LaunchReceipt(profile: .b, stamp: stamp, paths: secondaryPaths)
        XCTAssertThrowsError(try MetadataMigration.keepSecondaryReceipts([b, b]))
    }
}
