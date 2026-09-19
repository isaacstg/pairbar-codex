import AppKit
import SwiftUI
import SwitcherCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var controller: Controller?
    private var keys: HotKeys?
    private var item: NSStatusItem?
    private let popover = NSPopover()
    private let navigation = PopoverNavigation()

    func applicationDidFinishLaunching(_ notification: Notification) {
        configureMainMenu()
        do {
            let preview = CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--preview-ui"
            let store = try PrivateStore(root: preview ? URL(fileURLWithPath: CommandLine.arguments[2]) : PrivateStore.defaultRoot)
            try store.acquireLock()
            let controller = try Controller(store: store, previewOnly: preview)
            self.controller = controller
            navigation.needsWelcome = preview || !UserDefaults.standard.bool(forKey: PopoverNavigation.welcomePreferenceKey)
            navigation.page = navigation.needsWelcome ? .welcome : .accounts

            item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
            if let button = item?.button {
                button.image = NSImage(systemSymbolName: "person.2.fill", accessibilityDescription: "Pairbar")
                button.toolTip = "Pairbar"
                button.target = self
                button.action = #selector(togglePopover(_:))
                button.setAccessibilityLabel("Pairbar")
                button.setAccessibilityHelp("Open account switching, settings, and help.")
            }

            popover.behavior = .transient
            popover.contentSize = NSSize(width: PopoverPage.width, height: navigation.page.height(for: controller))
            popover.contentViewController = NSHostingController(rootView: SwitcherPopoverView(
                controller: controller,
                navigation: navigation,
                dismiss: { [weak self] in self?.popover.performClose(nil) }
            ))
            navigation.onPageChange = { [weak self, weak controller] page in
                guard let controller else { return }
                self?.resizePopover(page: page, controller: controller)
            }

            controller.onChange = { [weak self, weak controller] in
                guard let controller else { return }
                self?.item?.button?.toolTip = controller.currentState.isAmbiguous || controller.secondaryState.needsRecovery
                    ? "Pairbar · An account needs attention"
                    : "Switch between \(controller.settings.nameA) and \(controller.settings.nameB)"
                if let self { self.resizePopover(page: self.navigation.page, controller: controller) }
            }
            controller.onRequestPresentation = { [weak self] in self?.showPopover() }
            controller.onAccountActivated = { [weak self] in self?.popover.performClose(nil) }

            if !preview { keys = HotKeys() }
            keys?.onPress = { [weak controller] number in
                guard let controller else { return }
                Task { await controller.open(number == 1 ? .a : .b) }
            }
            for error in keys?.errors ?? [] { controller.log(error) }
            if preview || navigation.needsWelcome || !controller.settings.setupComplete { showPopover(returnToAccounts: true) }
        } catch {
            // Startup failures have no controller/popover yet. Keep a native error fallback.
            let alert = NSAlert()
            alert.messageText = "Switcher could not start"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            NSApp.terminate(nil)
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showPopover(returnToAccounts: !popover.isShown)
        return true
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown { popover.performClose(sender) }
        else { showPopover(returnToAccounts: true) }
    }

    private func showPopover(returnToAccounts: Bool = false) {
        guard let button = item?.button, let controller else { return }
        if returnToAccounts { navigation.page = navigation.needsWelcome ? .welcome : .accounts }
        controller.refresh()
        controller.refreshLogin()
        NSApp.activate(ignoringOtherApps: true)
        if !popover.isShown {
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        }
        popover.contentViewController?.view.window?.makeKey()
        if controller.isolationReadiness == .notChecked && !controller.busy {
            Task { _ = await controller.checkCompatibility() }
        }
    }

    private func configureMainMenu() {
        let bar = NSMenu()
        let appItem = NSMenuItem()
        let application = NSMenu(title: "Pairbar")
        application.addItem(withTitle: "Quit Switcher", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q").target = NSApp
        appItem.submenu = application
        bar.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            edit.addItem(withTitle: title, action: Selector(action), keyEquivalent: key)
        }
        editItem.submenu = edit
        bar.addItem(editItem)
        let navigationItem = NSMenuItem()
        let navigate = NSMenu(title: "Navigate")
        let back = navigate.addItem(withTitle: "Back to Accounts", action: #selector(showAccounts(_:)), keyEquivalent: "b")
        back.target = self
        back.keyEquivalentModifierMask = [.shift, .command]
        navigationItem.submenu = navigate
        bar.addItem(navigationItem)
        NSApp.mainMenu = bar
    }

    @objc private func showAccounts(_ sender: Any?) {
        showPopover(returnToAccounts: true)
    }

    private func resizePopover(page: PopoverPage, controller: Controller) {
        let size = NSSize(width: PopoverPage.width, height: page.height(for: controller))
        if popover.contentSize != size { popover.contentSize = size }
    }
}

@main
struct SwitcherMain {
    @MainActor static func main() {
        if CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--check-app" {
            do { print(try Compatibility.inspect(URL(fileURLWithPath: CommandLine.arguments[2])).summary) }
            catch { fputs(error.localizedDescription + "\n", stderr); exit(1) }
        } else if CommandLine.arguments.count > 1 && !(CommandLine.arguments.count == 3 && CommandLine.arguments[1] == "--preview-ui" && CommandLine.arguments[2].hasPrefix("/")) {
            fputs("Usage: DualAccountSwitcher [--check-app /path/to/ChatGPT.app | --preview-ui /absolute/scratch/path]\n", stderr)
            exit(2)
        } else {
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            let delegate = AppDelegate()
            app.delegate = delegate
            withExtendedLifetime(delegate) { app.run() }
        }
    }
}
