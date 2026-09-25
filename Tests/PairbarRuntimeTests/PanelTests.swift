import Carbon
import XCTest
@testable import DualAccountSwitcher

final class PanelTests: XCTestCase {
    func testPreviewIsRepresentativeAndHasNoActionSideEffects() async {
        await MainActor.run {
            let model = PairbarPanelModel.preview(language: .spanish)
            var actions: [String] = []
            model.onAction = { actions.append(Self.describe($0)) }

            XCTAssertTrue(model.previewOnly)
            XCTAssertTrue(model.welcomeCompleted)
            XCTAssertEqual(model.providers.map(\.id), ["codex", "claude"])
            XCTAssertEqual(model.rows.map(\.id), [
                "current:codex", "preview-second", "preview-work", "current:claude"
            ])
            XCTAssertEqual(model.providers.first(where: { $0.id == "claude" })?.canCreate, false)
            XCTAssertTrue(model.rows.filter(\.isCurrent).allSatisfy { !$0.canClose && !$0.canRestart })

            model.send(.open("preview-work"))
            model.send(.setLanguage(.english))
            model.send(.setStartAtLogin(true))
            model.send(.setOpenProfilesAtLogin(true))
            model.send(.setProfileAtLogin("preview-work", true))
            model.completeWelcome()

            XCTAssertTrue(actions.isEmpty)
            XCTAssertEqual(model.language, .english)
            XCTAssertTrue(model.startAtLogin)
            XCTAssertTrue(model.openProfilesAtLogin)
            XCTAssertTrue(model.rows.first(where: { $0.id == "preview-work" })?.openAtLogin == true)
            XCTAssertEqual(model.page, .accounts)
        }
    }

    func testFavoritesSortBeforeOrderWithStableIDTieBreak() async {
        await MainActor.run {
            let model = PairbarPanelModel()
            model.rows = [
                Self.row("z-last", provider: "codex", favorite: false, order: 0),
                Self.row("b-favorite", provider: "claude", favorite: true, order: 2),
                Self.row("a-favorite", provider: "codex", favorite: true, order: 2),
                Self.row("a-ordinary", provider: "codex", favorite: false, order: -1)
            ]

            XCTAssertEqual(model.orderedRows.map(\.id), [
                "a-favorite", "b-favorite", "a-ordinary", "z-last"
            ])
        }
    }

    func testSearchAndProviderFilterCompose() async {
        await MainActor.run {
            let model = PairbarPanelModel()
            model.rows = [
                Self.row("codex-research", provider: "codex", name: "Research Lab", order: 1),
                Self.row("claude-research", provider: "claude", name: "Research Notes", order: 2),
                Self.row("codex-personal", provider: "codex", name: "Personal", order: 3)
            ]

            model.search = "  research  "
            XCTAssertEqual(model.visibleRows.map(\.id), ["codex-research", "claude-research"])

            model.providerFilter = "claude"
            XCTAssertEqual(model.visibleRows.map(\.id), ["claude-research"])

            model.search = "PERSONAL"
            XCTAssertTrue(model.visibleRows.isEmpty)
            model.providerFilter = "codex"
            XCTAssertEqual(model.visibleRows.map(\.id), ["codex-personal"])
        }
    }

    func testSelectedOpenableIDsExcludeBusyAndUnavailableRows() async {
        await MainActor.run {
            let model = PairbarPanelModel()
            model.rows = [
                Self.row("ordinary", provider: "codex", order: 3, canOpen: true),
                Self.row("favorite", provider: "codex", favorite: true, order: 9, canOpen: true),
                Self.row("busy", provider: "codex", order: 1, isBusy: true, canOpen: true),
                Self.row("blocked", provider: "claude", order: 0, canOpen: false)
            ]
            model.selectedIDs = ["ordinary", "favorite", "busy", "blocked", "missing"]

            XCTAssertEqual(model.selectedOpenableIDs, ["favorite", "ordinary"])

            model.pruneSelection()
            XCTAssertEqual(model.selectedIDs, ["ordinary", "favorite", "busy", "blocked"])
        }
    }

    func testOpenSelectedRevalidatesAndNormalizesRequestedRows() async {
        await MainActor.run {
            let model = PairbarPanelModel()
            model.rows = [
                Self.row("later", provider: "codex", order: 4, canOpen: true),
                Self.row("first", provider: "codex", favorite: true, order: 10, canOpen: true),
                Self.row("busy", provider: "codex", order: 0, isBusy: true, canOpen: true),
                Self.row("blocked", provider: "claude", order: 1, canOpen: false)
            ]
            var actions: [String] = []
            model.onAction = { actions.append(Self.describe($0)) }

            model.send(.openSelected(["later", "missing", "busy", "first", "blocked", "first"]))
            model.send(.openSelected(["missing", "busy", "blocked"]))

            XCTAssertEqual(actions, ["openSelected:first,later"])
        }
    }

    func testStaleDestructiveActionsAndCurrentAccountAreRejected() async {
        await MainActor.run {
            let model = PairbarPanelModel()
            let current = PairbarProfileRow(
                id: "current:codex", providerID: "codex", name: "Current", isCurrent: true,
                canClose: true, canRestart: true, canArchive: true, canReset: true
            )
            let managed = PairbarProfileRow(
                id: "managed", providerID: "codex", name: "Managed",
                canClose: true, canRestart: true, canArchive: true, canReset: true
            )
            model.rows = [current, managed]
            var actions: [String] = []
            model.onAction = { actions.append(Self.describe($0)) }

            model.send(.close(current.id))
            model.send(.restart(current.id))
            model.send(.archive(current.id))
            model.send(.reset(current.id))

            model.rows.removeAll { $0.id == managed.id }
            model.send(.close(managed.id))
            model.send(.restart(managed.id))
            model.send(.archive(managed.id))
            model.send(.reset(managed.id))

            XCTAssertTrue(actions.isEmpty)
        }
    }

    func testCapabilitiesAreRecheckedImmediatelyBeforeDispatch() async {
        await MainActor.run {
            let model = PairbarPanelModel()
            model.rows = [PairbarProfileRow(
                id: "managed", providerID: "codex", name: "Managed",
                canOpen: true, canClose: true, canRestart: true, canArchive: true, canReset: true
            )]
            var actions: [String] = []
            model.onAction = { actions.append(Self.describe($0)) }

            model.rows[0].canClose = false
            model.send(.close("managed"))
            model.rows[0].canOpen = false
            model.send(.open("managed"))
            model.rows[0].canArchive = false
            model.send(.archive("managed"))

            model.rows[0].canRestart = true
            model.send(.restart("managed"))
            model.rows[0].canReset = true
            model.send(.reset("managed"))

            XCTAssertEqual(actions, ["restart:managed", "reset:managed"])
        }
    }

    func testHotKeyValidationAcceptsSupportedChordsOnly() {
        let command = UInt32(cmdKey)
        let option = UInt32(optionKey)
        let control = UInt32(controlKey)
        let shift = UInt32(shiftKey)

        XCTAssertTrue(HotKeys.isValid(keyCode: UInt32(kVK_ANSI_1), modifiers: command))
        XCTAssertTrue(HotKeys.isValid(keyCode: 127, modifiers: option | control | shift))
        XCTAssertFalse(HotKeys.isValid(keyCode: 128, modifiers: command))
        XCTAssertFalse(HotKeys.isValid(keyCode: UInt32(kVK_Escape), modifiers: command))
        XCTAssertFalse(HotKeys.isValid(keyCode: UInt32(kVK_ANSI_A), modifiers: shift))
        XCTAssertFalse(HotKeys.isValid(keyCode: UInt32(kVK_ANSI_A), modifiers: 0))
        XCTAssertFalse(HotKeys.isValid(keyCode: UInt32(kVK_ANSI_A), modifiers: command | 0x1))
    }

    func testHotKeyDisplayUsesStableModifierAndKeyLabels() {
        let modifiers = UInt32(controlKey | optionKey | shiftKey | cmdKey)
        XCTAssertEqual(HotKeys.display(keyCode: UInt32(kVK_ANSI_2), modifiers: modifiers), "⌃⌥⇧⌘2")
        XCTAssertEqual(HotKeys.display(keyCode: UInt32(kVK_Space), modifiers: UInt32(cmdKey)), "⌘Space")
        XCTAssertEqual(HotKeys.display(keyCode: 10, modifiers: UInt32(optionKey)), "⌥[10]")
        XCTAssertEqual(PairbarShortcut(keyCode: 18, modifiers: UInt32(optionKey | cmdKey)).display, "⌥⌘1")
    }

    @MainActor
    private static func row(
        _ id: String,
        provider: String,
        name: String? = nil,
        favorite: Bool = false,
        order: Int = 0,
        isBusy: Bool = false,
        canOpen: Bool = false
    ) -> PairbarProfileRow {
        PairbarProfileRow(
            id: id, providerID: provider, name: name ?? id, isBusy: isBusy,
            favorite: favorite, order: order, canOpen: canOpen
        )
    }

    private static func describe(_ action: PairbarPanelAction) -> String {
        switch action {
        case .open(let id): return "open:\(id)"
        case .openSelected(let ids): return "openSelected:\(ids.joined(separator: ","))"
        case .create: return "create"
        case .update(let id, _): return "update:\(id)"
        case .favorite(let id, let value): return "favorite:\(id):\(value)"
        case .move(let id, let offset): return "move:\(id):\(offset)"
        case .close(let id): return "close:\(id)"
        case .restart(let id): return "restart:\(id)"
        case .archive(let id): return "archive:\(id)"
        case .reset(let id): return "reset:\(id)"
        case .check(let id): return "check:\(id)"
        case .choose(let id): return "choose:\(id)"
        case .recover(let id): return "recover:\(id)"
        case .setStartAtLogin(let value): return "startAtLogin:\(value)"
        case .setOpenProfilesAtLogin(let value): return "openProfilesAtLogin:\(value)"
        case .setProfileAtLogin(let id, let value): return "profileAtLogin:\(id):\(value)"
        case .setLanguage(let language): return "language:\(language.rawValue)"
        case .completeWelcome: return "completeWelcome"
        case .exportConfiguration: return "export"
        case .copyDiagnostics: return "copyDiagnostics"
        case .clearDiagnostics: return "clearDiagnostics"
        case .quitPairbar: return "quit"
        }
    }
}
