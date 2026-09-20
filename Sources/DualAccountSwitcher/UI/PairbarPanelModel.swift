import Foundation
import SwiftUI

enum PairbarLanguage: String, CaseIterable, Identifiable {
    case system, english, spanish
    var id: String { rawValue }
    var usesSpanish: Bool {
        self == .spanish || (self == .system && Locale.preferredLanguages.first?.hasPrefix("es") == true)
    }
    func text(_ english: String, _ spanish: String) -> String { usesSpanish ? spanish : english }
}

struct PairbarShortcut: Hashable {
    var keyCode: UInt32
    var modifiers: UInt32
    var display: String { HotKeys.display(keyCode: keyCode, modifiers: modifiers) }
}

struct PairbarProfileRow: Identifiable, Equatable {
    var id: String
    var providerID: String
    var name: String
    var isCurrent: Bool = false
    var status: String = ""
    var running: Bool = false
    var needsAttention: Bool = false
    var isBusy: Bool = false
    var favorite: Bool = false
    var order: Int = 0
    var shortcut: PairbarShortcut?
    var openAtLogin: Bool = false
    var canOpen: Bool = false
    var canClose: Bool = false
    var canRestart: Bool = false
    var canArchive: Bool = false
    var canReset: Bool = false
    var canEdit: Bool = true
    var unavailableReason: String?
}

struct PairbarProviderRow: Identifiable, Equatable {
    var id: String
    var name: String
    var status: String
    var detail: String = ""
    var version: String = ""
    var canCreate: Bool = false
    var canCheck: Bool = true
    var canApprove: Bool = false
    var canChoose: Bool = true
    var canRecover: Bool = false
    var busy: Bool = false
}

struct PairbarProfileDraft: Equatable {
    var providerID: String = "codex"
    var name: String = ""
    var favorite: Bool = false
    var shortcut: PairbarShortcut?
    var openAtLogin: Bool = false
}

enum PairbarPanelPage: Equatable {
    case welcome, accounts, settings, help, create, edit(String)
}

enum PairbarMemoryPressure { case normal, warning, critical }

enum PairbarPanelAction {
    case open(String), openSelected([String])
    case create(PairbarProfileDraft), update(String, PairbarProfileDraft)
    case favorite(String, Bool), move(String, Int)
    case close(String), restart(String), archive(String), reset(String)
    case check(String), approve(String), choose(String), recover(String)
    case setStartAtLogin(Bool), setOpenProfilesAtLogin(Bool), setProfileAtLogin(String, Bool)
    case setLanguage(PairbarLanguage), completeWelcome
    case exportConfiguration, copyDiagnostics, clearDiagnostics, quitPairbar
}

/// Presentation state only. The controller validates every requested operation again.
/// No storage, provider inspection or process operations occur in this model or its previews.
@MainActor
final class PairbarPanelModel: ObservableObject {
    static let width: CGFloat = 430
    static let height: CGFloat = 610
    @Published var rows: [PairbarProfileRow] = []
    @Published var providers: [PairbarProviderRow] = []
    @Published var errorMessage: String?
    @Published var progressMessage: String?
    @Published var language: PairbarLanguage = .system
    @Published var memoryPressure: PairbarMemoryPressure = .normal
    @Published var startAtLogin = false
    @Published var openProfilesAtLogin = false
    @Published var loginStatus = ""
    @Published var welcomeCompleted = false
    @Published var busy = false
    @Published var previewOnly = false
    @Published var diagnosticText = ""
    @Published var page: PairbarPanelPage = .accounts
    @Published var search = ""
    @Published var providerFilter = "all"
    @Published var selectedIDs: Set<String> = []
    @Published var selecting = false
    var onAction: ((PairbarPanelAction) -> Void)?

    func text(_ english: String, _ spanish: String) -> String { language.text(english, spanish) }
    func providerName(_ id: String) -> String {
        providers.first { $0.id == id }?.name ?? (id == "claude" ? "Claude" : "Codex")
    }
    var visibleRows: [PairbarProfileRow] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return orderedRows.filter { row in
            (providerFilter == "all" || providerFilter == row.providerID) &&
            (query.isEmpty || row.name.localizedStandardContains(query))
        }
    }
    var orderedRows: [PairbarProfileRow] {
        rows.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.order != $1.order { return $0.order < $1.order }
            return $0.id < $1.id
        }
    }
    var selectedOpenableIDs: [String] {
        orderedRows.filter { selectedIDs.contains($0.id) && $0.canOpen && !$0.isBusy }.map(\.id)
    }
    var canCreate: Bool { providers.contains { $0.canCreate && !$0.busy } }
    func send(_ action: PairbarPanelAction) {
        guard !previewOnly else { return }
        // A confirmation may outlive the row it was opened from. Recheck current
        // presentation capabilities here; the controller separately checks ownership.
        switch action {
        case .close(let id):
            guard rows.contains(where: { $0.id == id && !$0.isCurrent && $0.canClose }) else { return }
        case .restart(let id):
            guard rows.contains(where: { $0.id == id && !$0.isCurrent && $0.canRestart }) else { return }
        case .archive(let id):
            guard rows.contains(where: { $0.id == id && !$0.isCurrent && $0.canArchive }) else { return }
        case .reset(let id):
            guard rows.contains(where: { $0.id == id && !$0.isCurrent && $0.canReset }) else { return }
        case .open(let id):
            guard rows.contains(where: { $0.id == id && $0.canOpen && !$0.isBusy }) else { return }
        case .openSelected(let ids):
            let requested = Set(ids)
            let allowed = orderedRows.filter { requested.contains($0.id) && $0.canOpen && !$0.isBusy }.map(\.id)
            guard !allowed.isEmpty else { return }
            onAction?(.openSelected(allowed))
            return
        case .update(let id, _), .favorite(let id, _), .move(let id, _), .setProfileAtLogin(let id, _):
            guard rows.contains(where: { $0.id == id && $0.canEdit }) else { return }
        case .create(let draft):
            guard providers.contains(where: { $0.id == draft.providerID && $0.canCreate && !$0.busy }) else { return }
        case .approve(let id):
            guard providers.contains(where: { $0.id == id && $0.canApprove && !$0.busy }) else { return }
        case .recover(let id):
            guard providers.contains(where: { $0.id == id && $0.canRecover && !$0.busy }) else { return }
        case .check(let id):
            guard providers.contains(where: { $0.id == id && $0.canCheck && !$0.busy }) else { return }
        case .choose(let id):
            guard providers.contains(where: { $0.id == id && $0.canChoose && !$0.busy }) else { return }
        default: break
        }
        onAction?(action)
    }
    func profileSaved() { page = .accounts }
    func completeWelcome() {
        if !previewOnly { onAction?(.completeWelcome) }
        welcomeCompleted = true
        page = .accounts
    }
    func showAccounts() { page = .accounts }
    func pruneSelection() { selectedIDs.formIntersection(Set(rows.map(\.id))) }
}

extension PairbarPanelModel {
    static func preview(language: PairbarLanguage = .english) -> PairbarPanelModel {
        let model = PairbarPanelModel()
        model.previewOnly = true
        model.language = language
        model.welcomeCompleted = true
        model.providers = [
            PairbarProviderRow(id: "codex", name: "Codex", status: model.text("App check passed", "Comprobación superada"), canCreate: true),
            PairbarProviderRow(id: "claude", name: "Claude", status: model.text("Under investigation", "En investigación"),
                detail: model.text("Additional Claude profiles are unavailable until Chat and Code session separation passes real acceptance tests.", "Los perfiles adicionales de Claude no están disponibles hasta verificar la separación real de sesiones de Chat y Code."))
        ]
        model.rows = [
            PairbarProfileRow(id: "current:codex", providerID: "codex", name: "Current Account", isCurrent: true,
                status: model.text("Running", "En ejecución"), running: true, favorite: true,
                shortcut: PairbarShortcut(keyCode: 18, modifiers: 2304), canOpen: true),
            PairbarProfileRow(id: "preview-second", providerID: "codex", name: "Second Account", status: model.text("Running · protected session", "En ejecución · sesión protegida"),
                running: true, favorite: true, order: 1, shortcut: PairbarShortcut(keyCode: 19, modifiers: 2304), canOpen: true),
            PairbarProfileRow(id: "preview-work", providerID: "codex", name: model.text("Work and research", "Trabajo e investigación"),
                status: model.text("Closed", "Cerrado"), order: 2, canOpen: true, canArchive: true, canReset: true),
            PairbarProfileRow(id: "current:claude", providerID: "claude", name: "Current Account", isCurrent: true,
                status: model.text("Closed", "Cerrado"), order: 3, canOpen: true)
        ]
        model.diagnosticText = "Pairbar 2 · preview\nprovider codex: ready\nprovider claude: managed-unavailable\nprofiles: 2"
        return model
    }
}
