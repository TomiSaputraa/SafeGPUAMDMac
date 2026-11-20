import AppKit
import SafeGPUCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = SafeGPUController()
    private var mainWindowController: MainWindowController?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        setupMainMenu()

        let windowController = MainWindowController(controller: controller)
        self.mainWindowController = windowController

        controller.onStateChanged = { [weak self] in
            self?.mainWindowController?.reloadUI()
            self?.rebuildStatusBarMenu()
        }

        setupStatusItem()
        controller.rescan()

        windowController.showWindow(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let statusItem {
            NSStatusBar.system.removeStatusItem(statusItem)
            self.statusItem = nil
        }
    }

    // MARK: - Status Bar (Active Only While App Is Running)

    private func setupStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            let image = UIFactory.symbolImage("checkmark.shield", size: 15, weight: .medium)
            image?.isTemplate = true
            button.image = image
            button.toolTip = "SafeGPU"
        }
        self.statusItem = item
        rebuildStatusBarMenu()
    }

    private func rebuildStatusBarMenu() {
        guard let statusItem else { return }
        let menu = NSMenu()

        let showItem = NSMenuItem(title: "Show SafeGPU Window", action: #selector(showMainWindow), keyEquivalent: "")
        showItem.target = self
        menu.addItem(showItem)
        menu.addItem(.separator())

        let header = NSMenuItem(title: "Quick Safe Launch", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)

        if controller.apps.isEmpty {
            let emptyItem = NSMenuItem(title: "No apps detected", action: nil, keyEquivalent: "")
            emptyItem.isEnabled = false
            menu.addItem(emptyItem)
        } else {
            for state in controller.apps {
                let title = "\(state.app.name)  [\(state.selectedPreset.displayName)]"
                let appItem = NSMenuItem(title: title, action: #selector(quickLaunchMenuItemClicked(_:)), keyEquivalent: "")
                appItem.target = self
                appItem.representedObject = state.app.id

                let icon = NSWorkspace.shared.icon(forFile: state.app.bundleURL.path)
                icon.size = NSSize(width: 16, height: 16)
                appItem.image = icon
                menu.addItem(appItem)
            }
        }

        menu.addItem(.separator())

        let rescanItem = NSMenuItem(title: "Rescan Applications", action: #selector(rescanFromMenu), keyEquivalent: "")
        rescanItem.target = self
        menu.addItem(rescanItem)

        let openFolderItem = NSMenuItem(title: "Open SafeLaunch Folder", action: #selector(openWrappersFromMenu), keyEquivalent: "")
        openFolderItem.target = self
        menu.addItem(openFolderItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit SafeGPU", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    // MARK: - Main Menu

    private func setupMainMenu() {
        let mainMenu = NSMenu()

        // App Menu
        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu(title: "SafeGPU")
        appMenu.addItem(withTitle: "About SafeGPU", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())

        let settingsItem = NSMenuItem(title: "Settings…", action: #selector(openSettingsFromMenu), keyEquivalent: ",")
        settingsItem.target = self
        appMenu.addItem(settingsItem)
        appMenu.addItem(.separator())

        appMenu.addItem(withTitle: "Hide SafeGPU", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit SafeGPU", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // File Menu
        let fileMenuItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")

        let rescanItem = NSMenuItem(title: "Rescan Applications", action: #selector(rescanFromMenu), keyEquivalent: "r")
        rescanItem.target = self
        fileMenu.addItem(rescanItem)

        let addAppItem = NSMenuItem(title: "Add Application…", action: #selector(addAppFromMenu), keyEquivalent: "o")
        addAppItem.target = self
        fileMenu.addItem(addAppItem)

        fileMenu.addItem(.separator())
        let openFolderItem = NSMenuItem(title: "Open SafeLaunch Folder", action: #selector(openWrappersFromMenu), keyEquivalent: "l")
        openFolderItem.keyEquivalentModifierMask = [.command, .shift]
        openFolderItem.target = self
        fileMenu.addItem(openFolderItem)

        fileMenu.addItem(.separator())
        fileMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileMenuItem.submenu = fileMenu
        mainMenu.addItem(fileMenuItem)

        // Edit Menu (enables Copy/Paste/Cut/Select All in SearchField & selectable labels)
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        // Window Menu
        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)

        NSApp.mainMenu = mainMenu
        NSApp.windowsMenu = windowMenu
    }

    // MARK: - Menu Actions

    @objc private func showMainWindow() {
        mainWindowController?.showWindow(nil)
        mainWindowController?.window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func rescanFromMenu() {
        controller.rescan()
    }

    @objc private func addAppFromMenu() {
        showMainWindow()
        mainWindowController?.promptAddApp()
    }

    @objc private func openSettingsFromMenu() {
        showMainWindow()
        mainWindowController?.openSettings()
    }

    @objc private func openWrappersFromMenu() {
        mainWindowController?.openSafeLaunchFolder()
    }

    @objc private func quickLaunchMenuItemClicked(_ sender: NSMenuItem) {
        guard let appID = sender.representedObject as? String,
              let state = controller.apps.first(where: { $0.id == appID })
        else { return }
        mainWindowController?.performSafeLaunchFromMenu(for: state.app)
    }
}
