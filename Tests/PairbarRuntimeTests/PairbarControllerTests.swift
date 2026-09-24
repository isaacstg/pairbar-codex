import Darwin
import Foundation
import XCTest
@testable import DualAccountSwitcher
import SwitcherCore

@MainActor
final class PairbarControllerTests: XCTestCase {
    private let fingerprint = "test-codex-fingerprint"

    func testCreatingProfilesAssignsPersistentFreeDigitsWithoutChangingExistingShortcuts() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        XCTAssertEqual(controller.providers[.codex]?.currentShortcut, .legacyCurrent)
        controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "One"))
        controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "Two"))
        XCTAssertEqual(controller.records.map(\.shortcut), [.legacySecond, Shortcut2(keyCode: 20, modifiers: 2304)])
        let first = try XCTUnwrap(controller.records.first)
        controller.saveDraft(id: first.id.description, draft: PairbarProfileDraft(name: "One", shortcut: PairbarShortcut(keyCode: 0, modifiers: 256)))
        controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "Three"))
        XCTAssertEqual(controller.records.last?.shortcut, .legacySecond)
        XCTAssertEqual(try fixture.store.listProfiles().last?.shortcut, .legacySecond)
        XCTAssertEqual(controller.records.first?.shortcut, Shortcut2(keyCode: 0, modifiers: 256))
    }

    func testProfileCreationContinuesAfterAllNumericShortcutsAreUsed() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        for number in 1...11 {
            controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "Account \(number)"))
        }
        XCTAssertEqual(controller.records.count, 11)
        XCTAssertEqual(Set(controller.records.compactMap(\.shortcut)).count, 9)
        XCTAssertEqual(controller.records[8].shortcut, Shortcut2(keyCode: 29, modifiers: 2304))
        XCTAssertNil(controller.records[9].shortcut)
        XCTAssertNil(controller.records[10].shortcut)
        let reloaded = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        XCTAssertEqual(reloaded.records.map(\.shortcut), controller.records.map(\.shortcut))
    }

    func testUnavailableSystemChordSkipsToNextFreeDigit() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        controller.replaceShortcuts = { bindings in !bindings.contains { $0.keyCode == 19 } }
        controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "Work"))
        XCTAssertEqual(controller.records.first?.shortcut, Shortcut2(keyCode: 20, modifiers: 2304))
    }

    func testFailedProfilePersistenceRestoresExactlyPreviousShortcutBindings() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        let original = controller.shortcutBindings()
        var installed = original
        var sawCandidate = false
        controller.replaceShortcuts = { bindings in
            installed = bindings
            if bindings.count == original.count + 1 { sawCandidate = true }
            return true
        }
        let directory = fixture.root.appendingPathComponent("Metadata/profiles/codex")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "Cannot persist"))
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        XCTAssertTrue(sawCandidate)
        XCTAssertEqual(installed, original)
        XCTAssertTrue(controller.records.isEmpty)
        XCTAssertTrue(try fixture.store.listProfiles(provider: .codex).isEmpty)
    }

    func testNewBuildNeedsOneContextualApprovalThenOpensWithoutAskingAgain() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = try fixture.addProfile(provider: .codex, name: "New build")
        let later = try fixture.addProfile(provider: .codex, name: "Later build")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let runtime = FakeRuntime()
        let firstStamp = inspector.stamp(provider: .codex, pid: 700, seconds: 101)
        let secondStamp = inspector.stamp(provider: .codex, pid: 701, seconds: 102)
        runtime.openHandler = { _ in
            let stamp = runtime.openRequests.count == 1 ? firstStamp : secondStamp
            runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
            return stamp.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        var approvals = 0
        controller.confirmNewBuild = { _ in approvals += 1; return true }
        let firstOpen = await controller.open(.managed(profile.id))
        XCTAssertTrue(firstOpen)
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, fingerprint)
        let secondOpen = await controller.open(.managed(later.id))
        XCTAssertTrue(secondOpen)
        XCTAssertEqual(approvals, 1)
        XCTAssertEqual(runtime.openRequests.count, 2)
        XCTAssertEqual(try fixture.store.listProfiles(provider: .codex).filter { $0.receipt != nil }.count, 2)
    }

    func testOpenSelectedCancelPromptsOnceAndLaunchesNothing() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try fixture.addProfile(provider: .codex, name: "First")
        let second = try fixture.addProfile(provider: .codex, name: "Second")
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector(codexFingerprint: fingerprint))
        var prompts = 0
        controller.confirmNewBuild = { _ in prompts += 1; return false }

        await controller.openBatch([.managed(first.id), .managed(second.id)])

        XCTAssertEqual(prompts, 1)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertNil(try fixture.store.loadProvider(.codex).approvedFingerprint)
        XCTAssertTrue(try fixture.store.listProfiles(provider: .codex).allSatisfy { $0.pending == nil })
    }

    func testOpenSelectedApprovePromptsOnceAndLaunchesBoth() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let first = try fixture.addProfile(provider: .codex, name: "First")
        let second = try fixture.addProfile(provider: .codex, name: "Second")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let runtime = FakeRuntime()
        runtime.openHandler = { _ in
            let stamp = inspector.stamp(provider: .codex, pid: Int32(710 + runtime.openRequests.count), seconds: UInt64(100 + runtime.openRequests.count))
            runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
            return stamp.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        var prompts = 0
        controller.confirmNewBuild = { _ in prompts += 1; return true }

        await controller.openBatch([.managed(first.id), .managed(second.id)])

        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(runtime.openRequests.count, 2)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, fingerprint)
    }

    func testDeclinedBuildAndAutomaticLoginNeverApproveOrLaunch() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = try fixture.addProfile(provider: .codex, name: "Blocked")
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector())
        controller.confirmNewBuild = { _ in false }
        let declinedOpen = await controller.open(.managed(profile.id))
        XCTAssertFalse(declinedOpen)
        await controller.openBatch([.managed(profile.id)], automatic: true)
        XCTAssertNil(try fixture.store.loadProvider(.codex).approvedFingerprint)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertNil(try fixture.store.listProfiles().first?.pending)
    }

    func testBuildChangeDuringContextualApprovalFailsClosed() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let profile = try fixture.addProfile(provider: .codex, name: "Changed")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        inspector.inspectionResponses[.codex] = [
            inspector.report(provider: .codex, fingerprint: fingerprint, managedLaunchAllowed: true),
            inspector.report(provider: .codex, fingerprint: "changed-during-approval", managedLaunchAllowed: true)
        ]
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        controller.confirmNewBuild = { _ in true }
        let opened = await controller.open(.managed(profile.id))
        XCTAssertFalse(opened)
        XCTAssertNil(try fixture.store.loadProvider(.codex).approvedFingerprint)
        XCTAssertNil(try fixture.store.listProfiles().first?.pending)
        XCTAssertTrue(runtime.openRequests.isEmpty)
    }

    func testApprovalPersistenceFailurePreventsLaunchAndKeepsDurableOldApproval() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: "old-build")
        let profile = try fixture.addProfile(provider: .codex, name: "Needs approval")
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector(codexFingerprint: fingerprint))
        controller.confirmNewBuild = { _ in true }
        let providerFile = fixture.root.appendingPathComponent("Metadata/providers/codex.json")
        let extraLink = fixture.root.appendingPathComponent("Metadata/providers/.test-hardlink")
        try FileManager.default.linkItem(at: providerFile, to: extraLink)
        let opened = await controller.open(.managed(profile.id))
        try FileManager.default.removeItem(at: extraLink)

        XCTAssertFalse(opened)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, "old-build")
        XCTAssertEqual(controller.providers[.codex]?.approvedFingerprint, "old-build")
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
    }

    func testPersistedApprovalCanStillAbortWhenOwnershipChangesBeforeLaunch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let profile = try fixture.addProfile(provider: .codex, name: "Needs approval")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let runtime = FakeRuntime()
        var injected = false
        runtime.runningHook = {
            guard !injected, (try? fixture.store.loadProvider(.codex).approvedFingerprint) == self.fingerprint else { return }
            injected = true
            let stranger = inspector.stamp(provider: .codex, pid: 730, seconds: 101)
            runtime.runningInstances[.codex] = [RunningInstance(pid: stranger.pid, appURL: nil)]
            runtime.processObservations[stranger.pid] = .observed(stranger)
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        controller.confirmNewBuild = { _ in true }

        let opened = await controller.open(.managed(profile.id))

        XCTAssertFalse(opened)
        XCTAssertTrue(injected)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, fingerprint)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
        XCTAssertEqual(controller.states[.codex]?.needsRecovery, true)
    }

    func testCurrentAccountCanOnlyBeActivatedAndNeverTerminated() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let runtime = FakeRuntime()
        let inspector = FakeInspector()
        let stamp = inspector.stamp(provider: .codex, pid: 301, seconds: 101)
        runtime.runningInstances[.codex] = [RunningInstance(pid: stamp.pid, appURL: inspector.identity(for: .codex).app)]
        runtime.processObservations[stamp.pid] = .observed(stamp)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        let opened = await controller.open(.current(.codex))

        XCTAssertTrue(opened)
        XCTAssertEqual(runtime.activated, [stamp])
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(runtime.openRequests.isEmpty)
    }

    func testManagedLaunchPersistsIntentBeforeOpenAndExactReceiptAfterVerification() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: fingerprint)
        let profile = try fixture.addProfile(provider: .codex, name: "Work")
        let runtime = FakeRuntime()
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 401, seconds: 101)
        var intentSeenAtOpen: PendingLaunch2?
        var receiptWasAlreadyPresentAtOpen = false
        runtime.openHandler = { request in
            let durable = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id })
            intentSeenAtOpen = durable.pending
            receiptWasAlreadyPresentAtOpen = durable.receipt != nil
            runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
            XCTAssertEqual(request.arguments, ["--user-data-dir=" + fixture.store.paths(for: profile).electron.path])
            return stamp.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        let opened = await controller.open(.managed(profile.id))

        XCTAssertTrue(opened)
        XCTAssertNotNil(intentSeenAtOpen)
        XCTAssertFalse(receiptWasAlreadyPresentAtOpen)
        let durable = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id })
        let receipt = try XCTUnwrap(durable.receipt)
        XCTAssertNil(durable.pending)
        XCTAssertEqual(receipt.launchID, intentSeenAtOpen?.launchID)
        XCTAssertEqual(receipt.profileID, profile.id)
        XCTAssertEqual(receipt.provider, .codex)
        XCTAssertEqual(receipt.storageGeneration, profile.storageGeneration)
        XCTAssertEqual(receipt.stamp, stamp)
        XCTAssertEqual(receipt.electron, fixture.store.paths(for: profile).electron.path)
        XCTAssertEqual(receipt.codexHome, fixture.store.paths(for: profile).codexHome.path)
        XCTAssertEqual(receipt.fingerprint, fingerprint)
        XCTAssertEqual(runtime.activated, [stamp])
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testManagedLaunchRechecksProviderOwnershipAfterSuspendedInspection() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: fingerprint)
        let target = try fixture.addProfile(provider: .codex, name: "Target")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let existingStamp = inspector.stamp(provider: .codex, pid: 400, seconds: 100)
        _ = try fixture.addOwnedProfile(name: "Existing", stamp: existingStamp, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        runtime.install(existingStamp, provider: .codex, app: inspector.identity(for: .codex).app)
        inspector.suspendNextInspection = true
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        let opening = Task { await controller.open(.managed(target.id)) }
        for _ in 0..<1_000 {
            if inspector.inspectionPauseCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(inspector.inspectionPauseCount, 1)
        runtime.processObservations[existingStamp.pid] = .unavailable
        inspector.releaseInspection()

        let opened = await opening.value
        XCTAssertFalse(opened)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        let durable = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first { $0.id == target.id })
        XCTAssertNil(durable.pending)
        XCTAssertNil(durable.receipt)
        XCTAssertEqual(controller.states[.codex]?.profiles[target.id], .stopped)
        XCTAssertTrue(controller.states[.codex]?.needsRecovery == true)
    }

    func testFailureAfterLaunchPreservesPendingAndReceiptForRecovery() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: fingerprint)
        let profile = try fixture.addProfile(provider: .codex, name: "Recovery")
        let runtime = FakeRuntime()
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        inspector.inspectionResponses[.codex] = [
            inspector.report(provider: .codex, fingerprint: fingerprint, managedLaunchAllowed: true),
            inspector.report(provider: .codex, fingerprint: "changed-after-launch", managedLaunchAllowed: true)
        ]
        let stamp = inspector.stamp(provider: .codex, pid: 402, seconds: 101)
        runtime.openHandler = { _ in
            runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
            return stamp.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        let opened = await controller.open(.managed(profile.id))

        XCTAssertFalse(opened)
        let durable = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id })
        let pending = try XCTUnwrap(durable.pending)
        let receipt = try XCTUnwrap(durable.receipt)
        XCTAssertEqual(receipt.launchID, pending.launchID)
        XCTAssertEqual(receipt.stamp, stamp)
        XCTAssertEqual(receipt.fingerprint, fingerprint)
        XCTAssertTrue(runtime.activated.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(controller.states[.codex]?.needsRecovery == true)
    }

    func testReturnedPIDMustBeEnumeratedAndPassLiveCodeIdentity() async throws {
        for liveIdentityAllowed in [true, false] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            try fixture.approveCodex(fingerprint: fingerprint)
            let profile = try fixture.addProfile(provider: .codex, name: liveIdentityAllowed ? "Not enumerated" : "Wrong live code")
            let runtime = FakeRuntime()
            runtime.liveIdentityAllowed = liveIdentityAllowed
            let inspector = FakeInspector(codexFingerprint: fingerprint)
            let stamp = inspector.stamp(provider: .codex, pid: liveIdentityAllowed ? 403 : 404, seconds: 101)
            runtime.openHandler = { _ in
                runtime.processObservations[stamp.pid] = .observed(stamp)
                if !liveIdentityAllowed {
                    runtime.runningInstances[.codex] = [RunningInstance(pid: stamp.pid, appURL: inspector.identity(for: .codex).app)]
                }
                return stamp.pid
            }
            let controller = try fixture.controller(runtime: runtime, inspector: inspector)

            let opened = await controller.open(.managed(profile.id))
            XCTAssertFalse(opened)
            let durable = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id })
            XCTAssertNotNil(durable.pending)
            XCTAssertNil(durable.receipt)
            XCTAssertTrue(runtime.activated.isEmpty)
            XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        }
    }

    func testGracefulCloseTimeoutPreservesReceipt() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 405, seconds: 100)
        let profile = try fixture.addOwnedProfile(name: "Timeout", stamp: stamp, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        let closed = await controller.close(profile.id)
        XCTAssertFalse(closed)
        XCTAssertEqual(runtime.terminationAttempts, [stamp])
        XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id }?.receipt)
    }

    func testRecoveryRechecksForNewProcessBeforeClearingPending() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Pending recovery")
        profile.pending = PendingLaunch2(fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        runtime.suspendPauses = true
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        let recovery = Task { await controller.recover(.codex) }
        for _ in 0..<1_000 {
            if runtime.pauseCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(runtime.pauseCount, 1)
        let appeared = inspector.stamp(provider: .codex, pid: 406, seconds: 101)
        runtime.install(appeared, provider: .codex, app: inspector.identity(for: .codex).app)
        runtime.releasePause()
        await recovery.value

        XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id }?.pending)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testReusedOrUnreadablePIDBlocksCloseWithoutSendingTerminate() async throws {
        for mode in InvalidObservation.allCases {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let inspector = FakeInspector(codexFingerprint: fingerprint)
            let original = inspector.stamp(provider: .codex, pid: mode.pid, seconds: 100)
            let profile = try fixture.addOwnedProfile(name: mode.rawValue, stamp: original, fingerprint: fingerprint)
            let runtime = FakeRuntime()
            runtime.runningInstances[.codex] = [RunningInstance(pid: original.pid, appURL: inspector.identity(for: .codex).app)]
            switch mode {
            case .reused:
                runtime.processObservations[original.pid] = .observed(
                    inspector.stamp(provider: .codex, pid: original.pid, seconds: original.seconds + 1)
                )
            case .unreadable:
                runtime.processObservations[original.pid] = .unavailable
            }
            let controller = try fixture.controller(runtime: runtime, inspector: inspector)

            let closed = await controller.close(profile.id)

            XCTAssertFalse(closed, mode.rawValue)
            XCTAssertTrue(runtime.terminationAttempts.isEmpty, mode.rawValue)
            XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id }?.receipt)
        }
    }

    func testResidualClaudeReceiptCannotCloseOrRestartEvenWhenProcessIdentityVerifies() async throws {
        for operation in ["close", "restart"] {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let fingerprint = "test-claude-fingerprint"
            var settings = try fixture.store.loadProvider(.claude)
            settings.approvedFingerprint = fingerprint
            settings.setupComplete = true
            try fixture.store.saveProvider(settings)

            let inspector = FakeInspector()
            inspector.inspectionResponses[.claude] = [
                inspector.report(provider: .claude, fingerprint: fingerprint, managedLaunchAllowed: true)
            ]
            let stamp = inspector.stamp(provider: .claude, pid: operation == "close" ? 420 : 421, seconds: 100)
            var profile = ProfileRecord2(provider: .claude, name: "Residual Claude " + operation)
            profile.receipt = LaunchReceipt2(provider: .claude, profileID: profile.id,
                storageGeneration: profile.storageGeneration, stamp: stamp,
                paths: fixture.store.paths(for: profile), fingerprint: fingerprint)
            try fixture.store.saveProfile(profile)

            let runtime = FakeRuntime()
            runtime.install(stamp, provider: .claude, app: inspector.identity(for: .claude).app)
            let controller = try fixture.controller(runtime: runtime, inspector: inspector)
            await controller.identify(.claude)
            XCTAssertEqual(controller.states[.claude]?.profiles[profile.id], .runningVerified(pid: stamp.pid))

            if operation == "close" {
                let closed = await controller.close(profile.id)
                XCTAssertFalse(closed)
            } else {
                await controller.restart(profile.id)
            }

            XCTAssertTrue(runtime.terminationAttempts.isEmpty, operation)
            XCTAssertTrue(runtime.openRequests.isEmpty, operation)
            XCTAssertEqual(try fixture.store.listProfiles(provider: .claude).first?.receipt?.stamp, stamp, operation)
        }
    }

    func testRestartHoldsProviderExclusionThroughCloseAndReplacementOpen() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: fingerprint)
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let oldStamp = inspector.stamp(provider: .codex, pid: 501, seconds: 100)
        let profile = try fixture.addOwnedProfile(name: "Restart", stamp: oldStamp, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        runtime.runningInstances[.codex] = [RunningInstance(pid: oldStamp.pid, appURL: inspector.identity(for: .codex).app)]
        runtime.processObservations[oldStamp.pid] = .observed(oldStamp)
        runtime.suspendPauses = true
        let newStamp = inspector.stamp(provider: .codex, pid: 502, seconds: 102)
        runtime.openHandler = { _ in
            runtime.install(newStamp, provider: .codex, app: inspector.identity(for: .codex).app)
            return newStamp.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        let restart = Task { await controller.restart(profile.id) }
        for _ in 0..<1_000 {
            if runtime.pauseCount > 0 { break }
            await Task.yield()
        }
        XCTAssertEqual(runtime.pauseCount, 1)

        let competingOpen = await controller.open(.current(.codex))
        XCTAssertFalse(competingOpen)
        XCTAssertTrue(runtime.openRequests.isEmpty)

        runtime.runningInstances[.codex] = []
        runtime.processObservations[oldStamp.pid] = .absent
        runtime.releasePause()
        await restart.value

        XCTAssertEqual(runtime.terminationAttempts, [oldStamp])
        XCTAssertEqual(runtime.openRequests.count, 1)
        XCTAssertFalse(runtime.openRequests[0].arguments.isEmpty)
        let durable = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first { $0.id == profile.id })
        XCTAssertNil(durable.pending)
        XCTAssertEqual(durable.receipt?.stamp, newStamp)
    }

    func testRestartNewBuildCancelPreservesRunningProcessWithoutApproval() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: "old-build")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 720, seconds: 100)
        let profile = try fixture.addOwnedProfile(name: "Running", stamp: stamp, fingerprint: "old-build")
        let runtime = FakeRuntime(); runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        var prompts = 0
        controller.confirmNewBuild = { _ in prompts += 1; return false }

        await controller.restart(profile.id)

        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(inspector.inspectionCount, 1)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, "old-build")
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertEqual(try fixture.store.listProfiles(provider: .codex).first?.receipt?.stamp, stamp)
    }

    func testRestartNewBuildApprovesThenClosesVerifiedProcessAndLaunches() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: "old-build")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let old = inspector.stamp(provider: .codex, pid: 721, seconds: 100)
        let next = inspector.stamp(provider: .codex, pid: 722, seconds: 102)
        let profile = try fixture.addOwnedProfile(name: "Running", stamp: old, fingerprint: "old-build")
        let runtime = FakeRuntime(); runtime.install(old, provider: .codex, app: inspector.identity(for: .codex).app)
        runtime.pauseHandler = {
            runtime.runningInstances[.codex] = []
            runtime.processObservations[old.pid] = .absent
        }
        runtime.openHandler = { _ in
            runtime.install(next, provider: .codex, app: inspector.identity(for: .codex).app)
            return next.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        var prompts = 0
        controller.confirmNewBuild = { _ in
            prompts += 1
            XCTAssertTrue(runtime.terminationAttempts.isEmpty)
            return true
        }

        await controller.restart(profile.id)

        XCTAssertEqual(prompts, 1)
        XCTAssertGreaterThanOrEqual(inspector.inspectionCount, 4)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, fingerprint)
        XCTAssertEqual(runtime.terminationAttempts, [old])
        XCTAssertEqual(runtime.openRequests.count, 1)
        let durable = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first)
        XCTAssertNil(durable.pending)
        XCTAssertEqual(durable.receipt?.stamp, next)
    }

    func testRestartBuildChangeDuringApprovalDoesNotCloseOrApprove() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: "old-build")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        inspector.inspectionResponses[.codex] = [
            inspector.report(provider: .codex, fingerprint: fingerprint, managedLaunchAllowed: true),
            inspector.report(provider: .codex, fingerprint: "changed-during-alert", managedLaunchAllowed: true)
        ]
        let stamp = inspector.stamp(provider: .codex, pid: 723, seconds: 100)
        let profile = try fixture.addOwnedProfile(name: "Running", stamp: stamp, fingerprint: "old-build")
        let runtime = FakeRuntime(); runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        var prompts = 0
        controller.confirmNewBuild = { _ in prompts += 1; return true }

        await controller.restart(profile.id)

        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(inspector.inspectionCount, 2)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, "old-build")
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(runtime.openRequests.isEmpty)
    }

    func testRestartOwnershipChangeDuringApprovalDoesNotCloseOrLaunch() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: "old-build")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 724, seconds: 100)
        let profile = try fixture.addOwnedProfile(name: "Running", stamp: stamp, fingerprint: "old-build")
        let runtime = FakeRuntime(); runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        controller.confirmNewBuild = { _ in
            runtime.processObservations[stamp.pid] = .observed(inspector.stamp(provider: .codex, pid: stamp.pid, seconds: 101))
            return true
        }

        await controller.restart(profile.id)

        XCTAssertEqual(try fixture.store.loadProvider(.codex).approvedFingerprint, "old-build")
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertEqual(try fixture.store.listProfiles(provider: .codex).first?.receipt?.stamp, stamp)
        XCTAssertEqual(controller.states[.codex]?.needsRecovery, true)
    }

    func testRestartOldProcessCannotMatchInstalledBuildFailsClosedWithGuidance() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: "old-build")
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 725, seconds: 100)
        let profile = try fixture.addOwnedProfile(name: "Running", stamp: stamp, fingerprint: "old-build")
        let runtime = FakeRuntime(); runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
        runtime.liveIdentityAllowed = false
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        controller.confirmNewBuild = { _ in true }

        await controller.restart(profile.id)

        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertEqual(try fixture.store.listProfiles(provider: .codex).first?.receipt?.stamp, stamp)
        XCTAssertTrue(controller.model.errorMessage?.contains("Close that ChatGPT app normally") == true)
    }

    func testLoginOpeningRequiresLoginEventGlobalOptInAndPerProfileSelection() async throws {
        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            let selected = try fixture.addProfile(provider: .codex, name: "Selected", launchAtLogin: true, order: 1)
            _ = try fixture.addProfile(provider: .codex, name: "Not selected", launchAtLogin: false, order: 0)
            _ = try fixture.addProfile(provider: .claude, name: "Claude selected", launchAtLogin: true, order: 0)
            try fixture.approveCodex(fingerprint: fingerprint)
            var preferences = try fixture.store.loadPreferences()
            preferences.launchSelectedAtLogin = true
            try fixture.store.savePreferences(preferences)
            let runtime = FakeRuntime()
            let inspector = FakeInspector(codexFingerprint: fingerprint)
            let selectedStamp = inspector.stamp(provider: .codex, pid: 601, seconds: 101)
            let selectedPaths = fixture.store.paths(for: selected)
            runtime.openHandler = { request in
                runtime.install(selectedStamp, provider: .codex, app: inspector.identity(for: .codex).app)
                XCTAssertEqual(request.environment["CODEX_HOME"], selectedPaths.codexHome.path)
                return selectedStamp.pid
            }
            let controller = try fixture.controller(runtime: runtime, inspector: inspector)

            await controller.launchAtLogin(isLoginEvent: false)
            XCTAssertTrue(runtime.openRequests.isEmpty)

            await controller.launchAtLogin(isLoginEvent: true)
            XCTAssertEqual(runtime.openRequests.count, 1)
            XCTAssertFalse(runtime.openRequests[0].arguments.isEmpty)

            let claude = try XCTUnwrap(try fixture.store.listProfiles(provider: .claude).first)
            let directClaudeOpen = await controller.open(.managed(claude.id))
            XCTAssertFalse(directClaudeOpen)
            XCTAssertEqual(runtime.openRequests.count, 1)
            XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        }

        do {
            let fixture = try Fixture()
            defer { fixture.remove() }
            _ = try fixture.addProfile(provider: .codex, name: "Selected but disabled", launchAtLogin: true)
            try fixture.approveCodex(fingerprint: fingerprint)
            let runtime = FakeRuntime()
            let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector(codexFingerprint: fingerprint))

            await controller.launchAtLogin(isLoginEvent: true)

            XCTAssertTrue(runtime.openRequests.isEmpty)
        }
    }

    func testLoginBatchContinuesAfterOptionalProviderIdentityFailure() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let selected = try fixture.addProfile(provider: .codex, name: "Codex selected", launchAtLogin: true)
        try fixture.approveCodex(fingerprint: fingerprint)
        var claude = try fixture.store.loadProvider(.claude)
        claude.currentLaunchAtLogin = true
        try fixture.store.saveProvider(claude)
        var preferences = try fixture.store.loadPreferences()
        preferences.launchSelectedAtLogin = true
        try fixture.store.savePreferences(preferences)
        let runtime = FakeRuntime()
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        inspector.identityFailures.insert(.claude)
        let stamp = inspector.stamp(provider: .codex, pid: 603, seconds: 101)
        runtime.openHandler = { request in
            runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
            XCTAssertEqual(request.environment["CODEX_HOME"], fixture.store.paths(for: selected).codexHome.path)
            return stamp.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)

        await controller.launchAtLogin(isLoginEvent: true)

        XCTAssertEqual(runtime.openRequests.count, 1)
        XCTAssertEqual(runtime.activated, [stamp])
    }

    func testCriticalMemoryStillAllowsBatchToFocusRunningProfile() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 602, seconds: 100)
        let profile = try fixture.addOwnedProfile(name: "Already running", stamp: stamp, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        controller.model.memoryPressure = .critical

        await controller.openBatch([.managed(profile.id)], automatic: true)

        XCTAssertEqual(runtime.activated, [stamp])
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertNil(controller.model.errorMessage)
    }

    func testChangingLanguageClearsStaleErrorAndRefreshesLoginStatus() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        controller.model.errorMessage = "Stale English error"

        controller.model.send(.setLanguage(.spanish))

        XCTAssertEqual(controller.model.language, .spanish)
        XCTAssertNil(controller.model.errorMessage)
        XCTAssertEqual(try fixture.store.loadPreferences().language, PairbarLanguage.spanish.rawValue)
        XCTAssertTrue(["Activado", "Requiere aprobación en Ajustes del Sistema", "Desactivado", "Instala Pairbar en Aplicaciones primero"].contains(controller.model.loginStatus))
    }
}

private enum InvalidObservation: String, CaseIterable {
    case reused
    case unreadable

    var pid: Int32 { self == .reused ? 410 : 411 }
}

@MainActor
private final class Fixture {
    let root: URL
    let store: DynamicStore

    init() throws {
        root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("work", isDirectory: true)
            .appendingPathComponent("PairbarControllerTests-" + UUID().uuidString, isDirectory: true)
        store = try DynamicStore(root: root)
        try store.acquireLock()
        try store.migrateIfNeeded()
    }

    func approveCodex(fingerprint: String) throws {
        var settings = try store.loadProvider(.codex)
        settings.approvedFingerprint = fingerprint
        settings.setupComplete = true
        try store.saveProvider(settings)
    }

    func addProfile(provider: ProviderID2, name: String, launchAtLogin: Bool = false,
                    order: Int = 0) throws -> ProfileRecord2 {
        var profile = ProfileRecord2(provider: provider, name: name)
        profile.launchAtLogin = launchAtLogin
        profile.order = order
        try store.saveProfile(profile)
        return profile
    }

    func addOwnedProfile(name: String, stamp: ProcessStamp, fingerprint: String) throws -> ProfileRecord2 {
        var profile = ProfileRecord2(provider: .codex, name: name)
        profile.receipt = LaunchReceipt2(provider: .codex, profileID: profile.id,
            storageGeneration: profile.storageGeneration, stamp: stamp,
            paths: store.paths(for: profile), fingerprint: fingerprint)
        try store.saveProfile(profile)
        return profile
    }

    func controller(runtime: FakeRuntime, inspector: FakeInspector) throws -> PairbarController {
        try PairbarController(store: store, runtime: runtime, inspector: inspector, model: PairbarPanelModel())
    }

    func remove() {
        try? FileManager.default.removeItem(at: root)
    }
}

@MainActor
private final class FakeRuntime: ApplicationRuntime {
    var runningInstances: [ProviderID2: [RunningInstance]] = [:]
    var processObservations: [Int32: ProcessObservation] = [:]
    var openRequests: [ProviderLaunchRequest] = []
    var activated: [ProcessStamp] = []
    var terminationAttempts: [ProcessStamp] = []
    var openHandler: ((ProviderLaunchRequest) throws -> Int32)?
    var pauseHandler: (() -> Void)?
    var runningHook: (() -> Void)?
    var terminationAllowed = true
    var liveIdentityAllowed = true
    var suspendPauses = false
    private(set) var pauseCount = 0
    private var pauseContinuation: CheckedContinuation<Void, Never>?
    var now = Date(timeIntervalSince1970: 100)
    let uid = getuid()

    func running(provider: ProviderID2) -> [RunningInstance] {
        runningHook?()
        return runningInstances[provider] ?? []
    }

    func observe(pid: Int32) -> ProcessObservation {
        processObservations[pid] ?? .absent
    }

    func open(_ request: ProviderLaunchRequest) async throws -> Int32 {
        openRequests.append(request)
        guard let openHandler else { throw FakeError.unexpectedOpen }
        return try openHandler(request)
    }

    func verifyLiveIdentity(_ stamp: ProcessStamp, provider: ProviderID2, identity: OfficialAppIdentity) -> Bool {
        liveIdentityAllowed && stamp.executable == identity.executable.path &&
            running(provider: provider).contains(where: { $0.pid == stamp.pid && $0.appURL == identity.app })
    }

    func activate(_ stamp: ProcessStamp, provider: ProviderID2) -> Bool {
        guard case .observed(let live) = observe(pid: stamp.pid), live == stamp,
              running(provider: provider).contains(where: { $0.pid == stamp.pid }) else { return false }
        activated.append(stamp)
        return true
    }

    func terminate(_ stamp: ProcessStamp, provider: ProviderID2) -> Bool {
        terminationAttempts.append(stamp)
        guard terminationAllowed, case .observed(let live) = observe(pid: stamp.pid), live == stamp,
              running(provider: provider).contains(where: { $0.pid == stamp.pid }) else { return false }
        return true
    }

    func pause() async {
        pauseCount += 1
        pauseHandler?()
        guard suspendPauses else { return }
        await withCheckedContinuation { continuation in pauseContinuation = continuation }
    }

    func releasePause() {
        suspendPauses = false
        pauseContinuation?.resume()
        pauseContinuation = nil
    }

    func install(_ stamp: ProcessStamp, provider: ProviderID2, app: URL) {
        runningInstances[provider, default: []].append(RunningInstance(pid: stamp.pid, appURL: app))
        processObservations[stamp.pid] = .observed(stamp)
    }
}

@MainActor
private final class FakeInspector: ProviderInspecting {
    var inspectionResponses: [ProviderID2: [ProviderInspection]] = [:]
    var identityFailures = Set<ProviderID2>()
    var suspendNextInspection = false
    private(set) var inspectionPauseCount = 0
    private(set) var inspectionCount = 0
    private var inspectionContinuation: CheckedContinuation<Void, Never>?
    private let codexFingerprint: String

    init(codexFingerprint: String = "test-codex-fingerprint") {
        self.codexFingerprint = codexFingerprint
    }

    func identity(provider: ProviderID2, at url: URL) async throws -> OfficialAppIdentity {
        if identityFailures.contains(provider) { throw FakeError.identityUnavailable }
        return identity(for: provider)
    }

    func inspect(provider: ProviderID2, at url: URL) async throws -> ProviderInspection {
        inspectionCount += 1
        if suspendNextInspection {
            suspendNextInspection = false
            inspectionPauseCount += 1
            await withCheckedContinuation { continuation in inspectionContinuation = continuation }
        }
        if var queued = inspectionResponses[provider], !queued.isEmpty {
            let response = queued.removeFirst()
            inspectionResponses[provider] = queued
            return response
        }
        return report(provider: provider, fingerprint: provider == .codex ? codexFingerprint : "claude-static-only",
                      managedLaunchAllowed: provider == .codex)
    }

    func releaseInspection() {
        inspectionContinuation?.resume()
        inspectionContinuation = nil
    }

    func identity(for provider: ProviderID2) -> OfficialAppIdentity {
        let appName = provider == .codex ? "FakeChatGPT.app" : "FakeClaude.app"
        let executableName = provider == .codex ? "FakeChatGPT" : "FakeClaude"
        let app = URL(fileURLWithPath: "/Applications/" + appName)
        return OfficialAppIdentity(app: app,
            executable: app.appendingPathComponent("Contents/MacOS/" + executableName), version: "test")
    }

    func report(provider: ProviderID2, fingerprint: String?, managedLaunchAllowed: Bool) -> ProviderInspection {
        ProviderInspection(identity: identity(for: provider), fingerprint: fingerprint,
                           managedLaunchAllowed: managedLaunchAllowed, detail: "synthetic test inspection")
    }

    func stamp(provider: ProviderID2, pid: Int32, seconds: UInt64) -> ProcessStamp {
        ProcessStamp(pid: pid, uid: getuid(), seconds: seconds, microseconds: 0,
                     executable: identity(for: provider).executable.path)
    }
}

private enum FakeError: Error {
    case unexpectedOpen, identityUnavailable
}
