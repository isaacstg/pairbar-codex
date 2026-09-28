import AppKit
import Foundation
import Darwin
import ServiceManagement
import SwitcherCore

@MainActor
final class PairbarController {
    /// Longer than NativeApplicationRuntime.open's 20-second LaunchServices timeout.
    static let automaticPendingMinimumAge: TimeInterval = 60
    let model: PairbarPanelModel
    let store: DynamicStore
    private let runtime: ApplicationRuntime
    private let inspector: ProviderInspecting
    private let standardCandidates: (URL?) -> [URL]
    private(set) var preferences: Preferences2
    private(set) var providers: [ProviderID2: ProviderSettings2] = [:]
    private(set) var records: [ProfileRecord2]
    private(set) var states: [ProviderID2: ProviderState2] = [:]
    private var identities: [ProviderID2: OfficialAppIdentity] = [:]
    private var reports: [ProviderID2: ProviderInspection] = [:]
    private var busy = Set<ProviderID2>()
    private var launching = Set<ManagedProfileID>()
    private var quitting = Set<ManagedProfileID>()
    private var currentLaunching = Set<ProviderID2>()
    private var events: [String] = []
    private var autoRecoveryAttempted = Set<ProviderID2>()
    private var hasRefreshed = false
    private var batchRunning = false
    private var loginHandled = false
    var onActivate: (() -> Void)?
    var onPresent: (() -> Void)?
    var replaceShortcuts: (([HotKeys.Binding]) -> Bool)?
    /// UI supplies a contextual decision. Nil keeps headless/test callers fail-closed.
    var confirmNewBuild: ((ProviderInspection) -> Bool)?

    init(store: DynamicStore, runtime: ApplicationRuntime, inspector: ProviderInspecting,
         model: PairbarPanelModel, standardCandidates: @escaping (URL?) -> [URL] = Compatibility.standardCandidates) throws {
        self.store = store; self.runtime = runtime; self.inspector = inspector; self.model = model
        self.standardCandidates = standardCandidates
        preferences = try store.loadPreferences()
        records = try store.listProfiles()
        for provider in ProviderID2.allCases { providers[provider] = try store.loadProvider(provider) }
        model.language = PairbarLanguage(rawValue: preferences.language) ?? .system
        model.welcomeCompleted = preferences.welcomeDismissed || UserDefaults.standard.bool(forKey: "pairbarWelcomeCompleted")
        model.page = model.welcomeCompleted ? .accounts : .welcome
        model.onAction = { [weak self] action in self?.handle(action) }
        refresh()
    }
    private func text(_ english: String, _ spanish: String) -> String { model.text(english, spanish) }
    private func event(_ code: String) { events.append(code); if events.count > 200 { events.removeFirst(events.count - 200) } }
    private func fail(_ code: String = "operation-blocked") {
        event(code)
        switch code {
        case "compatibility": model.errorMessage = text("This official app build could not be verified or approved. See Advanced in Settings.", "No se pudo verificar o aprobar esta versión oficial. Consulta Avanzado en Ajustes.")
        case "claude-unvalidated": model.errorMessage = text("Additional Claude profiles are unavailable until real Chat and Code separation is validated.", "Los perfiles adicionales de Claude no están disponibles hasta validar la separación real de Chat y Code.")
        case "ownership": model.errorMessage = text("Pairbar needs to verify this account before it can be opened. Close ChatGPT, then use Repair… or check Advanced.", "Pairbar necesita verificar esta cuenta antes de abrirla. Cierra ChatGPT y usa Reparar… o revisa Avanzado.")
        case "delete-ownership": model.errorMessage = text("Pairbar needs to verify this profile before it can be removed.", "Pairbar necesita verificar este perfil antes de eliminarlo.")
        case "delete-close": model.errorMessage = text("Pairbar could not safely close this profile. It remains in your list with its data intact.", "Pairbar no pudo cerrar este perfil de forma segura. Sigue en la lista y conserva sus datos.")
        case "updated-running-app": model.errorMessage = text("ChatGPT may have been updated while this profile was open. Close that ChatGPT app normally, then open the profile again.", "Es posible que ChatGPT se haya actualizado mientras este perfil estaba abierto. Cierra esa app de ChatGPT de forma normal y vuelve a abrir el perfil.")
        case "shortcut": model.errorMessage = text("That shortcut is invalid or unavailable. The previous shortcut was retained.", "El atajo no es válido o no está disponible. Se conserva el anterior.")
        case "name": model.errorMessage = text("Use a unique name of 1–40 characters without line breaks or control characters.", "Usa un nombre único de 1–40 caracteres, sin saltos de línea ni caracteres de control.")
        case "memory": model.errorMessage = text("Memory pressure paused new openings. Existing instances were preserved.", "La presión de memoria ha pausado las aperturas. Se conservan las instancias abiertas.")
        case "quit-timeout": model.errorMessage = text("The app did not finish quitting. Restart was cancelled; no forced close was sent.", "La app no terminó de cerrarse. Se canceló el reinicio; no se forzó el cierre.")
        default: model.errorMessage = text("Pairbar could not open this account safely. Your data is preserved. Use Repair… if the issue continues.", "Pairbar no pudo abrir esta cuenta con seguridad. Se conservan tus datos. Usa Reparar… si el problema continúa.")
        }
        onPresent?()
    }
    private func caught(_ error: Error) {
        if let storeError = error as? DynamicStoreError, storeError == .invalidName || storeError == .duplicateProfile { fail("name") }
        else { fail("operation-blocked") }
    }
    private func target(_ id: String) -> AccountTarget2? {
        if id.hasPrefix("current:"), let provider = ProviderID2(rawValue: String(id.dropFirst(8))) { return .current(provider) }
        if let uuid = UUID(uuidString: id) { return .managed(ManagedProfileID(uuid)) }
        return nil
    }
    func accountTarget(_ id: String) -> AccountTarget2? { target(id) }
    private func provider(for target: AccountTarget2) -> ProviderID2? {
        switch target { case .current(let p): return p; case .managed(let id): return records.first { $0.id == id }?.provider }
    }
    private func observations(provider: ProviderID2, apps: [RunningInstance]) -> [Int32: ProcessObservation2] {
        var result: [Int32: ProcessObservation2] = [:]
        let ids = Set(apps.map(\.pid) + records.filter { $0.provider == provider }.compactMap { $0.receipt?.stamp.pid })
        for pid in ids {
            switch runtime.observe(pid: pid) {
            case .absent: result[pid] = .absent
            case .unavailable: result[pid] = .unreadable
            case .observed(let stamp):
                if let app = apps.first(where: { $0.pid == pid }), let url = app.appURL,
                   let identity = identities[provider], url.resolvingSymlinksInPath() == identity.app,
                   stamp.executable == identity.executable.path { result[pid] = .verified(stamp) }
                else { result[pid] = .unreadable }
            }
        }
        return result
    }
    private func replaceRecord(_ record: ProfileRecord2) throws {
        try store.saveProfile(record)
        if let index = records.firstIndex(where: { $0.id == record.id }) { records[index] = record }
        else { records.append(record) }
    }
    private func providerHasMetadataIssue(_ provider: ProviderID2) -> Bool {
        do { return try store.hasPendingOperations(provider: provider) || store.hasOrphanStorage(provider: provider, records: records) }
        catch { return true }
    }
    private func currentIsKnown(_ state: ProviderState2) -> Bool {
        switch state.current { case .stopped, .running: return true; default: return false }
    }
    private func automaticPendingIsOldEnough(_ provider: ProviderID2) -> Bool {
        !records.contains { record in
            guard record.provider == provider, record.receipt == nil, let pending = record.pending else { return false }
            return runtime.now.timeIntervalSince(pending.startedAt) < Self.automaticPendingMinimumAge
        }
    }
    func refresh() {
        var candidates: [ProviderID2] = []
        for provider in ProviderID2.allCases {
            let apps = runtime.running(provider: provider)
            var staleReceiptSaveFailed = false
            // A receipt for a proven absent PID can be cleared locally even while
            // Current or another managed instance remains open. Pending intent is
            // never cleared here.
            for var record in records where record.provider == provider && record.pending == nil && record.receipt != nil &&
                !launching.contains(record.id) && !quitting.contains(record.id) {
                if let receipt = record.receipt, !apps.contains(where: { $0.pid == receipt.stamp.pid }),
                   case .absent = runtime.observe(pid: receipt.stamp.pid) {
                    record.receipt = nil
                    do { try replaceRecord(record) }
                    catch { staleReceiptSaveFailed = true; event("stale-receipt-save-failed") }
                }
            }
            states[provider] = DynamicStateResolver.resolve(provider: provider, records: records, root: store.root,
                officialPIDs: apps.map(\.pid), observations: observations(provider: provider, apps: apps), uid: runtime.uid,
                launching: launching, quitting: quitting, currentLaunching: currentLaunching.contains(provider),
                metadataUncertain: providerHasMetadataIssue(provider) || staleReceiptSaveFailed)
            if states[provider]?.needsRecovery != true || !apps.isEmpty || !automaticPendingIsOldEnough(provider) {
                autoRecoveryAttempted.remove(provider)
            }
            else if hasRefreshed && provider.managedProfilesEnabled && !busy.contains(provider) &&
                        autoRecoveryAttempted.insert(provider).inserted { candidates.append(provider) }
        }
        hasRefreshed = true
        present()
        for provider in candidates {
            Task { [weak self] in
                guard let self, !self.busy.contains(provider) else { return }
                self.busy.insert(provider)
                self.refresh()
                _ = await self.recoverQuiescentProvider(provider, automatic: true)
                self.busy.remove(provider)
                self.refresh()
            }
        }
    }
    private func present() {
        var rows: [PairbarProfileRow] = []
        var providerRows: [PairbarProviderRow] = []
        for provider in ProviderID2.allCases {
            guard let settings = providers[provider], let state = states[provider] else { continue }
            let isBusy = busy.contains(provider)
            let managedProfilesEnabled = provider.managedProfilesEnabled
            var row = PairbarProfileRow(id: "current:" + provider.rawValue, providerID: provider.rawValue,
                name: settings.currentName, isCurrent: true, favorite: settings.currentFavorite, order: settings.currentOrder,
                shortcut: settings.currentShortcut.map { PairbarShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) },
                openAtLogin: settings.currentLaunchAtLogin, canEdit: !isBusy)
            switch state.current {
            case .running: row.status = text("Running", "En ejecución"); row.running = true; row.canOpen = !isBusy
            case .stopped: row.status = text("Closed", "Cerrado"); row.canOpen = !isBusy
            case .launching: row.status = text("Opening…", "Abriendo…"); row.isBusy = true
            case .ambiguous: row.status = text("Multiple normal instances", "Varias instancias normales"); row.needsAttention = true
            case .blockedByRecovery: row.status = text("Needs a quick check", "Necesita una comprobación"); row.needsAttention = true
            }
            rows.append(row)
            for record in records where record.provider == provider && !record.archived {
                let profileState = state.profiles[record.id] ?? .ownershipUncertain
                let canDelete = managedProfilesEnabled && !isBusy && !state.needsRecovery && currentIsKnown(state) &&
                    record.pending == nil && (profileState == .stopped && record.receipt == nil ||
                        profileState.verifiedPID != nil)
                let archiveSafe = managedProfilesEnabled && !isBusy && !state.needsRecovery && runtime.running(provider: provider).isEmpty &&
                    !records.contains(where: { $0.provider == provider && ($0.receipt != nil || $0.pending != nil) })
                var row = PairbarProfileRow(id: record.id.description, providerID: provider.rawValue, name: record.name,
                    favorite: record.favorite, order: record.order,
                    shortcut: record.shortcut.map { PairbarShortcut(keyCode: $0.keyCode, modifiers: $0.modifiers) },
                    openAtLogin: record.launchAtLogin, canArchive: archiveSafe, canDelete: canDelete, canReset: archiveSafe, canEdit: !isBusy)
                switch profileState {
                case .runningVerified:
                    row.status = text("Running", "En ejecución"); row.running = true
                    row.canOpen = managedProfilesEnabled && !isBusy
                    row.canClose = managedProfilesEnabled && !isBusy
                    row.canRestart = managedProfilesEnabled && !isBusy && !state.needsRecovery
                case .stopped:
                    row.status = text("Closed", "Cerrado")
                    row.canOpen = managedProfilesEnabled && !isBusy && !state.needsRecovery
                case .launching: row.status = text("Opening…", "Abriendo…"); row.isBusy = true
                case .quitting: row.status = text("Closing…", "Cerrando…"); row.isBusy = true
                default: row.status = text("Needs a quick check", "Necesita una comprobación"); row.needsAttention = true
                }
                rows.append(row)
            }
            let report = reports[provider]
            let approved = report?.fingerprint != nil && report?.fingerprint == settings.approvedFingerprint && settings.setupComplete
            providerRows.append(PairbarProviderRow(id: provider.rawValue, name: provider == .codex ? "Codex" : "Claude",
                status: provider == .claude ? text("Managed profiles unvalidated", "Perfiles administrados sin validar") :
                    (approved ? text("Build approved", "Versión aprobada") : text("Approval requested when opening a profile", "Se pedirá aprobación al abrir un perfil")),
                detail: provider == .claude ? text("Current stays normal. Additional Chat and Code profiles remain unavailable pending real separation tests.", "Current sigue siendo normal. Los perfiles adicionales de Chat y Code esperan pruebas reales de separación.") :
                    text("Static compatibility does not prove account isolation. Verify the account inside the official app.", "La compatibilidad estática no demuestra aislamiento. Verifica la cuenta dentro de la app oficial."),
                version: identities[provider]?.version ?? "", canCreate: provider == .codex && !isBusy,
                canCheck: !isBusy,
                canChoose: !isBusy, canRecover: managedProfilesEnabled && state.needsRecovery && !isBusy, busy: isBusy))
        }
        model.rows = rows; model.providers = providerRows; model.busy = !busy.isEmpty
        model.openProfilesAtLogin = preferences.launchSelectedAtLogin
        model.diagnosticText = diagnosticText
        model.pruneSelection()
    }
    var diagnosticText: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        var lines = ["Pairbar \(version) (\(build))", "metadata-schema: 3", "managed-profiles: \(records.filter { !$0.archived }.count)",
                     "claude-managed: unavailable; runtime-separation-unvalidated"]
        for provider in ProviderID2.allCases {
            lines.append("provider: \(provider.rawValue); official-processes: \(runtime.running(provider: provider).count); recovery: \(states[provider]?.needsRecovery == true)")
        }
        lines.append("Profile names, paths, credentials and provider logs are omitted.")
        return (lines + events).joined(separator: "\n")
    }
    func check(_ provider: ProviderID2, presentErrors: Bool = true) async {
        guard !busy.contains(provider) else { return }; busy.insert(provider); refresh()
        defer { busy.remove(provider); refresh() }
        do {
            guard let settings = providers[provider] else { return }
            let identity = try await officialIdentity(provider, settings: settings)
            let result = try await inspector.inspect(provider: provider, at: identity.app)
            identities[provider] = result.identity; reports[provider] = result; model.errorMessage = nil
        } catch {
            reports[provider] = nil
            // Current identification remains independent of the stricter managed inspection.
            if let settings = providers[provider] {
                identities[provider] = try? await inspector.identity(provider: provider, at: URL(fileURLWithPath: settings.appPath))
            }
            if presentErrors { caught(error) } else { event("provider-check-unavailable") }
        }
        refresh()
        if provider.managedProfilesEnabled, states[provider]?.needsRecovery == true,
           automaticPendingIsOldEnough(provider) {
            autoRecoveryAttempted.insert(provider)
            _ = await recoverQuiescentProvider(provider, automatic: true)
        }
    }
    private func officialIdentity(_ provider: ProviderID2, settings: ProviderSettings2) async throws -> OfficialAppIdentity {
        let stored = URL(fileURLWithPath: settings.appPath)
        do { return try await inspector.identity(provider: provider, at: stored) }
        catch {
            guard provider == .codex else { throw error }
            var valid: [OfficialAppIdentity] = []
            for candidate in standardCandidates(stored) where candidate.standardizedFileURL != stored.standardizedFileURL {
                if let identity = try? await inspector.identity(provider: provider, at: candidate),
                   !valid.contains(where: { $0.app == identity.app }) { valid.append(identity) }
            }
            guard valid.count == 1, let identity = valid.first else {
                event(valid.isEmpty ? "provider-standard-path-unavailable" : "provider-standard-path-ambiguous")
                throw error
            }
            var updated = settings; updated.appPath = identity.app.path
            try store.saveProvider(updated)
            providers[provider] = updated; reports[provider] = nil; identities[provider] = identity
            event("provider-standard-path-rediscovered")
            return identity
        }
    }
    func identify(_ provider: ProviderID2) async {
        guard !busy.contains(provider), let settings = providers[provider] else { return }
        busy.insert(provider); refresh()
        defer { busy.remove(provider); refresh() }
        do {
            identities[provider] = try await officialIdentity(provider, settings: settings)
        } catch {
            event("provider-identity-unavailable")
        }
    }
    /// The approval is bound to a second inspection of the same installed build.
    /// Callers must recheck their own target's ownership after this may suspend or show an alert.
    private func approvedManagedBuild(_ provider: ProviderID2, settings: ProviderSettings2,
                                      allowApproval: Bool, onDecline: ((ProviderID2) -> Void)? = nil) async throws -> ProviderInspection? {
        let report = try await inspector.inspect(provider: provider, at: URL(fileURLWithPath: settings.appPath))
        guard report.managedLaunchAllowed, let fingerprint = report.fingerprint else { fail("compatibility"); return nil }
        identities[provider] = report.identity
        reports[provider] = report
        if !settings.setupComplete || fingerprint != settings.approvedFingerprint {
            guard allowApproval else { event("build-approval-required"); return nil }
            guard confirmNewBuild?(report) == true else {
                event("build-approval-declined"); onDecline?(provider); return nil
            }
            let confirmed = try await inspector.inspect(provider: provider, at: report.identity.app)
            guard confirmed.managedLaunchAllowed, confirmed.fingerprint == fingerprint,
                  confirmed.identity == report.identity else { fail("compatibility"); return nil }
            refresh()
            guard states[provider]?.needsRecovery == false, var current = providers[provider],
                  current.appPath == settings.appPath else { fail("ownership"); return nil }
            current.approvedFingerprint = fingerprint; current.setupComplete = true
            try store.saveProvider(current); providers[provider] = current
            event("official-build-approved")
        }
        return report
    }
    @discardableResult
    func open(_ target: AccountTarget2, allowCriticalMemory: Bool = false,
              holdingProviderLock: Bool = false, allowBuildApproval: Bool = true,
              onBuildApprovalDeclined: ((ProviderID2) -> Void)? = nil) async -> Bool {
        guard let provider = provider(for: target), let settings = providers[provider],
              holdingProviderLock || !busy.contains(provider) else { return false }
        let ownsProviderLock = !holdingProviderLock
        if ownsProviderLock { busy.insert(provider); refresh() }
        defer { if ownsProviderLock { busy.remove(provider); refresh() } }
        do {
            let identity = try await officialIdentity(provider, settings: settings)
            identities[provider] = identity; refresh()
            if provider.managedProfilesEnabled, states[provider]?.needsRecovery == true {
                guard automaticPendingIsOldEnough(provider) else { fail("ownership"); return false }
                autoRecoveryAttempted.insert(provider)
                guard await recoverQuiescentProvider(provider, automatic: true) else { fail("ownership"); return false }
                refresh()
            }
            switch target {
            case .current:
                guard let state = states[provider] else { return false }
                if case .running(let pid) = state.current, case .observed(let stamp) = runtime.observe(pid: pid) {
                    guard runtime.verifyLiveIdentity(stamp, provider: provider, identity: identity),
                          runtime.activate(stamp, provider: provider) else { fail("ownership"); return false }
                    onActivate?(); return true
                }
                guard state.current == .stopped else { fail("ownership"); return false }
                guard model.memoryPressure != .critical || allowCriticalMemory else { fail("memory"); return false }
                currentLaunching.insert(provider); refresh(); defer { currentLaunching.remove(provider) }
                let request = ProviderLaunchRequest.current(app: identity.app, hasManagedInstances: !runtime.running(provider: provider).isEmpty)
                let returned = try await runtime.open(request)
                refresh()
                guard case .running(let resolved) = states[provider]?.current, resolved == returned,
                      !records.contains(where: { $0.receipt?.stamp.pid == returned }),
                      case .observed(let stamp) = runtime.observe(pid: returned), stamp.executable == identity.executable.path,
                      runtime.verifyLiveIdentity(stamp, provider: provider, identity: identity),
                      runtime.activate(stamp, provider: provider) else { fail("ownership"); return false }
                onActivate?(); return true
            case .managed(let id):
                guard provider.managedProfilesEnabled else { fail("claude-unvalidated"); return false }
                guard var record = records.first(where: { $0.id == id && !$0.archived }), let state = states[provider]?.profiles[id] else { return false }
                if case .runningVerified = state, let receipt = record.receipt,
                   case .observed(let stamp) = runtime.observe(pid: receipt.stamp.pid),
                   receipt.owns(stamp, profile: record, paths: store.paths(for: record), uid: runtime.uid),
                   runtime.verifyLiveIdentity(stamp, provider: provider, identity: identity),
                   runtime.activate(stamp, provider: provider) { onActivate?(); return true }
                guard state == .stopped, states[provider]?.needsRecovery == false else { fail("ownership"); return false }
                guard model.memoryPressure != .critical || allowCriticalMemory else { fail("memory"); return false }
                guard let currentSettings = providers[provider],
                      let report = try await approvedManagedBuild(provider, settings: currentSettings,
                    allowApproval: allowBuildApproval, onDecline: onBuildApprovalDeclined),
                    let fingerprint = report.fingerprint else { return false }
                // Inspection suspends this MainActor method. Re-resolve live ownership before
                // creating storage or durable launch intent so an unreadable/reused process that
                // appeared during inspection cannot be crossed by a new managed launch.
                refresh()
                guard let refreshed = records.first(where: { $0.id == id && !$0.archived }),
                      refreshed == record, states[provider]?.profiles[id] == .stopped,
                      states[provider]?.needsRecovery == false else { fail("ownership"); return false }
                record = refreshed
                let paths = try store.prepareStorage(for: record)
                let existing = Set(runtime.running(provider: provider).map(\.pid))
                let intent = PendingLaunch2(startedAt: runtime.now, fingerprint: fingerprint)
                record.receipt = nil; record.pending = intent
                try replaceRecord(record); launching.insert(id); refresh(); defer { launching.remove(id) }
                let pid = try await runtime.open(.codex(app: report.identity.app, electron: paths.electron, codexHome: paths.codexHome))
                guard case .observed(let stamp) = runtime.observe(pid: pid),
                      LaunchReceipt.canAdopt(stamp, launchedAfter: intent.startedAt.timeIntervalSince1970,
                          executable: report.identity.executable.path, uid: runtime.uid, existingPIDs: existing),
                      runtime.running(provider: provider).contains(where: { $0.pid == pid &&
                          $0.appURL?.resolvingSymlinksInPath() == report.identity.app }),
                      runtime.verifyLiveIdentity(stamp, provider: provider, identity: report.identity),
                      !records.contains(where: { $0.id != id && $0.receipt?.stamp.pid == pid }) else { fail("ownership"); return false }
                record.receipt = LaunchReceipt2(provider: provider, profileID: id, storageGeneration: record.storageGeneration,
                    launchID: intent.launchID, stamp: stamp, paths: paths, fingerprint: fingerprint)
                try replaceRecord(record)
                let after = try await inspector.inspect(provider: provider, at: report.identity.app)
                guard after.fingerprint == fingerprint, after.managedLaunchAllowed,
                      case .observed(let stillLive) = runtime.observe(pid: pid), stillLive == stamp,
                      runtime.verifyLiveIdentity(stillLive, provider: provider, identity: after.identity) else { fail("compatibility"); return false }
                record.pending = nil; try replaceRecord(record)
                guard runtime.activate(stamp, provider: provider) else { fail("ownership"); return false }
                event("managed-launch-verified"); onActivate?(); return true
            }
        } catch { caught(error); return false }
    }
    @discardableResult
    func close(_ id: ManagedProfileID, holdingProviderLock: Bool = false) async -> Bool {
        guard let record = records.first(where: { $0.id == id && !$0.archived }),
              holdingProviderLock || !busy.contains(record.provider) else { return false }
        let provider = record.provider
        guard provider.managedProfilesEnabled else { fail("claude-unvalidated"); return false }
        let ownsProviderLock = !holdingProviderLock
        if ownsProviderLock { busy.insert(provider) }
        quitting.insert(id); refresh()
        defer {
            if ownsProviderLock { busy.remove(provider) }
            quitting.remove(id); refresh()
        }
        do {
            guard record.pending == nil, let receipt = record.receipt, let settings = providers[provider] else { fail("ownership"); return false }
            let identity = try await inspector.identity(provider: provider, at: URL(fileURLWithPath: settings.appPath))
            guard receipt.stamp.executable == identity.executable.path,
                  case .observed(let stamp) = runtime.observe(pid: receipt.stamp.pid),
                  receipt.owns(stamp, profile: record, paths: store.paths(for: record), uid: runtime.uid),
                  runtime.verifyLiveIdentity(stamp, provider: provider, identity: identity),
                  runtime.terminate(stamp, provider: provider) else { fail("ownership"); return false }
            for _ in 0..<100 {
                if case .absent = runtime.observe(pid: stamp.pid), !runtime.running(provider: provider).contains(where: { $0.pid == stamp.pid }) {
                    var next = record; next.receipt = nil; try replaceRecord(next); event("managed-graceful-exit"); return true
                }
                if case .observed(let live) = runtime.observe(pid: stamp.pid), live != stamp { fail("ownership"); return false }
                await runtime.pause()
            }
            fail("quit-timeout"); return false
        } catch { caught(error); return false }
    }
    func restart(_ id: ManagedProfileID) async {
        guard let record = records.first(where: { $0.id == id && !$0.archived }),
              let settings = providers[record.provider], !busy.contains(record.provider) else { return }
        guard record.provider.managedProfilesEnabled else { fail("claude-unvalidated"); return }
        guard model.memoryPressure != .critical else { fail("memory"); return }
        let provider = record.provider
        busy.insert(provider); refresh()
        defer { busy.remove(provider); refresh() }
        do {
            guard let report = try await approvedManagedBuild(provider, settings: settings, allowApproval: true) else { return }
            refresh()
            guard let current = records.first(where: { $0.id == id && !$0.archived }), current == record,
                  case .runningVerified = states[provider]?.profiles[id], states[provider]?.needsRecovery == false,
                  let receipt = current.receipt,
                  case .observed(let stamp) = runtime.observe(pid: receipt.stamp.pid),
                  receipt.owns(stamp, profile: current, paths: store.paths(for: current), uid: runtime.uid) else {
                fail("ownership"); return
            }
            guard runtime.verifyLiveIdentity(stamp, provider: provider, identity: report.identity) else {
                fail(receipt.fingerprint != report.fingerprint ? "updated-running-app" : "ownership"); return
            }
            if await close(id, holdingProviderLock: true) {
                // A restart replaces one verified instance, so it does not increase
                // process count even if pressure changes during the graceful close.
                _ = await open(.managed(id), allowCriticalMemory: true, holdingProviderLock: true,
                               allowBuildApproval: false)
            }
        } catch { caught(error) }
    }
    /// Caller owns the provider lock. No process is adopted or controlled here.
    @discardableResult
    private func recoverQuiescentProvider(_ provider: ProviderID2, automatic: Bool) async -> Bool {
        func ineligible(_ reason: String) -> Bool {
            if automatic { event("automatic-recovery-not-eligible:" + reason) }
            return false
        }
        guard provider.managedProfilesEnabled, busy.contains(provider),
              states[provider]?.needsRecovery == true,
              (!automatic || automaticPendingIsOldEnough(provider)),
              launching.isDisjoint(with: Set(records.filter { $0.provider == provider }.map(\.id))),
              quitting.isDisjoint(with: Set(records.filter { $0.provider == provider }.map(\.id))),
              !currentLaunching.contains(provider) else { return ineligible("state") }
        guard runtime.running(provider: provider).isEmpty else { return ineligible("process-running") }
        await runtime.pause()
        guard runtime.running(provider: provider).isEmpty else { return ineligible("process-after-pause") }
        do {
            guard try store.listProfiles() == records,
                  !(try store.hasPendingOperations(provider: provider)),
                  !(try store.hasOrphanStorage(provider: provider, records: records)) else { return ineligible("metadata") }
            var hypothetical = records
            var changed = false
            for index in hypothetical.indices where hypothetical[index].provider == provider {
                if let receipt = hypothetical[index].receipt {
                    guard case .absent = runtime.observe(pid: receipt.stamp.pid) else { return ineligible("receipt-unverified") }
                    hypothetical[index].receipt = nil; changed = true
                }
                if hypothetical[index].pending != nil { hypothetical[index].pending = nil; changed = true }
            }
            guard changed else { return ineligible("no-stale-metadata") }
            let resolved = DynamicStateResolver.resolve(provider: provider, records: hypothetical, root: store.root,
                officialPIDs: [], observations: [:], uid: runtime.uid)
            guard !resolved.needsRecovery else { return ineligible("hypothetical-uncertain") }
            for record in hypothetical where record.provider == provider {
                guard runtime.running(provider: provider).isEmpty,
                      try store.listProfiles() == records else { return ineligible("process-or-metadata-changed") }
                if let original = records.first(where: { $0.id == record.id }), original != record {
                    if let receipt = original.receipt {
                        guard case .absent = runtime.observe(pid: receipt.stamp.pid) else { return ineligible("receipt-changed") }
                    }
                    guard runtime.running(provider: provider).isEmpty else { return ineligible("process-before-write") }
                    try replaceRecord(record)
                }
            }
            guard runtime.running(provider: provider).isEmpty else { return ineligible("process-after-write") }
            refresh()
            if automatic { event("automatic-safe-recovery-completed") }
            return true
        } catch {
            event(automatic ? "automatic-recovery-not-eligible:persistence" : "safe-recovery-save-failed")
            return false
        }
    }
    func recover(_ provider: ProviderID2) async {
        guard provider.managedProfilesEnabled else { fail("claude-unvalidated"); return }
        guard !busy.contains(provider), let settings = providers[provider] else { return }
        busy.insert(provider); defer { busy.remove(provider); refresh() }
        do {
            let apps = runtime.running(provider: provider)
            if !apps.isEmpty {
                let report = try await inspector.inspect(provider: provider, at: URL(fileURLWithPath: settings.appPath))
                identities[provider] = report.identity
                guard report.managedLaunchAllowed, let approved = settings.approvedFingerprint, report.fingerprint == approved,
                      !providerHasMetadataIssue(provider) else { fail("ownership"); return }
                let pending = records.filter { $0.provider == provider && $0.pending != nil }
                guard !pending.isEmpty else { fail("ownership"); return }
                for record in pending {
                    guard let intent = record.pending, let receipt = record.receipt,
                          intent.fingerprint == approved, receipt.fingerprint == approved, intent.launchID == receipt.launchID,
                          apps.contains(where: { $0.pid == receipt.stamp.pid &&
                              $0.appURL?.resolvingSymlinksInPath() == report.identity.app }),
                          case .observed(let stamp) = runtime.observe(pid: receipt.stamp.pid),
                          stamp.executable == report.identity.executable.path,
                          runtime.verifyLiveIdentity(stamp, provider: provider, identity: report.identity),
                          receipt.owns(stamp, profile: record, paths: store.paths(for: record), uid: runtime.uid) else { fail("ownership"); return }
                }
                for var record in pending { record.pending = nil; try replaceRecord(record) }
            } else {
                refresh()
                let hasStaleLaunchMetadata = records.contains {
                    $0.provider == provider && ($0.pending != nil || $0.receipt != nil)
                }
                if hasStaleLaunchMetadata {
                    guard await recoverQuiescentProvider(provider, automatic: false) else { fail("ownership"); return }
                } else {
                    await runtime.pause()
                }
                guard runtime.running(provider: provider).isEmpty else { fail("ownership"); return }
                try store.recoverArchives(evidence: ProviderQuiescence2(provider: provider, officialProcessCount: 0, hasUnverifiableProcesses: false))
                records = try store.listProfiles()
                if try store.hasOrphanStorage(provider: provider, records: records) { fail("ownership"); return }
            }
            event("safe-recovery-completed")
        } catch { caught(error) }
    }
    func archive(_ id: ManagedProfileID, reset: Bool) {
        guard let record = records.first(where: { $0.id == id }), !busy.contains(record.provider) else { return }
        guard record.provider.managedProfilesEnabled else { fail("claude-unvalidated"); return }
        refresh()
        guard states[record.provider]?.needsRecovery == false, runtime.running(provider: record.provider).isEmpty else { fail("ownership"); return }
        do {
            let result = try store.archive(profileID: id, reset: reset,
                evidence: ProviderQuiescence2(provider: record.provider, officialProcessCount: 0, hasUnverifiableProcesses: false))
            if let index = records.firstIndex(where: { $0.id == id }) { records[index] = result.profile }
            _ = replaceShortcuts?(shortcutBindings())
            event(reset ? "storage-archived-reset" : "profile-archived")
        } catch { caught(error) }
        refresh()
    }
    func delete(_ id: ManagedProfileID) async {
        guard let initial = records.first(where: { $0.id == id && !$0.archived }),
              initial.provider == .codex, !busy.contains(initial.provider) else { return }
        let provider = initial.provider
        busy.insert(provider); refresh()
        defer { busy.remove(provider); refresh() }
        guard !providerHasMetadataIssue(provider), let initialState = states[provider],
              !initialState.needsRecovery, currentIsKnown(initialState),
              initial.pending == nil else { fail("delete-ownership"); return }
        switch states[provider]?.profiles[id] {
        case .runningVerified:
            guard await close(id, holdingProviderLock: true) else { fail("delete-close"); return }
        case .stopped:
            guard initial.receipt == nil else { fail("delete-ownership"); return }
        default: fail("delete-ownership"); return
        }
        refresh()
        guard !providerHasMetadataIssue(provider), let finalState = states[provider],
              !finalState.needsRecovery, currentIsKnown(finalState),
              states[provider]?.profiles[id] == .stopped,
              let current = records.first(where: { $0.id == id && !$0.archived }),
              current.pending == nil, current.receipt == nil else { fail("delete-ownership"); return }
        let previous = shortcutBindings()
        var removed = current
        removed.archived = true; removed.favorite = false; removed.shortcut = nil; removed.launchAtLogin = false
        guard acceptShortcuts(shortcutBindings(profiles: records.map { $0.id == id ? removed : $0 })) else {
            fail("shortcut"); return
        }
        do {
            let saved = try store.removeProfile(current)
            if let index = records.firstIndex(where: { $0.id == id }) { records[index] = saved }
            event("profile-removed")
        } catch {
            // A failed fsync can follow an atomic metadata rename. Read the durable
            // record before deciding whether the old shortcut should be restored.
            if let durable = try? store.listProfiles() {
                records = durable
                _ = replaceShortcuts?(shortcutBindings())
                if durable.first(where: { $0.id == id })?.archived == true { event("profile-removed") }
                else { fail("delete-ownership") }
            } else {
                _ = replaceShortcuts?(previous)
                fail("delete-ownership")
            }
        }
    }
    func shortcutBindings(profiles: [ProfileRecord2]? = nil, providerSettings: [ProviderID2: ProviderSettings2]? = nil) -> [HotKeys.Binding] {
        let currentProviders = providerSettings ?? providers
        var values = currentProviders.values.compactMap { settings in settings.currentShortcut.map {
            HotKeys.Binding(targetID: "current:" + settings.provider.rawValue, keyCode: $0.keyCode, modifiers: $0.modifiers)
        } }
        values += (profiles ?? records).filter { !$0.archived && $0.provider.managedProfilesEnabled }.compactMap { profile in profile.shortcut.map {
            HotKeys.Binding(targetID: profile.id.description, keyCode: $0.keyCode, modifiers: $0.modifiers)
        } }
        return values
    }
    private func acceptShortcuts(_ bindings: [HotKeys.Binding]) -> Bool {
        var seen = Set<Shortcut2>()
        guard bindings.allSatisfy({ HotKeys.isValid(keyCode: $0.keyCode, modifiers: $0.modifiers) &&
            seen.insert(Shortcut2(keyCode: $0.keyCode, modifiers: $0.modifiers)).inserted }) else { return false }
        return replaceShortcuts?(bindings) ?? true
    }
    func saveDraft(id: String?, draft: PairbarProfileDraft) {
        guard let selectedProvider = ProviderID2(rawValue: draft.providerID), !busy.contains(selectedProvider) else { return }
        let oldBindings = shortcutBindings()
        do {
            let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let shortcut = draft.shortcut.map { Shortcut2(keyCode: $0.keyCode, modifiers: $0.modifiers) }
            if let id, case .current(let provider) = target(id), provider == selectedProvider, var value = providers[provider] {
                value.currentName = name; value.currentFavorite = draft.favorite; value.currentShortcut = shortcut; value.currentLaunchAtLogin = draft.openAtLogin
                var next = providers; next[provider] = value
                guard acceptShortcuts(shortcutBindings(providerSettings: next)) else { fail("shortcut"); return }
                try store.saveProvider(value); providers = next
            } else if id == nil {
                var record: ProfileRecord2
                guard selectedProvider == .codex else { fail("claude-unvalidated"); return }
                record = ProfileRecord2(provider: selectedProvider, name: name)
                let maximum = records.map(\.order).max() ?? 0
                guard maximum < Int.max else { fail(); return }
                record.order = maximum + 1
                let occupied = Set(providers.values.compactMap(\.currentShortcut) +
                    records.filter { !$0.archived }.compactMap(\.shortcut))
                record.name = name; record.favorite = draft.favorite; record.launchAtLogin = draft.openAtLogin
                if let shortcut {
                    record.shortcut = shortcut
                    guard acceptShortcuts(shortcutBindings(profiles: records + [record])) else { fail("shortcut"); return }
                } else {
                    // Skip chords reserved by another app; the profile itself is unlimited.
                    for candidate in NumericShortcutPolicy.available(occupied: occupied) {
                        record.shortcut = candidate
                        if acceptShortcuts(shortcutBindings(profiles: records + [record])) { break }
                        record.shortcut = nil
                    }
                    // With no registered chord, saving the profile cannot change hotkeys.
                }
                try replaceRecord(record)
            } else if let id, let uuid = UUID(uuidString: id),
                      var record = records.first(where: { $0.id.rawValue == uuid && !$0.archived }) {
                guard record.provider == selectedProvider else { return }
                record.name = name; record.favorite = draft.favorite; record.shortcut = shortcut; record.launchAtLogin = draft.openAtLogin
                let next = records.filter { $0.id != record.id } + [record]
                guard acceptShortcuts(shortcutBindings(profiles: next)) else { fail("shortcut"); return }
                try replaceRecord(record)
            } else {
                fail("operation-blocked"); return
            }
            model.errorMessage = nil; model.profileSaved()
        } catch { _ = replaceShortcuts?(oldBindings); caught(error) }
        refresh()
    }
    func editMetadata(_ id: String, change: (inout PairbarProfileDraft) -> Void) {
        guard let row = model.rows.first(where: { $0.id == id }), row.canEdit else { return }
        var draft = PairbarProfileDraft(providerID: row.providerID, name: row.name, favorite: row.favorite,
                                       shortcut: row.shortcut, openAtLogin: row.openAtLogin)
        change(&draft); saveDraft(id: id, draft: draft)
    }
    func launchAtLogin(isLoginEvent: Bool) async {
        guard isLoginEvent, !loginHandled else { return }; loginHandled = true
        guard preferences.launchSelectedAtLogin else { return }
        var targets = providers.values.filter(\.currentLaunchAtLogin).sorted { $0.provider.rawValue < $1.provider.rawValue }.map { AccountTarget2.current($0.provider) }
        targets += records.filter { !$0.archived && $0.launchAtLogin && $0.provider.managedProfilesEnabled }
            .sorted { $0.order < $1.order }.map { .managed($0.id) }
        await openBatch(targets, automatic: true)
    }
    func openBatch(_ targets: [AccountTarget2], automatic: Bool = false, allowCriticalMemory: Bool = false) async {
        guard !batchRunning else { return }; batchRunning = true; defer { batchRunning = false }
        var seen = Set<AccountTarget2>()
        var declinedProviders = Set<ProviderID2>()
        for target in targets where seen.insert(target).inserted {
            if let provider = provider(for: target), declinedProviders.contains(provider) { continue }
            if model.memoryPressure == .critical && needsNewInstance(target) && (automatic || !allowCriticalMemory) {
                fail("memory"); break
            }
            // Targets are independent. A missing/invalid optional provider or one stale
            // selection must not prevent later safe targets from opening. Critical memory
            // remains the only batch-wide stop because it applies to every new instance.
            _ = await open(target, allowCriticalMemory: allowCriticalMemory, allowBuildApproval: !automatic,
                           onBuildApprovalDeclined: { declinedProviders.insert($0) })
        }
    }
    private func handle(_ action: PairbarPanelAction) {
        switch action {
        case .open(let id):
            if let target = target(id) {
                let override = model.memoryPressure == .critical && needsNewInstance(target) ? confirmMemory() : false
                if model.memoryPressure != .critical || !needsNewInstance(target) || override {
                    Task { _ = await open(target, allowCriticalMemory: override) }
                }
            }
        case .openSelected(let ids):
            let targets = ids.compactMap(target)
            let needsOverride = model.memoryPressure == .critical && targets.contains(where: needsNewInstance)
            let override = needsOverride ? confirmMemory() : false
            if !needsOverride || override { Task { await openBatch(targets, allowCriticalMemory: override) } }
        case .create(let draft): saveDraft(id: nil, draft: draft)
        case .update(let id, let draft): saveDraft(id: id, draft: draft)
        case .favorite(let id, let value): editMetadata(id) { $0.favorite = value }
        case .setProfileAtLogin(let id, let value): editMetadata(id) { $0.openAtLogin = value }
        case .move(let id, let offset): move(id, offset: offset)
        case .close(let id): if let uuid = UUID(uuidString: id) { Task { _ = await close(ManagedProfileID(uuid)) } }
        case .restart(let id): if let uuid = UUID(uuidString: id) { Task { await restart(ManagedProfileID(uuid)) } }
        case .archive(let id): if let uuid = UUID(uuidString: id) { archive(ManagedProfileID(uuid), reset: false) }
        case .delete(let id): if let uuid = UUID(uuidString: id) { Task { await delete(ManagedProfileID(uuid)) } }
        case .reset(let id): if let uuid = UUID(uuidString: id) { archive(ManagedProfileID(uuid), reset: true) }
        case .check(let id): if let provider = ProviderID2(rawValue: id) { Task { await check(provider) } }
        case .recover(let id): if let provider = ProviderID2(rawValue: id) { Task { await recover(provider) } }
        case .choose(let id): if let provider = ProviderID2(rawValue: id) { choose(provider) }
        case .setStartAtLogin(let enabled): configureLogin(enabled)
        case .setOpenProfilesAtLogin(let enabled):
            var next = preferences; next.launchSelectedAtLogin = enabled; savePreferences(next)
        case .setLanguage(let language):
            model.errorMessage = nil
            var next = preferences; next.language = language.rawValue; savePreferences(next)
            refreshLogin()
        case .completeWelcome:
            var next = preferences; next.welcomeDismissed = true; savePreferences(next)
            if preferences.welcomeDismissed { UserDefaults.standard.set(true, forKey: "pairbarWelcomeCompleted") }
        case .copyDiagnostics: NSPasteboard.general.clearContents(); NSPasteboard.general.setString(diagnosticText, forType: .string)
        case .clearDiagnostics: events = []; refresh()
        case .exportConfiguration: exportConfiguration()
        case .quitPairbar: NSApp.terminate(nil)
        }
    }
    private func needsNewInstance(_ target: AccountTarget2) -> Bool {
        switch target {
        case .current(let provider): return states[provider]?.current == .stopped
        case .managed(let id):
            guard let provider = records.first(where: { $0.id == id })?.provider else { return false }
            return states[provider]?.profiles[id] == .stopped
        }
    }
    private func savePreferences(_ next: Preferences2) {
        do { try store.savePreferences(next); preferences = next; model.language = PairbarLanguage(rawValue: next.language) ?? .system }
        catch { caught(error) }; refresh()
    }
    private func confirmMemory() -> Bool {
        guard model.memoryPressure == .critical else { return false }
        let alert = NSAlert(); alert.messageText = text("Memory pressure is critical", "La presión de memoria es crítica")
        alert.informativeText = text("Opening more instances may slow your Mac. Existing instances will stay open.", "Abrir más instancias puede ralentizar el Mac. Las existentes seguirán abiertas.")
        alert.addButton(withTitle: text("Cancel", "Cancelar")); alert.addButton(withTitle: text("Open anyway", "Abrir igualmente"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    private func move(_ id: String, offset: Int) {
        guard offset == -1 || offset == 1,
              let row = model.rows.first(where: { $0.id == id }), row.canEdit, let target = target(id) else { return }
        do {
            let peers = model.orderedRows.filter { $0.providerID == row.providerID && $0.favorite == row.favorite }
            guard let index = peers.firstIndex(where: { $0.id == id }) else { return }
            let destination = index + offset
            guard peers.indices.contains(destination) else { return }
            let newOrder = peers[destination].order.addingReportingOverflow(offset < 0 ? -1 : 1)
            guard !newOrder.overflow, (-1_000_000_000...1_000_000_000).contains(newOrder.partialValue) else { return }
            switch target {
            case .current(let provider):
                guard var value = providers[provider] else { return }; value.currentOrder = newOrder.partialValue
                try store.saveProvider(value); providers[provider] = value
            case .managed(let id):
                guard var record = records.first(where: { $0.id == id }) else { return }
                record.order = newOrder.partialValue; try replaceRecord(record)
            }
        } catch { caught(error) }; refresh()
    }
    private func choose(_ provider: ProviderID2) {
        guard !busy.contains(provider) else { return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.applicationBundle]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            guard !busy.contains(provider), var settings = providers[provider] else { return }
            busy.insert(provider); defer { busy.remove(provider); refresh() }
            do {
                let identity = try await inspector.identity(provider: provider, at: url)
                settings.appPath = identity.app.path
                try store.saveProvider(settings); providers[provider] = settings; identities[provider] = identity; reports[provider] = nil
            } catch { caught(error) }
        }
    }
    func refreshLogin() {
        model.startAtLogin = SMAppService.mainApp.status == .enabled
        switch SMAppService.mainApp.status {
        case .enabled: model.loginStatus = text("Enabled", "Activado")
        case .requiresApproval: model.loginStatus = text("Approve in System Settings", "Requiere aprobación en Ajustes del Sistema")
        case .notRegistered: model.loginStatus = text("Disabled", "Desactivado")
        default: model.loginStatus = text("Install Pairbar in Applications first", "Instala Pairbar en Aplicaciones primero")
        }
    }
    private func configureLogin(_ enabled: Bool) {
        do {
            guard Bundle.main.bundleURL.pathExtension == "app", Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else { fail(); return }
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
            refreshLogin()
        } catch { caught(error); refreshLogin() }
    }
    private func exportConfiguration() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = "Pairbar-configuration.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let data = try ConfigurationExport2(preferences: preferences, providers: Array(providers.values), profiles: records).jsonData()
            try data.write(to: url, options: .atomic)
        } catch { caught(error) }
    }
}
