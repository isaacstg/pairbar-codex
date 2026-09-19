import AppKit
import SwiftUI
import SwitcherCore

enum PopoverPage {
    case welcome, accounts, settings, help
    static let width: CGFloat = 380
    @MainActor func height(for controller: Controller) -> CGFloat {
        guard self == .accounts else { return 540 }
        if !controller.settings.setupComplete || controller.isolationReadiness.requiresConfirmation ||
            controller.secondaryState.needsRecovery || controller.currentState.isAmbiguous ||
            controller.errorMessage != nil { return 500 }
        if case .unavailable = controller.isolationReadiness { return 500 }
        if controller.settings.nameA.count > 20 || controller.settings.nameB.count > 20 { return 400 }
        return 360
    }
    var title: String {
        switch self {
        case .welcome: return "Welcome to Pairbar"
        case .accounts: return "Pairbar"
        case .settings: return "Settings"
        case .help: return "Help"
        }
    }
}

@MainActor
final class PopoverNavigation: ObservableObject {
    static let welcomePreferenceKey = "pairbarWelcomeCompleted"
    @Published var needsWelcome = true
    @Published var page: PopoverPage = .accounts {
        didSet { onPageChange?(page) }
    }
    var onPageChange: ((PopoverPage) -> Void)?
}

private enum SecondAction: String, Identifiable {
    case quit, restart, recover, reset
    var id: String { rawValue }
    var title: String {
        switch self {
        case .quit: return "Quit Second Account?"
        case .restart: return "Restart Second Account?"
        case .recover: return "Recover Second Account?"
        case .reset: return "Reset Second Account?"
        }
    }
    var button: String {
        switch self {
        case .quit: return "Quit Second Account"
        case .restart: return "Restart Second Account"
        case .recover: return "Try Safe Recovery"
        case .reset: return "Archive & Reset"
        }
    }
    var explanation: String {
        switch self {
        case .quit, .restart:
            return "Save your work in Second Account first. Your current account stays open."
        case .recover:
            return "We will verify the recorded Second process and the confirmed ChatGPT version. If verification is not possible, save your work and close every ChatGPT instance yourself before retrying. Recovery preserves saved account data."
        case .reset:
            return "The previous Second Account data will be archived, so it can be recovered. Next time you open Second Account you will need to sign in again. Both ChatGPT instances must be closed first."
        }
    }
}

struct SwitcherPopoverView: View {
    @ObservedObject var controller: Controller
    @ObservedObject var navigation: PopoverNavigation
    let dismiss: () -> Void
    @State private var confirmation: SecondAction?

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                if navigation.page != .accounts && navigation.page != .welcome {
                    Button { navigation.page = .accounts } label: {
                        Image(systemName: "chevron.left")
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Back to accounts")
                    .help("Back to accounts · Shift-Command-B")
                }
                Text(navigation.page.title).font(.headline)
                Spacer()
                Button(action: dismiss) { Image(systemName: "xmark") }
                    .buttonStyle(.plain)
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Close popover")
                    .help("Close · Escape")
            }
            .padding(16)
            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if let error = controller.errorMessage {
                        messageBanner(error)
                    }
                    switch navigation.page {
                    case .welcome:
                        welcome
                    case .accounts:
                        accounts
                    case .settings:
                        PopoverSettingsView(controller: controller)
                    case .help:
                        PopoverHelpView(controller: controller, quickStart: { navigation.page = .welcome }, confirm: { confirmation = $0 })
                    }
                }
                .padding(16)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            Divider()
            HStack {
                if navigation.page == .welcome {
                    Text("Open this guide again in Help.")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    welcomeContinueButton
                } else {
                    Button {
                        controller.refreshLogin()
                        navigation.page = .settings
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                    .buttonStyle(.plain)
                    .disabled(navigation.page == .settings)
                    Spacer()
                    Button { navigation.page = .help } label: {
                        Label("Help", systemImage: "questionmark.circle")
                    }
                    .buttonStyle(.plain)
                    .disabled(navigation.page == .help)
                }
            }
            .font(.callout)
            .padding(16)
        }
        .frame(width: PopoverPage.width, height: navigation.page.height(for: controller))
        .confirmationDialog(confirmation?.title ?? "", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), titleVisibility: .visible, presenting: confirmation) { action in
            Button(action.button) {
                confirmation = nil
                switch action {
                case .quit: Task { _ = await controller.quit(.b) }
                case .restart: Task { await controller.restart(.b) }
                case .recover: Task { await controller.resolveInterruptedLaunches() }
                case .reset: controller.resetSecondAccount()
                }
            }
            Button("Cancel", role: .cancel) { confirmation = nil }
        } message: { action in
            Text(action.explanation)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "person.2.fill")
                .font(.system(size: 32)).foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 8) {
                Text("Two accounts. One click apart.").font(.title3.bold())
                Text("Pairbar lives in your Mac's menu bar. Click its two-person icon to open this panel; it doesn't add a Dock window.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            welcomeStep("1", title: "Keep your current login", detail: "Current Account opens your normal ChatGPT. You don't need to sign in again if you're already signed in.")
            welcomeStep("2", title: "Add your other account", detail: controller.settings.setupComplete
                        ? "Open Second Account. Sign into your other account there if needed; its saved login is kept between launches."
                        : "Choose Set Up Second Account, then sign into your other account in its separate ChatGPT window.")
            welcomeStep("3", title: "Switch without closing either", detail: "Use ⌥⌘1 for Current and ⌥⌘2 for Second, or choose Open Both. Change the account names in Settings.")
            if controller.settings.setupComplete {
                Label("Your saved setup is preserved. Any required app checks appear next.", systemImage: "checkmark.circle")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var welcomeContinueButton: some View {
        Button(controller.settings.setupComplete ? "Go to Accounts" : "Get Started") {
            // This preference records only completion of our introduction. It never
            // grants isolation approval, changes login items, or touches account data.
            if !controller.previewOnly {
                UserDefaults.standard.set(true, forKey: PopoverNavigation.welcomePreferenceKey)
            }
            navigation.needsWelcome = false
            navigation.page = .accounts
        }
        .buttonStyle(.borderedProminent)
        .keyboardShortcut(.defaultAction)
    }

    private func welcomeStep(_ number: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text(number).font(.caption.bold())
                .frame(width: 24, height: 24)
                .background(Color.accentColor.opacity(0.12), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.bold())
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var accounts: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !controller.settings.setupComplete {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Two accounts. One click apart.").font(.title3.bold())
                    Text("Keep your current login. Open a separate ChatGPT window and sign into your other account there.")
                        .font(.callout).foregroundStyle(.secondary)
                }
            }

            accountCard(.a)
            accountCard(.b)

            if controller.secondaryState.needsRecovery && !controller.secondaryIsOpening {
                actionNotice("Second Account needs attention.",
                             detail: "Use safe recovery before opening either account from the switcher.",
                             button: "Get help") { navigation.page = .help }
            } else if case .ambiguous = controller.currentState {
                actionNotice("More than one normal ChatGPT is open.",
                             detail: "Close the extra normal instance so the switcher can find your current account.",
                             button: "Get help") { navigation.page = .help }
            }

            if !controller.secondaryState.needsRecovery {
                switch controller.isolationReadiness {
                case .notChecked, .checking:
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Checking your ChatGPT app…").font(.callout).foregroundStyle(.secondary)
                    }
                case .confirmationRequired(_, let isUpdate):
                    VStack(alignment: .leading, spacing: 10) {
                        Text(isUpdate
                             ? "ChatGPT was updated. The app check passed; confirm this version before opening Second Account again."
                             : "The app check passed. Set up Second Account to open its own sign-in window.")
                            .font(.callout).foregroundStyle(.secondary)
                        Button(isUpdate ? "Confirm ChatGPT Update" : "Set Up Second Account") {
                            Task {
                                if await controller.authorizeInstalledBuild() && !controller.previewOnly {
                                    await controller.open(.b)
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .disabled(controller.busy || !controller.secondaryState.allowsBuildConfirmation)
                    }
                case .unavailable:
                    actionNotice("Second Account is unavailable.",
                                 detail: "The app check did not pass. Settings explains what to do next.",
                                 button: "Open settings") { navigation.page = .settings }
                case .ready:
                    EmptyView()
                }
            }

            if controller.settings.setupComplete {
                Button {
                    Task { await controller.openBoth() }
                } label: {
                    HStack {
                        Image(systemName: "rectangle.on.rectangle")
                        Text("Open Both")
                        Spacer()
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(controller.previewOnly || !controller.capabilities.canOpenBoth || !secondReadyToOpen)
            }

            Text(controller.previewOnly
                 ? "Preview · account and startup actions are disabled."
                 : "Switching keeps the other account running.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private func accountCard(_ id: ProfileID) -> some View {
        let isCurrent = id == .a
        let running: Bool
        let needsAttention: Bool
        let status: String
        if isCurrent {
            switch controller.currentState {
            case .stopped: (running, needsAttention, status) = (false, false, "Closed")
            case .running: (running, needsAttention, status) = (true, false, "Running")
            case .launching: (running, needsAttention, status) = (false, false, "Opening…")
            case .ambiguous:
                (running, needsAttention, status) = (false, true, "Needs attention")
            case .blockedBySecondaryRecovery:
                (running, needsAttention, status) = (false, !controller.secondaryIsOpening,
                    controller.secondaryIsOpening ? "Waiting for Second" : "Needs attention")
            }
        } else {
            switch controller.secondaryState {
            case .stopped: (running, needsAttention, status) = (false, false, controller.settings.setupComplete ? "Closed" : "Not set up")
            case .runningVerified: (running, needsAttention, status) = (true, false, "Running")
            case .launching: (running, needsAttention, status) = (false, false, "Opening…")
            case .quitting: (running, needsAttention, status) = (false, false, "Closing…")
            case .ownershipUncertain:
                (running, needsAttention, status) = (false, !controller.secondaryIsOpening,
                    controller.secondaryIsOpening ? "Opening…" : "Needs attention")
            case .unverifiedLiveProcess:
                (running, needsAttention, status) = (false, true, "Needs attention")
            }
        }
        let canOpen = isCurrent ? controller.capabilities.canOpenCurrent :
            controller.capabilities.canOpenSecond && secondReadyToOpen
        return HStack(spacing: 12) {
            Image(systemName: isCurrent ? "person.crop.circle" : "person.crop.circle.badge.plus")
                .font(.system(size: 25))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text(controller.settings.name(id)).font(.headline).lineLimit(2)
                    .help(controller.settings.name(id))
                Label(status, systemImage: needsAttention ? "exclamationmark.circle" : (running ? "checkmark.circle.fill" : "circle"))
                    .font(.caption)
                    .foregroundStyle(needsAttention ? Color.orange : (running ? Color.green : Color.secondary))
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 5) {
                Button { Task { await controller.open(id) } } label: {
                    Text(running ? "Switch" : "Open").frame(minWidth: 52)
                }
                    .disabled(controller.previewOnly || !canOpen)
                    .accessibilityLabel("\(running ? "Switch to" : "Open") \(controller.settings.name(id))")
                    .help(isCurrent ? "Option-Command-1" : "Option-Command-2")
                HStack(spacing: 6) {
                    if !isCurrent && controller.secondaryState.hasVerifiedRunningProcess {
                        Menu {
                            Button("Restart Second Account…") { confirmation = .restart }
                                .disabled(controller.previewOnly || !controller.capabilities.canRestartSecond)
                            Button("Quit Second Account…") { confirmation = .quit }
                                .disabled(controller.previewOnly || !controller.capabilities.canQuitSecond)
                        } label: {
                            Image(systemName: "ellipsis")
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .frame(width: 18)
                        .accessibilityLabel("More actions for Second Account")
                        .help("Restart or quit Second Account")
                    }
                    Text(isCurrent ? "⌥⌘1" : "⌥⌘2")
                        .font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        .accessibilityLabel(isCurrent ? "Option Command 1" : "Option Command 2")
                }
                .frame(height: 16)
            }
            // Lifecycle controls share the shortcut row, so verified ownership cannot
            // insert a column or move the primary action as Second starts/stops.
            .frame(width: 78, alignment: .trailing)
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
    }

    private func messageBanner(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Action needs attention", systemImage: "exclamationmark.circle").font(.callout.bold())
                Spacer()
                Button { controller.clearError() } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss message")
            }
            Text(message).font(.callout)
        }
        .padding(12)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private var secondReadyToOpen: Bool {
        if controller.secondaryState.hasVerifiedRunningProcess { return true }
        if case .ready = controller.isolationReadiness { return true }
        return false
    }

    private func actionNotice(_ title: String, detail: String, button: String,
                              action: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.callout.bold())
            Text(detail).font(.caption).foregroundStyle(.secondary)
            Button(button, action: action)
        }
    }
}

struct PopoverSettingsView: View {
    @ObservedObject var controller: Controller
    @State private var currentName: String
    @State private var secondName: String
    @State private var saved = false
    @State private var showAppDetails = false

    init(controller: Controller) {
        self.controller = controller
        _currentName = State(initialValue: controller.settings.nameA)
        _secondName = State(initialValue: controller.settings.nameB)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Account names").font(.headline)
                Text("Choose names you recognize, such as Personal and Work.")
                    .font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Current · ⌥⌘1").font(.caption).foregroundStyle(.secondary)
                    TextField("Current account", text: $currentName)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Current account name")
                }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Second · ⌥⌘2").font(.caption).foregroundStyle(.secondary)
                    TextField("Second account", text: $secondName)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Second account name")
                }
                HStack {
                    if saved { Label("Names saved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary) }
                    Spacer()
                    Button("Save Names") {
                        saved = controller.saveAccountLabels(current: currentName, second: secondName)
                        if saved {
                            currentName = controller.settings.nameA
                            secondName = controller.settings.nameB
                        }
                    }
                    .disabled(!controller.canEditSettings || !namesChanged)
                }
            }
            .onChange(of: currentName) { _ in saved = false }
            .onChange(of: secondName) { _ in saved = false }

            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Toggle("Start switcher at login", isOn: Binding(
                    get: { controller.loginStatus == "Enabled" || controller.loginStatus == "Needs approval in System Settings" },
                    set: { _ in controller.toggleLogin() }
                ))
                .disabled(controller.previewOnly)
                Text("Starts this menu-bar utility. Your ChatGPT windows open when you choose.")
                    .font(.caption).foregroundStyle(.secondary)
                if controller.loginStatus != "Enabled" && controller.loginStatus != "Disabled" {
                    Text(controller.loginStatus).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 10) {
                Text("ChatGPT app").font(.headline)
                readiness
                DisclosureGroup("App details", isExpanded: $showAppDetails) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text(controller.settings.appPath)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        HStack {
                            Button("Choose app…") { controller.chooseApp() }
                            Button("Check again") { Task { _ = await controller.checkCompatibility() } }
                        }
                        .disabled(controller.busy)
                    }.padding(.top, 8)
                }
                .font(.callout)
            }
        }
    }

    private var namesChanged: Bool {
        currentName != controller.settings.nameA || secondName != controller.settings.nameB
    }

    @ViewBuilder private var readiness: some View {
        switch controller.isolationReadiness {
        case .notChecked, .checking:
            HStack {
                ProgressView().controlSize(.small)
                Text("Checking your ChatGPT app…").font(.callout)
            }
        case .ready(let version):
            Label("App check passed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            Text("ChatGPT \(version)").font(.caption).foregroundStyle(.secondary)
        case .confirmationRequired(let version, let isUpdate):
            Label(isUpdate ? "ChatGPT update detected" : "Ready to set up Second Account",
                  systemImage: isUpdate ? "arrow.triangle.2.circlepath" : "checkmark.circle")
                .font(.callout)
            Text(isUpdate
                 ? "This version passed the setup checks. Confirm it to continue opening Second Account."
                 : "Your app passed the setup checks. Set up Second Account, then sign into your other account in its window.")
                .font(.caption).foregroundStyle(.secondary)
            Text("ChatGPT \(version)").font(.caption).foregroundStyle(.secondary)
            Button(isUpdate ? "Confirm ChatGPT Update" : "Set Up Second Account") {
                Task {
                    if await controller.authorizeInstalledBuild() && !controller.previewOnly {
                        await controller.open(.b)
                    }
                }
            }
            .disabled(controller.busy || !controller.secondaryState.allowsBuildConfirmation)
        case .unavailable(let reason):
            Label("Second Account cannot open yet", systemImage: "exclamationmark.circle").foregroundStyle(.orange)
            Text(reason).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Your normal ChatGPT account stays available unless Second needs recovery.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Check again") { Task { _ = await controller.checkCompatibility() } }
                .disabled(controller.busy)
        }
    }
}

private struct PopoverHelpView: View {
    @ObservedObject var controller: Controller
    let quickStart: () -> Void
    let confirm: (SecondAction) -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Button("Quick Start", action: quickStart)
            VStack(alignment: .leading, spacing: 8) {
                Text("Everyday shortcuts").font(.headline)
                shortcut("⌥⌘1", name: controller.settings.nameA)
                shortcut("⌥⌘2", name: controller.settings.nameB)
                Text("Switching keeps both accounts running. Click outside this popover or press Escape to close it.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if controller.secondaryState.needsRecovery && !controller.secondaryIsOpening {
                Divider()
                VStack(alignment: .leading, spacing: 8) {
                    Label("Second Account needs recovery", systemImage: "exclamationmark.circle").font(.headline)
                    Text("Try Safe Recovery first. If the switcher cannot verify Second, save your work and manually close both ChatGPT instances, then retry. Your saved account data is preserved.")
                        .font(.callout).foregroundStyle(.secondary)
                    Button("Try Safe Recovery…") { confirm(.recover) }
                        .disabled(controller.busy || controller.previewOnly)
                }
            }
            if case .ambiguous = controller.currentState {
                Text("More than one normal ChatGPT instance is open. Close the extra instance manually; the switcher will then recognize your current account.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Divider()
            DisclosureGroup("Troubleshooting details") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Only switcher state is included. Account identities and sign-in data are never collected.")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        Button(copied ? "Copied" : "Copy Diagnostics") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(controller.diagnosticText, forType: .string)
                            copied = true
                        }
                        Button("Clear Log") { controller.clearLog(); copied = false }
                    }
                    Text(controller.diagnosticText)
                        .font(.system(size: 10, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }.padding(.top, 8)
            }

            DisclosureGroup("Second Account data") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Your second login is saved separately. Reset archives its data instead of deleting it, then opens a fresh sign-in next time.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Show saved data in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting([controller.store.root])
                    }
                    Button("Archive & Reset Second Account…") { confirm(.reset) }
                        .disabled(!controller.canResetSecond)
                    if !controller.canResetSecond {
                        Text("Reset requires both ChatGPT instances to be closed and no pending recovery.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.top, 8)
            }

            DisclosureGroup("Remove the switcher") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("1. Save your work and quit Second Account from its More menu.\n2. Disable startup at login.\n3. Quit the switcher below.\n4. Move Pairbar.app to Trash.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("Your normal ChatGPT account and saved Second Account data remain intact.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Disable startup at login") { controller.disableLoginForUninstall() }
                        .disabled(controller.previewOnly || controller.loginStatus == "Disabled")
                }.padding(.top, 8)
            }

            Divider()
            Text("Pairbar \(version) · Local-only")
                .font(.caption).foregroundStyle(.secondary)
            Text("Independent utility. Not affiliated with OpenAI.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Quit Switcher") { NSApp.terminate(nil) }
                .help("Your ChatGPT accounts keep running.")
        }
    }

    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
    }

    private func shortcut(_ key: String, name: String) -> some View {
        HStack {
            Text(key).font(.system(.callout, design: .monospaced)).frame(width: 60, alignment: .leading)
            Text(name).font(.callout).lineLimit(2)
        }
    }
}
