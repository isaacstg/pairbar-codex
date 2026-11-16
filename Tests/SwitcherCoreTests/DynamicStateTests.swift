import XCTest
import Foundation
import Darwin
@testable import SwitcherCore

final class DynamicStateTests: XCTestCase {
    // Pure values only: this root is never opened and no real process is observed or controlled.
    private let root = URL(fileURLWithPath: "/synthetic/pairbar", isDirectory: true)
    private func stamp(_ pid: Int32, seconds: UInt64 = 500, uid: UInt32 = getuid()) -> ProcessStamp {
        ProcessStamp(pid: pid, uid: uid, seconds: seconds, microseconds: 10,
                     executable: "/Applications/ChatGPT.app/Contents/MacOS/ChatGPT")
    }
    private func profile(_ name: String, pid: Int32? = nil, provider: ProviderID2 = .codex) -> ProfileRecord2 {
        var value = ProfileRecord2(provider: provider, name: name)
        if let pid {
            value.receipt = LaunchReceipt2(provider: provider, profileID: value.id,
                storageGeneration: value.storageGeneration, stamp: stamp(pid),
                paths: Paths2(root: root, provider: provider, storage: value.storage), fingerprint: "approved-test-build")
        }
        return value
    }
    private func resolve(_ profiles: [ProfileRecord2], official: [Int32],
                         observations: [Int32: ProcessObservation2], provider: ProviderID2 = .codex,
                         launching: Set<ManagedProfileID> = [], quitting: Set<ManagedProfileID> = [],
                         currentLaunching: Bool = false, metadataUncertain: Bool = false) -> ProviderState2 {
        DynamicStateResolver.resolve(provider: provider, records: profiles, root: root,
            officialPIDs: official, observations: observations, uid: getuid(), launching: launching,
            quitting: quitting, currentLaunching: currentLaunching, metadataUncertain: metadataUncertain)
    }

    func testCurrentExcludesEveryVerifiedManagedProcessWithoutDependingOnOrder() {
        let first = profile("One", pid: 11), second = profile("Two", pid: 22)
        let observations: [Int32: ProcessObservation2] = [11: .verified(stamp(11)), 22: .verified(stamp(22)), 33: .verified(stamp(33))]
        for profiles in [[first, second], [second, first]] {
            let state = resolve(profiles, official: [33, 22, 11, 33], observations: observations)
            XCTAssertEqual(state.current, .running(pid: 33))
            XCTAssertEqual(state.profiles[first.id], .runningVerified(pid: 11))
            XCTAssertEqual(state.profiles[second.id], .runningVerified(pid: 22))
            XCTAssertFalse(state.needsRecovery)
        }
    }

    func testCurrentIsStoppedWhenOnlyManagedProcessesAreRunning() {
        let first = profile("One", pid: 11), second = profile("Two", pid: 22)
        let state = resolve([first, second], official: [11, 22], observations: [11: .verified(stamp(11)), 22: .verified(stamp(22))])
        XCTAssertEqual(state.current, .stopped)
        XCTAssertFalse(state.needsRecovery)
    }

    func testCurrentCannotChooseAmongMultipleUnmanagedOfficialProcesses() {
        let state = resolve([], official: [11, 22], observations: [11: .verified(stamp(11)), 22: .verified(stamp(22))])
        XCTAssertEqual(state.current, .ambiguous(count: 2))
        XCTAssertFalse(state.needsRecovery)
    }

    func testPendingBlocksCurrentEvenWhenNoOfficialProcessesAreEnumerated() {
        var record = profile("One")
        record.pending = PendingLaunch2(fingerprint: "approved-test-build")
        let stopped = resolve([record], official: [], observations: [:])
        XCTAssertEqual(stopped.current, .blockedByRecovery)
        XCTAssertEqual(stopped.profiles[record.id], .ownershipUncertain)
        XCTAssertTrue(stopped.needsRecovery)
        let launching = resolve([record], official: [], observations: [:], launching: [record.id])
        XCTAssertEqual(launching.current, .blockedByRecovery)
        XCTAssertEqual(launching.profiles[record.id], .launching)
    }

    func testMatchingReceiptDoesNotOverridePendingIntent() {
        var record = profile("One", pid: 11)
        record.pending = PendingLaunch2(launchID: record.receipt!.launchID, fingerprint: "approved-test-build")
        let state = resolve([record], official: [11], observations: [11: .verified(stamp(11))])
        XCTAssertEqual(state.current, .blockedByRecovery)
        XCTAssertEqual(state.profiles[record.id], .ownershipUncertain)
        XCTAssertNil(state.profiles[record.id]?.verifiedPID)
    }

    func testAbsentAndUnreadableAreDifferentAndEnumerationDisagreementBlocks() {
        let record = profile("One", pid: 11)
        let absent = resolve([record], official: [], observations: [11: .absent])
        XCTAssertEqual(absent.current, .stopped)
        XCTAssertEqual(absent.profiles[record.id], .stopped)
        XCTAssertFalse(absent.needsRecovery)
        for observations in [[Int32: ProcessObservation2](), [11: .unreadable], [11: .absent]] {
            let official: [Int32] = observations[11] == .absent ? [11] : []
            let uncertain = resolve([record], official: official, observations: observations)
            XCTAssertEqual(uncertain.current, .blockedByRecovery)
            XCTAssertEqual(uncertain.profiles[record.id], .unverifiedLiveProcess)
            XCTAssertTrue(uncertain.needsRecovery)
        }
    }

    func testPIDReuseAndIdentityMismatchNeverGrantOwnership() {
        let record = profile("One", pid: 11)
        for observed in [stamp(11, seconds: 501), stamp(11, uid: getuid() &+ 1), stamp(12)] {
            let state = resolve([record], official: [11], observations: [11: .verified(observed)])
            XCTAssertEqual(state.current, .blockedByRecovery)
            XCTAssertEqual(state.profiles[record.id], .unverifiedLiveProcess)
            XCTAssertNil(state.profiles[record.id]?.verifiedPID)
        }
    }

    func testReceiptWithoutOfficialEnumerationCannotBeUsedToControlOrClassify() {
        let record = profile("One", pid: 11)
        let state = resolve([record], official: [], observations: [11: .verified(stamp(11))])
        XCTAssertEqual(state.current, .blockedByRecovery)
        XCTAssertEqual(state.profiles[record.id], .unverifiedLiveProcess)
    }

    func testUnknownOfficialCandidateBlocksCurrentWithoutReceipt() {
        for observations in [[Int32: ProcessObservation2](), [11: .unreadable], [11: .absent]] {
            let state = resolve([], official: [11], observations: observations)
            XCTAssertEqual(state.current, .blockedByRecovery)
            XCTAssertTrue(state.needsRecovery)
        }
    }

    func testDuplicatePIDsInvalidateBothProfilesAndCannotSelectWinner() {
        let first = profile("One", pid: 11), second = profile("Two", pid: 11)
        for profiles in [[first, second], [second, first]] {
            let state = resolve(profiles, official: [11], observations: [11: .verified(stamp(11))])
            XCTAssertEqual(state.profiles[first.id], .ownershipUncertain)
            XCTAssertEqual(state.profiles[second.id], .ownershipUncertain)
            XCTAssertEqual(state.current, .blockedByRecovery)
        }
    }

    func testCrossProviderPIDCollisionBlocksBothProviders() {
        let codex = profile("Codex", pid: 11), claude = profile("Claude", pid: 11, provider: .claude)
        for provider in ProviderID2.allCases {
            let state = resolve([codex, claude], official: [11], observations: [11: .verified(stamp(11))], provider: provider)
            XCTAssertEqual(state.current, .blockedByRecovery)
            XCTAssertTrue(state.needsRecovery)
        }
    }

    func testDuplicateStorageAndDuplicateIdentityFailClosed() {
        let first = profile("One")
        var second = profile("Two"); second.storage = first.storage
        let paths = resolve([first, second], official: [], observations: [:])
        XCTAssertEqual(paths.current, .blockedByRecovery)
        XCTAssertEqual(paths.profiles[first.id], .ownershipUncertain)
        XCTAssertEqual(paths.profiles[second.id], .ownershipUncertain)
        let identities = resolve([first, first], official: [], observations: [:])
        XCTAssertEqual(identities.current, .blockedByRecovery)
    }

    func testProviderUncertaintyDoesNotBlockAnotherProvider() {
        var codex = profile("Codex")
        codex.pending = PendingLaunch2(fingerprint: "approved-test-build")
        let claude = resolve([codex], official: [22], observations: [22: .verified(stamp(22))], provider: .claude)
        XCTAssertEqual(claude.current, .running(pid: 22))
        XCTAssertFalse(claude.needsRecovery)
        XCTAssertTrue(claude.profiles.isEmpty)
    }

    func testExplicitMetadataUncertaintyBlocksCurrentWithoutFabricatingProcess() {
        let state = resolve([profile("One")], official: [], observations: [:], metadataUncertain: true)
        XCTAssertEqual(state.current, .blockedByRecovery)
        XCTAssertTrue(state.needsRecovery)
        XCTAssertTrue(state.profiles.values.allSatisfy { $0 == .stopped })
    }

    func testArchiveCannotHideALiveReceiptAndLegacyStorageCannotBelongToClaude() {
        var archived = profile("Archived", pid: 11); archived.archived = true
        let state = resolve([archived], official: [11], observations: [11: .verified(stamp(11))])
        XCTAssertEqual(state.current, .blockedByRecovery)
        XCTAssertEqual(state.profiles[archived.id], .ownershipUncertain)
        var claude = profile("Wrong legacy", provider: .claude); claude.storage = .legacySecond
        let invalid = resolve([claude], official: [], observations: [:], provider: .claude)
        XCTAssertEqual(invalid.current, .blockedByRecovery)
    }

    func testStorageGenerationMismatchInvalidatesReceipt() {
        var record = profile("One", pid: 11); record.storageGeneration = UUID()
        let state = resolve([record], official: [11], observations: [11: .verified(stamp(11))])
        XCTAssertEqual(state.current, .blockedByRecovery)
        XCTAssertEqual(state.profiles[record.id], .unverifiedLiveProcess)
    }

    func testQuittingOwnedProcessRemainsExcludedFromCurrent() {
        let record = profile("One", pid: 11)
        let state = resolve([record], official: [11, 22], observations: [11: .verified(stamp(11)), 22: .verified(stamp(22))], quitting: [record.id])
        XCTAssertEqual(state.profiles[record.id], .quitting)
        XCTAssertEqual(state.current, .running(pid: 22))
        XCTAssertFalse(state.needsRecovery)
    }

    func testUIInFlightFlagCannotReplaceDurableIntent() {
        let record = profile("One")
        for state in [resolve([record], official: [], observations: [:], launching: [record.id]),
                      resolve([record], official: [], observations: [:], quitting: [record.id])] {
            XCTAssertEqual(state.current, .blockedByRecovery)
            XCTAssertEqual(state.profiles[record.id], .ownershipUncertain)
        }
        XCTAssertEqual(resolve([], official: [], observations: [:], currentLaunching: true).current, .launching)
    }

    func testTenThousandSavedProfilesResolveWithoutAnyOpenInstances() {
        let records = (0..<10_000).map { profile("Synthetic \($0)") }
        let state = resolve(records, official: [], observations: [:])
        XCTAssertEqual(state.current, .stopped)
        XCTAssertEqual(state.profiles.count, 10_000)
        XCTAssertFalse(state.needsRecovery)
        XCTAssertTrue(state.profiles.values.allSatisfy { $0 == .stopped })
    }
}
