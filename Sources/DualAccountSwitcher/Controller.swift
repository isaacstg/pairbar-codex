import AppKit
import Foundation
import Darwin
import ServiceManagement
import SwitcherCore

@MainActor
final class Controller: NSObject, ObservableObject {
    @Published var settings: Settings
    @Published private(set) var currentState: CurrentAccountState = .stopped
    @Published private(set) var secondaryState: SecondaryAccountState = .stopped
    @Published var status: [ProfileID: String] = [.a: "Not running", .b: "Not running"]
    @Published var logs: [String] = []
    @Published var compatibilityText = "Isolation compatibility has not been checked. Current Account can still use the normal official app."
    @Published private(set) var isolationReadiness: IsolationReadiness = .notChecked
    @Published private(set) var errorMessage: String?
    @Published var busy = false
    @Published var loginStatus = "Disabled"

    let previewOnly: Bool
    let store: PrivateStore

    private let runtime = OfficialAppRuntime()
    private var receipts: [LaunchReceipt]
    private var inFlight = Set<ProfileID>()
    private var uncertainty = Set<ProfileID>()
    private var shuttingDown = Set<ProfileID>()
    private var openBothInFlight = false
    private var timer: Timer?
    private var cachedReport: CompatibilityReport?
    var onChange: (() -> Void)?
    var onRequestPresentation: (() -> Void)?
    var onAccountActivated: (() -> Void)?

    init(store: PrivateStore, previewOnly: Bool = false) throws {
        self.previewOnly = previewOnly
        self.store = store

        var loadedSettings = try store.load(Settings.self, name: "settings.json") ?? Settings()
        if loadedSettings.isFromFutureVersion {
            throw SwitcherError.message("These settings were written by a newer Pairbar version. Install that version (or newer) instead of downgrading, so unknown settings are not discarded.")
        }
        if loadedSettings.needsSchemaRewrite {
            loadedSettings.schemaVersion = Settings.currentSchemaVersion
            try store.save(loadedSettings, name: "settings.json")
        }
        settings = loadedSettings

        let loadedPending = try store.load([ProfileID].self, name: "pending.json") ?? []
        let loadedReceipts = try store.load([LaunchReceipt].self, name: "receipts.json") ?? []
        let migratedPending = MetadataMigration.keepSecondaryPending(loadedPending)
        let migratedReceipts = try MetadataMigration.keepSecondaryReceipts(loadedReceipts)
        uncertainty = Set(migratedPending)
        receipts = migratedReceipts

        // Migration changes metadata only. Legacy A profile directories are intentionally untouched.
        if loadedPending != migratedPending { try store.save(migratedPending, name: "pending.json") }
        if loadedReceipts != migratedReceipts { try store.save(migratedReceipts, name: "receipts.json") }

        super.init()

        refresh()
        refreshLogin()
        // Selector-based scheduling avoids the Swift 6 sendability diagnostic produced by
        // Timer's closure overload on the macOS 14 GitHub Actions toolchain.
        timer = Timer.scheduledTimer(timeInterval: 2,
                                     target: self,
                                     selector: #selector(refreshTimerFired(_:)),
                                     userInfo: nil,
                                     repeats: true)
        log("Controller ready. Current Account uses normal ChatGPT storage; Second Account alone is isolated. No credentials were read or copied.")
    }

    deinit { timer?.invalidate() }

    @objc private func refreshTimerFired(_ timer: Timer) {
        refresh()
    }

    // MARK: - Public derived state

    var capabilities: AccountCapabilities {
        AccountCapabilities(current: currentState, secondary: secondaryState,
                            secondarySetupComplete: settings.setupComplete,
                            compatibilityBusy: busy)
    }

    var canResetSecond: Bool {
        !previewOnly && !busy && !inFlight.contains(.b) && !shuttingDown.contains(.b) &&
        uncertainty.isEmpty && receipts.isEmpty && secondaryState == .stopped &&
        officialApps.isEmpty && store.secondaryProfileExists
    }

    var canEditSettings: Bool {
        !busy && inFlight.isEmpty && shuttingDown.isEmpty
    }

    // UI-only progress. Pending metadata still blocks ownership and unsafe actions in core.
    var secondaryIsOpening: Bool { inFlight.contains(.b) }

    var unmanagedCount: Int {
        if case .ambiguous(let count) = currentState { return max(0, count - 1) }
        return 0
    }

    // MARK: - Logging / errors

    func log(_ message: String) {
        logs.append(Date().formatted(date: .omitted, time: .standard) + "  " + message)
        if logs.count > 200 { logs.removeFirst(logs.count - 200) }
        onChange?()
    }

    func clearLog() {
        logs.removeAll()
        onChange?()
    }

    func showError(_ error: Error) {
        log(error.localizedDescription)
        errorMessage = error.localizedDescription
        onRequestPresentation?()
    }

    func clearError() {
        errorMessage = nil
    }

    // MARK: - Process discovery / ownership

    private var secondaryPaths: ProfilePaths { ProfilePaths(root: store.root, id: .b) }

    private var officialApps: [NSRunningApplication] { runtime.runningApplications() }

    private func verifiedSecondary() -> NSRunningApplication? {
        guard let receipt = receipts.first,
              receipt.owns(ProcessStamp.read(pid: receipt.stamp.pid), paths: secondaryPaths, uid: getuid()),
              let app = runtime.application(pid: receipt.stamp.pid) else { return nil }
        return app
    }

    private var currentApps: [NSRunningApplication] {
        let verifiedB = verifiedSecondary()?.processIdentifier
        let candidates = Set(AccountStateResolver.currentCandidatePIDs(
            officialPIDs: officialApps.map(\.processIdentifier), verifiedSecondaryPID: verifiedB
        ))
        return officialApps.filter { candidates.contains($0.processIdentifier) }
    }

    private func reconcileDeadSecondaryReceipt() {
        guard !uncertainty.contains(.b), !inFlight.contains(.b), !shuttingDown.contains(.b),
              let receipt = receipts.first else { return }
        guard ProcessStamp.read(pid: receipt.stamp.pid) == nil,
              runtime.application(pid: receipt.stamp.pid) == nil else { return }
        do {
            try store.save([LaunchReceipt](), name: "receipts.json")
            receipts = []
            log("Cleared a stale Second Account receipt; isolated account data was preserved.")
        } catch {
            // Safe failure mode: stale metadata remains and ownership is never inferred from it.
        }
    }

    func refresh() {
        reconcileDeadSecondaryReceipt()

        let apps = officialApps
        let receipt = receipts.first
        let currentStamp = receipt.flatMap { ProcessStamp.read(pid: $0.stamp.pid) }
        let recordedPIDIsLive = receipt.flatMap { runtime.application(pid: $0.stamp.pid) } != nil
        secondaryState = AccountStateResolver.secondary(
            receipt: receipt,
            currentStamp: currentStamp,
            paths: secondaryPaths,
            uid: getuid(),
            pending: uncertainty.contains(.b),
            launching: inFlight.contains(.b),
            quitting: shuttingDown.contains(.b),
            recordedPIDIsLive: recordedPIDIsLive
        )

        let verifiedB = verifiedSecondary()
        currentState = AccountStateResolver.current(
            officialPIDs: apps.map(\.processIdentifier),
            verifiedSecondaryPID: verifiedB?.processIdentifier,
            secondaryOwnershipUncertain: secondaryState.needsRecovery,
            launching: inFlight.contains(.a)
        )

        status[.a] = currentState.displayText
        status[.b] = secondaryState.displayText
        onChange?()
    }

    // MARK: - Official app identity / compatibility

    /// Finds the genuine official app only in the configured path or standard install locations.
    /// This is sufficient for Current Account and deliberately does not require isolation markers.
    private func resolveOfficialIdentity() async throws -> OfficialAppIdentity {
        let preferred = URL(fileURLWithPath: settings.appPath)
        var lastError: Error?
        for candidate in Compatibility.standardCandidates(preferred: preferred) {
            do {
                let identity = try await Task.detached(priority: .userInitiated) {
                    try Compatibility.inspectOfficialIdentity(candidate)
                }.value
                if identity.app.path != settings.appPath {
                    var next = settings
                    next.appPath = identity.app.path
                    try store.save(next, name: "settings.json")
                    settings = next
                    cachedReport = nil
                    isolationReadiness = .notChecked
                    compatibilityText = "Official app was found at \(identity.app.path). Recheck isolation compatibility before launching Second Account."
                    log("Updated the stored official app location after verifying OpenAI's signature.")
                }
                return identity
            } catch {
                lastError = error
            }
        }
        throw lastError ?? SwitcherError.message("The official ChatGPT app could not be found in a trusted standard location.")
    }

    func checkCompatibility() async -> CompatibilityReport? {
        guard !busy else { return cachedReport }
        busy = true
        isolationReadiness = .checking
        defer { busy = false; refresh() }
        do {
            let identity = try await resolveOfficialIdentity()
            let report = try await Task.detached(priority: .userInitiated) {
                try Compatibility.inspect(identity.app)
            }.value
            cachedReport = report
            isolationReadiness = .inspected(version: report.version, fingerprint: report.fingerprint, settings: settings)
            compatibilityText = report.summary
            if let approved = settings.approvedFingerprint, approved != report.fingerprint {
                compatibilityText += "\nThe official app changed. Current Account remains usable, but this build must be approved before launching Second Account."
            } else if settings.approvedFingerprint == nil {
                compatibilityText += "\nSecond Account has not approved this build yet."
            }
            return report
        } catch {
            cachedReport = nil
            isolationReadiness = .unavailable(reason: error.localizedDescription)
            compatibilityText = error.localizedDescription
            log("Isolation compatibility check failed: " + error.localizedDescription)
            return nil
        }
    }

    /// Explicit setup/update confirmation. Label editing cannot enter this path.
    @discardableResult
    func authorizeInstalledBuild() async -> Bool {
        guard !busy, inFlight.isEmpty, shuttingDown.isEmpty else { return false }
        refresh()
        guard secondaryState.allowsBuildConfirmation else {
            showError(SwitcherError.message("Resolve Second Account recovery before confirming a ChatGPT update. An uncertain running instance must not be trusted by approving a different build."))
            return false
        }
        clearError()
        // Inspect again at the moment of confirmation, rather than trusting a stale UI report.
        guard let report = await checkCompatibility() else { return false }
        refresh()
        guard secondaryState.allowsBuildConfirmation else {
            showError(SwitcherError.message("Second Account state changed during the app check. Resolve recovery before confirming this version."))
            return false
        }

        var next = settings
        next.schemaVersion = Settings.currentSchemaVersion
        next.appPath = report.app.path
        next.approvedFingerprint = report.fingerprint
        next.setupComplete = true
        do {
            try store.save(next, name: "settings.json")
            settings = next
            isolationReadiness = .ready(version: report.version)
            compatibilityText = report.summary + "\nApproved for Second Account isolation."
            log("Settings saved. Current Account remains unchanged; Second Account build fingerprint approved.")
            refresh()
            return true
        } catch { showError(error); return false }
    }

    @discardableResult
    func saveAccountLabels(current: String, second: String) -> Bool {
        guard !busy, inFlight.isEmpty, shuttingDown.isEmpty else { return false }
        do {
            let next = try settings.renamingAccounts(current: current, second: second)
            try store.save(next, name: "settings.json")
            settings = next
            clearError()
            log("Account names saved. Isolation approval was not changed.")
            return true
        } catch { showError(error); return false }
    }

    func chooseApp() {
        guard inFlight.isEmpty, shuttingDown.isEmpty, !busy else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = false
        panel.message = "Locate the official ChatGPT.app."
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                busy = true
                do {
                    let identity = try await Task.detached(priority: .userInitiated) {
                        try Compatibility.inspectOfficialIdentity(url)
                    }.value
                    var next = settings
                    next.appPath = identity.app.path
                    try store.save(next, name: "settings.json")
                    settings = next
                    cachedReport = nil
                    isolationReadiness = .notChecked
                    busy = false
                    _ = await checkCompatibility()
                } catch {
                    busy = false
                    showError(error)
                }
                onRequestPresentation?()
            }
        } else {
            onRequestPresentation?()
        }
    }

    // MARK: - Open / focus

    func open(_ id: ProfileID) async {
        guard !previewOnly else {
            showError(SwitcherError.message("UI preview cannot launch accounts."))
            return
        }

        // Current Account does not depend on isolated-profile setup or fingerprint approval.
        if id == .a {
            await openCurrent()
            return
        }

        guard settings.setupComplete else {
            showError(SwitcherError.message("Choose Set Up Second Account in the switcher before opening Second Account."))
            return
        }
        await openSecond()
    }

    private func openCurrent() async {
        guard !inFlight.contains(.a) else { return }
        refresh()
        guard !secondaryState.needsRecovery else {
            showError(SwitcherError.message("Current Account discovery is temporarily blocked because a previous Second Account launch has uncertain ownership. Use Safe Recovery first so the switcher does not mistake an orphaned Second process for Current."))
            return
        }

        let candidates = currentApps
        if candidates.count == 1 {
            runtime.activate(candidates[0])
            onAccountActivated?()
            return
        }
        guard candidates.isEmpty else {
            showError(SwitcherError.message("More than one default ChatGPT instance is running. The switcher will not guess which one is Current Account. Close the extra default instance(s), then retry."))
            return
        }

        inFlight.insert(.a)
        refresh()
        defer { inFlight.remove(.a); refresh() }

        do {
            let identity = try await resolveOfficialIdentity()
            let app = try await runtime.openCurrent(identity.app)
            guard app.bundleIdentifier == Compatibility.bundleIdentifier,
                  let stamp = ProcessStamp.read(pid: app.processIdentifier),
                  stamp.uid == getuid(), stamp.executable == identity.executable.path else {
                throw SwitcherError.message("macOS returned an unexpected process for Current Account. It was not adopted or controlled.")
            }
            runtime.activate(app)
            onAccountActivated?()
            log("Opened Current Account normally with no CODEX_HOME or Electron profile override.")
        } catch { showError(error) }
    }

    private func openSecond() async {
        guard !inFlight.contains(.b), !shuttingDown.contains(.b), !busy else { return }

        if let app = verifiedSecondary() {
            runtime.activate(app)
            onAccountActivated?()
            return
        }
        guard !uncertainty.contains(.b) else {
            showError(SwitcherError.message("The previous Second Account launch has uncertain ownership. Open Help and choose Try Safe Recovery before retrying."))
            return
        }
        if let receipt = receipts.first, runtime.application(pid: receipt.stamp.pid) != nil {
            showError(SwitcherError.message("The recorded Second Account process is live but cannot be verified. It will not be controlled. Quit it manually before recovery."))
            return
        }

        inFlight.insert(.b)
        refresh()
        defer { inFlight.remove(.b); refresh() }

        guard let report = await checkCompatibility() else { return }
        guard report.fingerprint == settings.approvedFingerprint else {
            showError(SwitcherError.message("ChatGPT was updated. Choose Confirm ChatGPT Update in the switcher before opening Second Account again."))
            return
        }

        do {
            let paths = try store.prepareSecondary()
            let plan = LaunchPlan(paths: paths,
                                  userHome: FileManager.default.homeDirectoryForCurrentUser,
                                  username: NSUserName(),
                                  temporaryDirectory: NSTemporaryDirectory())
            let existing = Set(officialApps.map(\.processIdentifier))

            // Persist uncertainty before LaunchServices can create a process.
            try store.save([ProfileID.b], name: "pending.json")
            uncertainty.insert(.b)
            refresh()

            let started = Date().timeIntervalSince1970
            let app = try await runtime.openSecond(report.app, plan: plan)
            guard let stamp = ProcessStamp.read(pid: app.processIdentifier),
                  LaunchReceipt.canAdopt(stamp, launchedAfter: started,
                                         executable: report.executable.path,
                                         uid: getuid(), existingPIDs: existing) else {
                throw SwitcherError.message("macOS did not return a verifiable new Second Account process. It will not be controlled.")
            }

            let receipt = LaunchReceipt(profile: .b, stamp: stamp, paths: paths)
            try store.save([receipt], name: "receipts.json")
            receipts = [receipt]

            // If an updater swaps the bundle during launch, keep pending=true. Because the receipt
            // was already persisted, recovery can prove the process but still requires the approved
            // fingerprint before clearing the pending state.
            let after = try await Task.detached(priority: .userInitiated) {
                try Compatibility.inspect(report.app)
            }.value
            guard after.fingerprint == report.fingerprint else {
                throw SwitcherError.message("The official app changed during Second Account launch. The verified receipt was preserved, but the launch stays quarantined until safe recovery.")
            }

            try store.save([ProfileID](), name: "pending.json")
            uncertainty.remove(.b)
            runtime.activate(app)
            onAccountActivated?()
            log("Launched Second Account with independent Codex and Electron storage.")
        } catch {
            refresh()
            showError(error)
        }
    }

    func openBoth() async {
        guard !openBothInFlight else { return }
        openBothInFlight = true
        defer { openBothInFlight = false; refresh() }
        await open(.a)
        await open(.b)
    }

    // MARK: - Second Account lifecycle

    func quit(_ id: ProfileID) async -> Bool {
        if id == .a {
            showError(SwitcherError.message("Current Account belongs to normal ChatGPT and is intentionally not owned by the switcher. Quit it from ChatGPT itself."))
            return false
        }
        guard !previewOnly, !inFlight.contains(.b), !shuttingDown.contains(.b), !uncertainty.contains(.b) else {
            return false
        }
        guard let app = verifiedSecondary() else {
            if let receipt = receipts.first, runtime.application(pid: receipt.stamp.pid) != nil {
                showError(SwitcherError.message("Second Account ownership cannot be verified, so the switcher will not terminate that process."))
                return false
            }
            reconcileDeadSecondaryReceipt()
            refresh()
            return receipts.isEmpty
        }

        shuttingDown.insert(.b)
        refresh()
        defer { shuttingDown.remove(.b); refresh() }

        guard app.terminate() else {
            showError(SwitcherError.message("Second Account declined to quit."))
            return false
        }

        for _ in 0..<100 {
            if verifiedSecondary() == nil {
                guard app.isTerminated else {
                    showError(SwitcherError.message("Process identity changed while quitting. No further action was taken."))
                    return false
                }
                do {
                    try store.save([LaunchReceipt](), name: "receipts.json")
                    receipts = []
                    log("Second Account quit gracefully.")
                    return true
                } catch {
                    showError(error)
                    return false
                }
            }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        showError(SwitcherError.message("Second Account has not quit after 20 seconds. Restart was cancelled and no forced kill was sent."))
        return false
    }

    func restart(_ id: ProfileID) async {
        guard id == .b else {
            showError(SwitcherError.message("Restart Current Account from ChatGPT itself; the switcher intentionally does not own its lifecycle."))
            return
        }
        if await quit(.b) { await open(.b) }
    }

    /// Recovery is automatic only when a pending launch has both a still-valid owned receipt and
    /// a currently installed isolation build matching the already-approved fingerprint. Otherwise
    /// all official ChatGPT processes must be manually closed before metadata can be cleared.
    func resolveInterruptedLaunches() async {
        guard !previewOnly, inFlight.isEmpty, shuttingDown.isEmpty, !busy else { return }
        busy = true
        defer { busy = false; refresh() }

        do {
            if uncertainty.contains(.b), verifiedSecondary() != nil {
                guard let approved = settings.approvedFingerprint else {
                    throw SwitcherError.message("Second Account ownership is verifiable, but no approved isolation fingerprint exists. Quit all official ChatGPT instances manually before clearing recovery state.")
                }
                let identity = try await resolveOfficialIdentity()
                let report = try await Task.detached(priority: .userInitiated) {
                    try Compatibility.inspect(identity.app)
                }.value
                guard report.fingerprint == approved else {
                    throw SwitcherError.message("Second Account ownership is verifiable, but the installed ChatGPT build no longer matches the approved isolation fingerprint. Do not trust this pending instance as isolated. Close all official ChatGPT instances manually, then retry recovery.")
                }
                cachedReport = report
                try store.save([ProfileID](), name: "pending.json")
                uncertainty.remove(.b)
                log("Recovered Second Account ownership after re-verifying the approved isolation fingerprint. No process was terminated.")
                return
            }

            guard officialApps.isEmpty else {
                throw SwitcherError.message("Recovery cannot safely identify an orphaned Second Account while any official ChatGPT process is running. Save your work, close all official ChatGPT windows yourself, then retry recovery.")
            }

            try store.save([ProfileID](), name: "pending.json")
            try store.save([LaunchReceipt](), name: "receipts.json")
            uncertainty.removeAll()
            receipts = []
            log("Cleared interrupted Second Account metadata after confirming no official ChatGPT process is running. Account data was preserved.")
        } catch { showError(error) }
    }

    /// Makes the next Second Account launch start fresh without permanently deleting the old data.
    /// The previous directory is atomically moved under Profiles/Archived and can be recovered manually.
    func resetSecondAccount() {
        guard canResetSecond else {
            showError(SwitcherError.message("Second Account can only be reset while every official ChatGPT instance is closed, Second Account is fully stopped, and no pending/owned process metadata remains."))
            return
        }
        do {
            let archived = try store.archiveSecondaryProfile()
            if let archived {
                log("Second Account storage was archived at \(archived.path). The next launch will create fresh isolated storage.")
            } else {
                log("Second Account had no private storage to reset.")
            }
            refresh()
        } catch { showError(error) }
    }

    // MARK: - Login item

    func refreshLogin() {
        switch SMAppService.mainApp.status {
        case .enabled: loginStatus = "Enabled"
        case .requiresApproval: loginStatus = "Needs approval in System Settings"
        case .notRegistered: loginStatus = "Disabled"
        case .notFound: loginStatus = "Unavailable — install the app bundle first"
        @unknown default: loginStatus = "Unknown macOS status"
        }
    }

    func toggleLogin() {
        guard !previewOnly else {
            showError(SwitcherError.message("UI preview cannot change login items."))
            return
        }
        do {
            guard Bundle.main.bundleURL.pathExtension == "app",
                  Bundle.main.bundleURL.deletingLastPathComponent().lastPathComponent == "Applications" else {
                throw SwitcherError.message("Move the switcher to an Applications folder before enabling startup at login.")
            }
            if SMAppService.mainApp.status == .enabled || SMAppService.mainApp.status == .requiresApproval {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            refreshLogin()
            log("Startup at login: " + loginStatus)
            if SMAppService.mainApp.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
        } catch {
            showError(error)
            refreshLogin()
        }
    }

    func disableLoginForUninstall() {
        guard !previewOnly else { return }
        do {
            if SMAppService.mainApp.status != .notRegistered { try SMAppService.mainApp.unregister() }
            refreshLogin()
        } catch { showError(error) }
    }

    // MARK: - Diagnostics

    var diagnosticText: String {
        let receiptPID = receipts.first?.stamp.pid.description ?? "none"
        let pending = uncertainty.contains(.b) ? "yes" : "no"
        let approved = settings.approvedFingerprint ?? "none"
        let cached = cachedReport?.fingerprint ?? "not checked this run"
        let version = (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "development"
        let build = (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? "dev"
        return """
        Pairbar \(version) (\(build))
        Settings schema: \(settings.schemaVersion)
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Official app path: \(settings.appPath)

        Current mode: normal/default ChatGPT; never owned; no profile overrides
        Current state: \(currentState.displayText)

        Second mode: isolated Electron + CODEX_HOME; destructive control only with verified ownership
        Second state: \(secondaryState.displayText)
        Second receipt PID: \(receiptPID)
        Second pending launch: \(pending)
        Second storage exists: \(store.secondaryProfileExists ? "yes" : "no")
        Legacy A storage retained: \(store.legacyCurrentProfileExists ? "yes" : "no")

        Approved isolation fingerprint: \(approved)
        Last checked fingerprint: \(cached)
        Startup at login: \(loginStatus)
        Private root: \(store.root.path)

        \(compatibilityText)

        No account identities, credentials, tokens, cookies, Keychain data, official app logs,
        process command-line arguments, or process environments are collected.

        \(logs.joined(separator: "\n"))
        """
    }
}
