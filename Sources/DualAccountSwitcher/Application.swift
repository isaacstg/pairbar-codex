import AppKit
import CoreServices
import SwiftUI
import SwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let previewModel: PairbarPanelModel?
    private var controller: PairbarController?
    private var model: PairbarPanelModel?
    private var keys: HotKeys?
    private var item: NSStatusItem?
    private var refreshTimer: Timer?
    private var memorySource: DispatchSourceMemoryPressure?
    private let popover = NSPopover()

    init(previewModel: PairbarPanelModel? = nil) { self.previewModel = previewModel }

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        let launchedAtLogin = NSAppleEventManager.shared().currentAppleEvent?
            .attributeDescriptor(forKeyword: AEKeyword(keyAELaunchedAsLogInItem)) != nil
        do {
            let model: PairbarPanelModel
            if let previewModel {
                model = previewModel
            } else {
                let store = try DynamicStore(root: PrivateStore.defaultRoot)
                try store.acquireLock()
                try store.migrateIfNeeded()
                model = PairbarPanelModel()
                let controller = try PairbarController(store: store, runtime: NativeApplicationRuntime(),
                                                       inspector: InstalledProviderInspector(), model: model)
                self.controller = controller
                let keys = HotKeys(registerDefaults: false)
                keys.onTargetPress = { [weak controller] target in
                    guard let controller, let account = controller.accountTarget(target) else { return }
                    Task { _ = await controller.open(account) }
                }
                controller.replaceShortcuts = { [weak keys] bindings in keys?.replaceBindings(bindings) ?? false }
                let shortcutsReady = keys.replaceBindings(controller.shortcutBindings())
                if !shortcutsReady {
                    model.errorMessage = model.text(
                        "One or more global shortcuts are unavailable. Edit the affected shortcuts; account controls remain available here.",
                        "Uno o varios atajos globales no están disponibles. Edita los atajos afectados; los controles de cuentas siguen disponibles aquí."
                    )
                }
                self.keys = keys
                controller.onActivate = { [weak self] in self?.popover.performClose(nil) }
                controller.onPresent = { [weak self] in self?.showPopover() }
                startRuntimeUpdates(model: model, controller: controller)
                Task {
                    await controller.check(.codex, presentErrors: false)
                    if !shortcutsReady {
                        model.errorMessage = model.text(
                            "One or more global shortcuts are unavailable. Edit the affected shortcuts; account controls remain available here.",
                            "Uno o varios atajos globales no están disponibles. Edita los atajos afectados; los controles de cuentas siguen disponibles aquí."
                        )
                    }
                    await controller.launchAtLogin(isLoginEvent: launchedAtLogin)
                    // Claude managed profiles are compiled off. A lightweight
                    // identity check is enough to classify Current at startup;
                    // the bounded ASAR review runs only on explicit Check again.
                    await controller.identify(.claude)
                }
            }
            self.model = model
            configureStatusItem(model: model)
            popover.behavior = .transient
            popover.contentSize = NSSize(width: PairbarPanelModel.width, height: PairbarPanelModel.height)
            popover.contentViewController = NSHostingController(rootView: PairbarPanelView(
                model: model, dismiss: { [weak self] in self?.popover.performClose(nil) }
            ))
            if previewModel != nil || (!launchedAtLogin && !model.welcomeCompleted) { showPopover() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Pairbar could not start"
            alert.informativeText = "Pairbar preserved provider apps and profile data. Its private configuration needs attention."
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        refreshTimer?.invalidate()
        memorySource?.cancel()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover()
        return true
    }

    private func configureStatusItem(model: PairbarPanelModel) {
        item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        guard let button = item?.button else { return }
        button.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Pairbar")
        button.toolTip = "Pairbar"
        button.target = self
        button.action = #selector(togglePopover(_:))
        button.setAccessibilityLabel("Pairbar")
        button.setAccessibilityHelp(model.text("Open profiles, settings and help.", "Abrir perfiles, ajustes y ayuda."))
    }

    private func startRuntimeUpdates(model: PairbarPanelModel, controller: PairbarController) {
        // Selector scheduling avoids the strict-concurrency capture diagnostic emitted by
        // the Swift toolchain on the macOS 14 GitHub Actions runner.
        refreshTimer = Timer.scheduledTimer(timeInterval: 2, target: self,
            selector: #selector(refreshTimerFired(_:)), userInfo: nil, repeats: true)
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak model] in
            guard let model else { return }
            let event = source.data
            if event.contains(.critical) { model.memoryPressure = .critical }
            else if event.contains(.warning) { model.memoryPressure = .warning }
            else { model.memoryPressure = .normal }
        }
        memorySource = source
        source.resume()
    }

    @objc private func refreshTimerFired(_ timer: Timer) {
        controller?.refresh()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) } else { showPopover() }
    }

    private func showPopover() {
        guard let button = item?.button else { return }
        controller?.refresh()
        controller?.refreshLogin()
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown { popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY) }
        popover.contentViewController?.view.window?.makeKey()
    }

    private func configureMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let application = NSMenu(title: "Pairbar")
        application.addItem(withTitle: "Quit Pairbar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        appItem.submenu = application
        bar.addItem(appItem)
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        bar.addItem(editItem)
        NSApp.mainMenu = bar
    }
}

@main
struct SwitcherMain {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        if arguments.count == 3 && arguments[1] == "--check-app" {
            do { print(try Compatibility.inspect(URL(fileURLWithPath: arguments[2])).summary) }
            catch { fputs("Pairbar could not verify the selected ChatGPT app.\n", stderr); exit(1) }
            return
        }
        if arguments.count == 3 && arguments[1] == "--check-claude" {
            do { print(try ClaudeCompatibility.inspect(URL(fileURLWithPath: arguments[2])).summary) }
            catch { fputs("Pairbar could not verify the selected Claude app.\n", stderr); exit(1) }
            return
        }
        let preview: PairbarPanelModel?
        if arguments.count == 2 && arguments[1] == "--preview-ui" {
            preview = .preview()
        } else if arguments.count == 3 && arguments[1] == "--preview-ui" {
            preview = .preview(language: arguments[2] == "spanish" ? .spanish : .english)
        } else if arguments.count == 1 {
            preview = nil
        } else {
            fputs("Usage: DualAccountSwitcher [--check-app /path/to/ChatGPT.app | --check-claude /path/to/Claude.app | --preview-ui [english|spanish]]\n", stderr)
            exit(2)
        }
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        let delegate = AppDelegate(previewModel: preview)
        app.delegate = delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
