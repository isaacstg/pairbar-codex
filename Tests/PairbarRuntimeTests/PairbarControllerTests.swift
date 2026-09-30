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
    func testStandardPathRediscoveryRequiresOneOfficialCandidateAndKeepsApproval() async throws {
        for valid in [["/Applications/ChatGPT.app"], [], ["/Applications/ChatGPT.app", "/Users/test/Applications/ChatGPT.app"]] {
            let fixture = try Fixture(); defer { fixture.remove() }
            try fixture.approveCodex(fingerprint: "old-approved")
            var settings = try fixture.store.loadProvider(.codex)
            settings.appPath = "/missing/ChatGPT.app"
            try fixture.store.saveProvider(settings)
            let inspector = FakeInspector()
            inspector.validIdentityPaths = Set(valid)
            let runtime = FakeRuntime()
            let controller = try fixture.controller(runtime: runtime, inspector: inspector) { preferred in
                [preferred!, URL(fileURLWithPath: "/Applications/ChatGPT.app"),
                 URL(fileURLWithPath: "/Users/test/Applications/ChatGPT.app")]
            }
            await controller.check(.codex, presentErrors: false)
            let saved = try fixture.store.loadProvider(.codex)
            XCTAssertEqual(saved.appPath, valid.count == 1 ? valid[0] : settings.appPath)
            XCTAssertEqual(saved.approvedFingerprint, "old-approved")
            XCTAssertTrue(runtime.openRequests.isEmpty)
        }
    }

    func testValidStoredAppPathDoesNotRediscover() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var settings = try fixture.store.loadProvider(.codex)
        settings.appPath = "/custom/ChatGPT.app"
        try fixture.store.saveProvider(settings)
        let inspector = FakeInspector()
        inspector.validIdentityPaths = [settings.appPath, "/Applications/ChatGPT.app"]
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: inspector) { preferred in
            [preferred!, URL(fileURLWithPath: "/Applications/ChatGPT.app")]
        }
        await controller.check(.codex, presentErrors: false)
        XCTAssertEqual(try fixture.store.loadProvider(.codex).appPath, settings.appPath)
        XCTAssertFalse(controller.diagnosticText.contains("provider-standard-path-rediscovered"))
    }

    func testAbsentReceiptIsClearedLocally() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let stamp = inspector.stamp(provider: .codex, pid: 705, seconds: 101)
        let profile = try fixture.addOwnedProfile(name: "Second", stamp: stamp, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.check(.codex, presentErrors: false)
        let saved = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first)
        XCTAssertNil(saved.receipt)
        XCTAssertEqual(saved.storageGeneration, profile.storageGeneration)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testAbsentReceiptClearsWhileCurrentRemainsOpen() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let stale = inspector.stamp(provider: .codex, pid: 710, seconds: 101)
        let current = inspector.stamp(provider: .codex, pid: 711, seconds: 102)
        let profile = try fixture.addOwnedProfile(name: "Second", stamp: stale, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        runtime.install(current, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.check(.codex, presentErrors: false)
        let saved = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first)
        XCTAssertNil(saved.receipt)
        XCTAssertNil(saved.pending)
        XCTAssertEqual(controller.states[.codex]?.needsRecovery, false)
        XCTAssertTrue(runtime.running(provider: .codex).contains { $0.pid == current.pid })
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertEqual(controller.model.providers.first { $0.id == "codex" }?.canRecover, false)
        XCTAssertEqual(profile.storageGeneration, saved.storageGeneration)
    }

    func testUnavailableReceiptIsNotClearedLocally() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let stamp = inspector.stamp(provider: .codex, pid: 712, seconds: 101)
        let profile = try fixture.addOwnedProfile(name: "Second", stamp: stamp, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        runtime.processObservations[stamp.pid] = .unavailable
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.check(.codex, presentErrors: false)
        XCTAssertEqual(try fixture.store.listProfiles(provider: .codex).first?.receipt, profile.receipt)
        XCTAssertEqual(controller.states[.codex]?.needsRecovery, true)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testFreshPendingWaitsWithoutPauseOrMetadataWrite() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 95), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector())
        await controller.check(.codex, presentErrors: false)
        XCTAssertEqual(try fixture.store.listProfiles(provider: .codex).first?.pending, profile.pending)
        XCTAssertEqual(runtime.pauseCount, 0)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testFreshPendingBecomesEligibleOnceAfterTimeWindow() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 95), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector())
        for _ in 0..<10 { controller.refresh() }
        await Task.yield()
        XCTAssertEqual(runtime.pauseCount, 0)
        XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
        runtime.now = Date(timeIntervalSince1970: 156)
        controller.refresh()
        for _ in 0..<1_000 {
            if try fixture.store.listProfiles(provider: .codex).first?.pending == nil { break }
            await Task.yield()
        }
        XCTAssertNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
        XCTAssertEqual(runtime.pauseCount, 1)
        for _ in 0..<10 { controller.refresh() }
        await Task.yield()
        XCTAssertEqual(runtime.pauseCount, 1)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testOpenWithFreshPendingDoesNotLaunchOrPause() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: fingerprint)
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 95), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector(codexFingerprint: fingerprint))
        let opened = await controller.open(.managed(profile.id))
        XCTAssertFalse(opened)
        XCTAssertEqual(try fixture.store.listProfiles(provider: .codex).first?.pending, profile.pending)
        XCTAssertEqual(runtime.pauseCount, 0)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertNotNil(controller.model.errorMessage)
    }

    func testAutomaticRecoveryClearsStaleMetadataAndPreservesStorage() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        let paths = try fixture.store.prepareStorage(for: profile)
        let sentinel = paths.electron.appendingPathComponent("keep-me")
        try Data("session".utf8).write(to: sentinel)
        let generation = profile.storageGeneration
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector())
        await controller.check(.codex, presentErrors: false)
        let saved = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first)
        XCTAssertNil(saved.pending)
        XCTAssertNil(saved.receipt)
        XCTAssertEqual(saved.storageGeneration, generation)
        XCTAssertEqual(try Data(contentsOf: sentinel), Data("session".utf8))
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertTrue(controller.diagnosticText.contains("automatic-safe-recovery-completed"))
    }

    func testAutomaticRecoveryRejectsLiveUnreadableAndOrphanStates() async throws {
        for condition in ["live", "unreadable", "orphan"] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let inspector = FakeInspector()
            let stamp = inspector.stamp(provider: .codex, pid: 701, seconds: 100)
            var profile = try fixture.addProfile(provider: .codex, name: "Second")
            profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
            if condition == "unreadable" {
                profile.receipt = LaunchReceipt2(provider: .codex, profileID: profile.id,
                    storageGeneration: profile.storageGeneration, launchID: profile.pending!.launchID,
                    stamp: stamp, paths: fixture.store.paths(for: profile), fingerprint: fingerprint)
            }
            try fixture.store.saveProfile(profile)
            let runtime = FakeRuntime()
            if condition == "live" { runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app) }
            if condition == "unreadable" { runtime.processObservations[stamp.pid] = .unavailable }
            if condition == "orphan" {
                let orphan = fixture.root.appendingPathComponent("Profiles/codex/orphan")
                try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
            }
            let controller = try fixture.controller(runtime: runtime, inspector: inspector)
            await controller.check(.codex, presentErrors: false)
            XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
            XCTAssertTrue(runtime.openRequests.isEmpty)
        }
    }

    func testAutomaticRecoveryAbortsWhenProcessAppearsDuringPause() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let inspector = FakeInspector()
        let stamp = inspector.stamp(provider: .codex, pid: 703, seconds: 101)
        runtime.pauseHandler = { runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app) }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.check(.codex, presentErrors: false)
        XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testAutomaticRecoverySaveFailureKeepsPendingAndNeverLaunches() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let stamp = inspector.stamp(provider: .codex, pid: 704, seconds: 101)
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(fingerprint: fingerprint)
        profile.receipt = LaunchReceipt2(provider: .codex, profileID: profile.id,
            storageGeneration: profile.storageGeneration, launchID: profile.pending!.launchID,
            stamp: stamp, paths: fixture.store.paths(for: profile), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let file = fixture.root.appendingPathComponent("Metadata/profiles/codex/" + profile.id.description + ".json")
        let extra = fixture.root.appendingPathComponent("Metadata/profiles/codex/.blocked-link")
        var observationsAfterPause = 0
        runtime.observeHook = {
            guard runtime.pauseCount > 0 else { return }
            observationsAfterPause += 1
            if observationsAfterPause == 2 { try? FileManager.default.linkItem(at: file, to: extra) }
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.check(.codex, presentErrors: false)
        try FileManager.default.removeItem(at: extra)
        let saved = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first)
        XCTAssertNotNil(saved.pending)
        XCTAssertNotNil(saved.receipt)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        controller.refresh()
        XCTAssertEqual(controller.states[.codex]?.needsRecovery, true)
    }

    func testPartialMultiRecordSaveFailureRemainsConservative() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        var first = try fixture.addProfile(provider: .codex, name: "First", order: 0)
        var second = try fixture.addProfile(provider: .codex, name: "Second", order: 1)
        let firstPaths = try fixture.store.prepareStorage(for: first)
        let secondPaths = try fixture.store.prepareStorage(for: second)
        let firstSentinel = firstPaths.electron.appendingPathComponent("session")
        let secondSentinel = secondPaths.electron.appendingPathComponent("session")
        try Data("first".utf8).write(to: firstSentinel)
        try Data("second".utf8).write(to: secondSentinel)
        first.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
        second.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 713, seconds: 101)
        second.receipt = LaunchReceipt2(provider: .codex, profileID: second.id,
            storageGeneration: second.storageGeneration, launchID: second.pending!.launchID,
            stamp: stamp, paths: fixture.store.paths(for: second), fingerprint: fingerprint)
        try fixture.store.saveProfile(first)
        try fixture.store.saveProfile(second)
        let secondFile = fixture.root.appendingPathComponent("Metadata/profiles/codex/" + second.id.description + ".json")
        let extra = fixture.root.appendingPathComponent("Metadata/profiles/codex/.blocked-second")
        let runtime = FakeRuntime()
        var observationsAfterPause = 0
        runtime.observeHook = {
            guard runtime.pauseCount > 0 else { return }
            observationsAfterPause += 1
            if observationsAfterPause == 2 { try? FileManager.default.linkItem(at: secondFile, to: extra) }
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.check(.codex, presentErrors: false)
        XCTAssertTrue(FileManager.default.fileExists(atPath: extra.path))
        try FileManager.default.removeItem(at: extra)
        let saved = try fixture.store.listProfiles(provider: .codex)
        XCTAssertNil(saved.first { $0.id == first.id }?.pending)
        XCTAssertNotNil(saved.first { $0.id == second.id }?.pending)
        XCTAssertNotNil(saved.first { $0.id == second.id }?.receipt)
        XCTAssertEqual(saved.first { $0.id == first.id }?.storageGeneration, first.storageGeneration)
        XCTAssertEqual(saved.first { $0.id == second.id }?.storageGeneration, second.storageGeneration)
        XCTAssertEqual(try Data(contentsOf: firstSentinel), Data("first".utf8))
        XCTAssertEqual(try Data(contentsOf: secondSentinel), Data("second".utf8))
        controller.refresh()
        XCTAssertEqual(controller.states[.codex]?.needsRecovery, true)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testFreshPendingWithReceiptStillRequiresAbsentPID() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let stamp = inspector.stamp(provider: .codex, pid: 714, seconds: 101)
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 95), fingerprint: fingerprint)
        profile.receipt = LaunchReceipt2(provider: .codex, profileID: profile.id,
            storageGeneration: profile.storageGeneration, launchID: profile.pending!.launchID,
            stamp: stamp, paths: fixture.store.paths(for: profile), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        runtime.processObservations[stamp.pid] = .unavailable
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.check(.codex, presentErrors: false)
        let saved = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first)
        XCTAssertEqual(saved.pending, profile.pending)
        XCTAssertEqual(saved.receipt, profile.receipt)
        XCTAssertTrue(runtime.openRequests.isEmpty)
    }

    func testAutomaticRecoveryDoesNotWriteCorruptDurableMetadata() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector())
        let file = fixture.root.appendingPathComponent("Metadata/profiles/codex/" + profile.id.description + ".json")
        let corrupt = Data("{corrupt".utf8)
        try corrupt.write(to: file)
        await controller.check(.codex, presentErrors: false)
        XCTAssertEqual(try Data(contentsOf: file), corrupt)
        XCTAssertEqual(controller.states[.codex]?.needsRecovery, true)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testOpenWithLiveUnownedProcessKeepsMetadataAndExplainsRepair() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let inspector = FakeInspector()
        let runtime = FakeRuntime()
        let stamp = inspector.stamp(provider: .codex, pid: 706, seconds: 101)
        runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        let opened = await controller.open(.managed(profile.id))
        XCTAssertFalse(opened)
        XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(controller.model.errorMessage?.contains("Repair") == true ||
                      controller.model.errorMessage?.contains("Reparar") == true)
        XCTAssertEqual(controller.model.providers.first { $0.id == "codex" }?.canRecover, true)
    }

    func testIneligibleAutomaticRecoveryIsNotRetriedEachRefresh() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let orphan = fixture.root.appendingPathComponent("Profiles/codex/orphan")
        try FileManager.default.createDirectory(at: orphan, withIntermediateDirectories: true)
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector())
        await controller.check(.codex, presentErrors: false)
        let attempts = runtime.pauseCount
        for _ in 0..<10 { controller.refresh() }
        await Task.yield()
        XCTAssertEqual(runtime.pauseCount, attempts)
        XCTAssertNotNil(try fixture.store.listProfiles(provider: .codex).first?.pending)
    }

    func testOpenRecoversStalePendingThenLaunches() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        try fixture.approveCodex(fingerprint: fingerprint)
        var profile = try fixture.addProfile(provider: .codex, name: "Second")
        profile.pending = PendingLaunch2(startedAt: Date(timeIntervalSince1970: 0), fingerprint: fingerprint)
        try fixture.store.saveProfile(profile)
        let runtime = FakeRuntime()
        let inspector = FakeInspector(codexFingerprint: fingerprint)
        let stamp = inspector.stamp(provider: .codex, pid: 702, seconds: 101)
        runtime.openHandler = { _ in
            runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
            return stamp.pid
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        let opened = await controller.open(.managed(profile.id))
        XCTAssertTrue(opened)
        let saved = try XCTUnwrap(try fixture.store.listProfiles(provider: .codex).first)
        XCTAssertNil(saved.pending)
        XCTAssertNotNil(saved.receipt)
        XCTAssertEqual(runtime.openRequests.count, 1)
    }

    func testDeleteStoppedProfileWhileCurrentAndWorkRunKeepsBothAndReleasesShortcut() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let current = inspector.stamp(provider: .codex, pid: 801, seconds: 100)
        let workStamp = inspector.stamp(provider: .codex, pid: 802, seconds: 100)
        _ = try fixture.addOwnedProfile(name: "Work", stamp: workStamp, fingerprint: fingerprint)
        var target = try fixture.addProfile(provider: .codex, name: "Unused", launchAtLogin: true)
        target.shortcut = .legacySecond
        try fixture.store.saveProfile(target)
        let storage = try fixture.store.prepareStorage(for: target)
        let marker = storage.codexHome.appendingPathComponent("retained-marker")
        try Data("keep".utf8).write(to: marker)
        let runtime = FakeRuntime()
        runtime.install(current, provider: .codex, app: inspector.identity(for: .codex).app)
        runtime.install(workStamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.identify(.codex)
        XCTAssertEqual(controller.model.rows.first { $0.id == target.id.description }?.canDelete, true)
        let before = controller.shortcutBindings()
        var installed = before
        controller.replaceShortcuts = { installed = $0; return true }

        await controller.delete(target.id)

        let saved = try XCTUnwrap(try fixture.store.listProfiles().first { $0.id == target.id })
        XCTAssertTrue(saved.archived)
        XCTAssertEqual(saved.storageRetainedInPlace, true)
        XCTAssertNil(saved.shortcut)
        XCTAssertFalse(saved.launchAtLogin)
        XCTAssertFalse(controller.model.rows.contains { $0.id == target.id.description })
        XCTAssertTrue(runtime.running(provider: .codex).contains { $0.pid == current.pid })
        XCTAssertTrue(runtime.running(provider: .codex).contains { $0.pid == workStamp.pid })
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
        XCTAssertFalse(try fixture.store.hasOrphanStorage(provider: .codex, records: fixture.store.listProfiles()))
        XCTAssertEqual(installed.count, before.count - 1)
        XCTAssertFalse(installed.contains { $0.targetID == target.id.description })
        XCTAssertEqual(installed.filter { $0.targetID != target.id.description }, before.filter { $0.targetID != target.id.description })
        controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "New"))
        XCTAssertEqual(controller.records.last?.shortcut, .legacySecond)
    }

    func testDeleteRunningProfileClosesOnlyExactTarget() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let current = inspector.stamp(provider: .codex, pid: 811, seconds: 100)
        let workStamp = inspector.stamp(provider: .codex, pid: 812, seconds: 100)
        let targetStamp = inspector.stamp(provider: .codex, pid: 813, seconds: 100)
        let work = try fixture.addOwnedProfile(name: "Work", stamp: workStamp, fingerprint: fingerprint)
        let target = try fixture.addOwnedProfile(name: "Remove", stamp: targetStamp, fingerprint: fingerprint)
        let runtime = FakeRuntime()
        for stamp in [current, workStamp, targetStamp] { runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app) }
        runtime.pauseHandler = {
            runtime.runningInstances[.codex]?.removeAll { $0.pid == targetStamp.pid }
            runtime.processObservations[targetStamp.pid] = .absent
        }
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.identify(.codex)
        XCTAssertEqual(controller.model.rows.first { $0.id == target.id.description }?.canDelete, true)

        await controller.delete(target.id)

        XCTAssertEqual(runtime.terminationAttempts, [targetStamp])
        XCTAssertTrue(runtime.running(provider: .codex).contains { $0.pid == current.pid })
        XCTAssertTrue(runtime.running(provider: .codex).contains { $0.pid == workStamp.pid })
        XCTAssertFalse(controller.model.rows.contains { $0.id == target.id.description })
        XCTAssertEqual(try fixture.store.listProfiles().first { $0.id == target.id }?.archived, true)
        XCTAssertEqual(try fixture.store.listProfiles().first { $0.id == work.id }?.receipt?.stamp, workStamp)
    }

    func testRemovedWorkRestoresWithOriginalDataWhileCurrentAndAnotherProfileRun() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let inspector = FakeInspector()
        let current = inspector.stamp(provider: .codex, pid: 881, seconds: 100)
        let otherStamp = inspector.stamp(provider: .codex, pid: 882, seconds: 100)
        let other = try fixture.addOwnedProfile(name: "Other", stamp: otherStamp, fingerprint: fingerprint)
        let work = try fixture.addProfile(provider: .codex, name: "Work", order: 7)
        let storage = try fixture.store.prepareStorage(for: work)
        let marker = storage.codexHome.appendingPathComponent("test-fixture")
        try Data("intact".utf8).write(to: marker)
        let runtime = FakeRuntime()
        runtime.install(current, provider: .codex, app: inspector.identity(for: .codex).app)
        runtime.install(otherStamp, provider: .codex, app: inspector.identity(for: .codex).app)
        let controller = try fixture.controller(runtime: runtime, inspector: inspector)
        await controller.identify(.codex)
        await controller.delete(work.id)
        XCTAssertFalse(controller.model.normalRows.contains { $0.id == work.id.description })
        XCTAssertEqual(controller.model.removedProfiles.map(\.id), [work.id.description])
        controller.restoreRemoved(work.id)
        let restored = try XCTUnwrap(controller.records.first { $0.id == work.id })
        XCTAssertFalse(restored.archived)
        XCTAssertEqual(restored.id, work.id)
        XCTAssertEqual(restored.storage, work.storage)
        XCTAssertEqual(restored.storageGeneration, work.storageGeneration)
        XCTAssertEqual(restored.order, work.order)
        XCTAssertEqual(fixture.store.paths(for: restored).base, storage.base)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "intact")
        XCTAssertTrue(controller.model.removedProfiles.isEmpty)
        XCTAssertTrue(controller.model.normalRows.contains { $0.id == work.id.description })
        XCTAssertEqual(controller.model.normalRows.first { $0.id == work.id.description }?.status, "Closed")
        XCTAssertFalse(restored.favorite); XCTAssertFalse(restored.launchAtLogin)
        XCTAssertEqual(restored.shortcut, .legacySecond)
        XCTAssertEqual(controller.records.first { $0.id == other.id }?.receipt?.stamp, otherStamp)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        XCTAssertEqual(runtime.running(provider: .codex).count, 2)
    }

    func testRestoreConflictOffersRenameAndSkipsUnavailableShortcut() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.addProfile(provider: .codex, name: "Work")
        let removed = try fixture.store.removeProfile(old)
        _ = try fixture.addProfile(provider: .codex, name: "Work")
        let runtime = FakeRuntime()
        let controller = try fixture.controller(runtime: runtime, inspector: FakeInspector())
        controller.replaceShortcuts = { !$0.contains(where: { $0.targetID == old.id.description && $0.keyCode == 19 }) }
        controller.restoreRemoved(old.id)
        XCTAssertEqual(controller.model.page, .restore(old.id.description))
        XCTAssertEqual(controller.model.restoreName, "Work")
        XCTAssertFalse(controller.model.restoreNameValid(for: old.id.description))
        controller.model.restoreName = "Restored Work"
        XCTAssertTrue(controller.model.restoreNameValid(for: old.id.description))
        controller.restoreRemoved(old.id, name: controller.model.restoreName)
        let restored = try XCTUnwrap(controller.records.first { $0.id == old.id })
        XCTAssertEqual(restored.name, "Restored Work")
        XCTAssertEqual(restored.shortcut, Shortcut2(keyCode: 20, modifiers: 2304))
        XCTAssertFalse(restored.archived)
        XCTAssertNotEqual(removed, restored)
        XCTAssertTrue(runtime.openRequests.isEmpty)
        XCTAssertTrue(runtime.terminationAttempts.isEmpty)
    }

    func testRestoreFailsClosedWhenMetadataChangesSincePresentation() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.addProfile(provider: .codex, name: "Work")
        _ = try fixture.store.removeProfile(old)
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        var changed = try XCTUnwrap(fixture.store.listProfiles().first)
        changed.name = "Changed outside UI"
        try fixture.store.saveProfile(changed)
        controller.restoreRemoved(old.id)
        XCTAssertTrue(controller.records.first { $0.id == old.id }?.archived == true)
        XCTAssertEqual(try fixture.store.listProfiles().first?.name, "Changed outside UI")
    }

    func testRestoreWithNoAvailableShortcutStillSucceeds() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.addProfile(provider: .codex, name: "Old")
        _ = try fixture.store.removeProfile(old)
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        for number in 1...9 { controller.saveDraft(id: nil, draft: PairbarProfileDraft(name: "Other \(number)")) }
        XCTAssertEqual(controller.records.filter { !$0.archived && $0.shortcut != nil }.count, 9)
        controller.restoreRemoved(old.id)
        XCTAssertFalse(try XCTUnwrap(controller.records.first { $0.id == old.id }).archived)
        XCTAssertNil(controller.records.first { $0.id == old.id }?.shortcut)
    }

    func testRestoreShortcutRegistrationFailureFallsBackToNoShortcut() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.addProfile(provider: .codex, name: "Old")
        _ = try fixture.store.removeProfile(old)
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        let previous = controller.shortcutBindings()
        var installed = previous
        controller.replaceShortcuts = { bindings in
            guard !bindings.contains(where: { $0.targetID == old.id.description }) else { return false }
            installed = bindings; return true
        }
        controller.restoreRemoved(old.id)
        XCTAssertEqual(installed, previous)
        XCTAssertNil(controller.records.first { $0.id == old.id }?.shortcut)
        XCTAssertFalse(try XCTUnwrap(fixture.store.listProfiles().first { $0.id == old.id }).archived)
    }

    func testRemovedProfilesOnlyShowsRetainedInPlaceRecords() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let removedSource = try fixture.addProfile(provider: .codex, name: "Removed")
        _ = try fixture.store.removeProfile(removedSource)
        let archivedSource = try fixture.addProfile(provider: .codex, name: "Archived")
        _ = try fixture.store.archive(profileID: archivedSource.id, reset: false,
            evidence: ProviderQuiescence2(provider: .codex, officialProcessCount: 0, hasUnverifiableProcesses: false))
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        XCTAssertEqual(controller.model.removedProfiles.map(\.name), ["Removed"])
        XCTAssertFalse(controller.model.removedProfiles.contains { $0.isCurrent })
        XCTAssertFalse(controller.model.normalRows.contains { $0.id == removedSource.id.description })
        XCTAssertFalse(controller.model.normalRows.contains { $0.id == archivedSource.id.description })
    }

    func testRestoreReconcilesHotkeysWhenMetadataChangesDuringRegistration() throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        let old = try fixture.addProfile(provider: .codex, name: "Old")
        _ = try fixture.store.removeProfile(old)
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        let previous = controller.shortcutBindings()
        var installed = previous
        var changed = false
        controller.replaceShortcuts = { bindings in
            installed = bindings
            if !changed && bindings.contains(where: { $0.targetID == old.id.description }) {
                changed = true
                var durable = try! XCTUnwrap(fixture.store.listProfiles().first { $0.id == old.id })
                durable.name = "Changed concurrently"
                try! fixture.store.saveProfile(durable)
            }
            return true
        }
        controller.restoreRemoved(old.id)
        XCTAssertTrue(changed)
        XCTAssertEqual(installed, previous)
        XCTAssertTrue(try XCTUnwrap(fixture.store.listProfiles().first { $0.id == old.id }).archived)
        XCTAssertEqual(controller.records.first { $0.id == old.id }?.name, "Changed concurrently")
    }

    func testDeleteCloseTimeoutOrStampChangePreservesProfile() async throws {
        for changed in [false, true] {
            let fixture = try Fixture(); defer { fixture.remove() }
            let inspector = FakeInspector()
            let stamp = inspector.stamp(provider: .codex, pid: changed ? 822 : 821, seconds: 100)
            let target = try fixture.addOwnedProfile(name: "Target", stamp: stamp, fingerprint: fingerprint)
            let runtime = FakeRuntime()
            runtime.install(stamp, provider: .codex, app: inspector.identity(for: .codex).app)
            if changed {
                runtime.pauseHandler = { runtime.processObservations[stamp.pid] = .observed(
                    inspector.stamp(provider: .codex, pid: stamp.pid, seconds: 101)) }
            }
            let controller = try fixture.controller(runtime: runtime, inspector: inspector)
            await controller.identify(.codex)
            await controller.delete(target.id)
            XCTAssertEqual(runtime.terminationAttempts, [stamp])
            XCTAssertEqual(try fixture.store.listProfiles().first { $0.id == target.id }?.archived, false)
            XCTAssertNotNil(try fixture.store.listProfiles().first { $0.id == target.id }?.receipt)
            XCTAssertTrue(controller.model.rows.contains { $0.id == target.id.description })
        }
    }

    func testDeletePersistenceFailureRestoresShortcutAndKeepsStorage() async throws {
        let fixture = try Fixture(); defer { fixture.remove() }
        var target = try fixture.addProfile(provider: .codex, name: "Keep")
        target.shortcut = .legacySecond
        try fixture.store.saveProfile(target)
        let paths = try fixture.store.prepareStorage(for: target)
        let marker = paths.codexHome.appendingPathComponent("marker")
        try Data("keep".utf8).write(to: marker)
        let controller = try fixture.controller(runtime: FakeRuntime(), inspector: FakeInspector())
        let original = controller.shortcutBindings()
        var installed = original
        controller.replaceShortcuts = { installed = $0; return true }
        let directory = fixture.root.appendingPathComponent("Metadata/profiles/codex")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        await controller.delete(target.id)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        XCTAssertEqual(installed, original)
        XCTAssertEqual(try fixture.store.listProfiles().first { $0.id == target.id }?.archived, false)
        XCTAssertTrue(controller.model.rows.contains { $0.id == target.id.description })
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "keep")
    }

    func testDeleteUnsafeStatesAndAmbiguousCurrentDoNotRemove() async throws {
        for mode in 0..<4 {
            let fixture = try Fixture(); defer { fixture.remove() }
            let inspector = FakeInspector()
            var target = try fixture.addProfile(provider: .codex, name: "Unsafe")
            let runtime = FakeRuntime()
            if mode == 0 { target.pending = PendingLaunch2(fingerprint: fingerprint); try fixture.store.saveProfile(target) }
            if mode == 1 {
                let stamp = inspector.stamp(provider: .codex, pid: 831, seconds: 100)
                target.receipt = LaunchReceipt2(provider: .codex, profileID: target.id,
                    storageGeneration: target.storageGeneration, stamp: stamp,
                    paths: fixture.store.paths(for: target), fingerprint: fingerprint)
                try fixture.store.saveProfile(target)
                runtime.processObservations[stamp.pid] = .unavailable
            }
            if mode == 2 {
                let unknown = fixture.root.appendingPathComponent("Profiles/codex/unknown")
                try FileManager.default.createDirectory(at: unknown, withIntermediateDirectories: true,
                                                        attributes: [.posixPermissions: 0o700])
            }
            if mode == 3 {
                for pid in [Int32(832), 833] {
                    runtime.install(inspector.stamp(provider: .codex, pid: pid, seconds: 100),
                                    provider: .codex, app: inspector.identity(for: .codex).app)
                }
            }
            let controller = try fixture.controller(runtime: runtime, inspector: inspector)
            await controller.identify(.codex)
            XCTAssertEqual(controller.model.rows.first { $0.id == target.id.description }?.canDelete, false, "mode \(mode)")
            await controller.delete(target.id)
            XCTAssertEqual(try fixture.store.listProfiles().first { $0.id == target.id }?.archived, false)
            XCTAssertTrue(runtime.terminationAttempts.isEmpty)
        }
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

    func controller(runtime: FakeRuntime, inspector: FakeInspector,
                    candidates: ((URL?) -> [URL])? = nil) throws -> PairbarController {
        try PairbarController(store: store, runtime: runtime, inspector: inspector, model: PairbarPanelModel(),
                              standardCandidates: candidates ?? Compatibility.standardCandidates)
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
    var observeHook: (() -> Void)?
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
        observeHook?()
        return processObservations[pid] ?? .absent
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
    var validIdentityPaths: Set<String>?
    var suspendNextInspection = false
    private(set) var inspectionPauseCount = 0
    private(set) var inspectionCount = 0
    private var inspectionContinuation: CheckedContinuation<Void, Never>?
    private let codexFingerprint: String

    init(codexFingerprint: String = "test-codex-fingerprint") {
        self.codexFingerprint = codexFingerprint
    }

    func identity(provider: ProviderID2, at url: URL) async throws -> OfficialAppIdentity {
        if identityFailures.contains(provider) || (validIdentityPaths != nil && !validIdentityPaths!.contains(url.path)) {
            throw FakeError.identityUnavailable
        }
        if validIdentityPaths != nil {
            let original = identity(for: provider)
            let app = url.standardizedFileURL
            return OfficialAppIdentity(app: app, executable: app.appendingPathComponent("Contents/MacOS/")
                .appendingPathComponent(original.executable.lastPathComponent), version: "test")
        }
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
