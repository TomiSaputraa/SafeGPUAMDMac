import AppKit
import SafeGPUCore
import UniformTypeIdentifiers

@MainActor
private final class DropContainerView: NSView {
    var onAppURLsDropped: (([URL]) -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        registerForDraggedTypes([.fileURL])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        extractAppURLs(from: sender).isEmpty ? [] : .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = extractAppURLs(from: sender)
        guard !urls.isEmpty else { return false }
        onAppURLsDropped?(urls)
        return true
    }

    private func extractAppURLs(from info: any NSDraggingInfo) -> [URL] {
        guard let items = info.draggingPasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL] else {
            return []
        }
        return items.filter { $0.pathExtension.lowercased() == "app" }
    }
}

@MainActor
final class MainWindowController: NSWindowController {
    private enum FilterMode: Int {
        case all = 0
        case protected = 1
        case unprotected = 2
    }

    private enum ToolbarID {
        static let toolbar = NSToolbar.Identifier("SafeGPUMainToolbar")
        static let rescan = NSToolbarItem.Identifier("rescan")
        static let addApp = NSToolbarItem.Identifier("addApp")
        static let openWrappers = NSToolbarItem.Identifier("openWrappers")
        static let settings = NSToolbarItem.Identifier("settings")
    }

    private let controller: SafeGPUController
    private var settingsController: SettingsWindowController?

    private var filteredApps: [ManagedAppState] = []
    private var selectedAppID: String?
    private var filterMode: FilterMode = .all
    private var searchQuery: String = ""
    private var iconCache: [String: NSImage] = [:]

    // UI elements
    private let splitView = NSSplitView()
    private let searchField = NSSearchField()
    private let filterControl = NSSegmentedControl(
        labels: ["All", "Protected", "Unprotected"],
        trackingMode: .selectOne,
        target: nil,
        action: nil
    )
    private let tableView = NSTableView()
    private let sidebarCountLabel = UIFactory.label("", size: 11, color: .secondaryLabelColor)
    private let detailView = AppDetailView()
    private let statusFooterLabel = UIFactory.label("Ready", size: 11.5, color: .secondaryLabelColor)

    init(controller: SafeGPUController) {
        self.controller = controller
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SafeGPU"
        window.minSize = NSSize(width: 760, height: 500)
        window.center()
        window.setFrameAutosaveName("SafeGPUMainWindow")
        window.toolbarStyle = .unified
        super.init(window: window)

        setupToolbar()
        setupContent()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func reloadUI() {
        applyFilterAndReloadTable()
        updateDetailPane()
        updateSidebarSummary()
    }

    func openSettings() {
        guard let window else { return }
        if settingsController == nil {
            settingsController = SettingsWindowController(controller: controller)
        }
        settingsController?.refresh()
        if let sheetWindow = settingsController?.window {
            window.beginSheet(sheetWindow)
        }
    }

    func promptAddApp() {
        let panel = NSOpenPanel()
        panel.title = "Add Application"
        panel.message = "Select any .app bundle to manage GPU acceleration settings or create a Safe Wrapper."
        panel.allowedContentTypes = [.applicationBundle]
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications", isDirectory: true)

        if let window {
            panel.beginSheetModal(for: window) { [weak self] response in
                guard response == .OK else { return }
                Task { @MainActor in
                    self?.handleAddApps(panel.urls)
                }
            }
        } else if panel.runModal() == .OK {
            handleAddApps(panel.urls)
        }
    }

    func openSafeLaunchFolder() {
        let dir = controller.settings.wrapperDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    func performSafeLaunchFromMenu(for app: DiscoveredApp) {
        handleSafeLaunchRequest(for: app)
    }

    // MARK: - Setup

    private func setupToolbar() {
        let toolbar = NSToolbar(identifier: ToolbarID.toolbar)
        toolbar.delegate = self
        toolbar.displayMode = .iconAndLabel
        toolbar.allowsUserCustomization = false
        window?.toolbar = toolbar
    }

    private func setupContent() {
        guard let window else { return }

        let rootView = DropContainerView(frame: window.contentView?.bounds ?? .zero)
        rootView.autoresizingMask = [.width, .height]
        rootView.onAppURLsDropped = { [weak self] urls in
            self?.handleAddApps(urls)
        }
        window.contentView = rootView

        splitView.translatesAutoresizingMaskIntoConstraints = false
        splitView.isVertical = true
        splitView.dividerStyle = .thin
        splitView.delegate = self

        let sidebar = buildSidebar()
        let detailContainer = buildDetailContainer()

        splitView.addArrangedSubview(sidebar)
        splitView.addArrangedSubview(detailContainer)
        splitView.setHoldingPriority(.defaultHigh, forSubviewAt: 0)
        splitView.setHoldingPriority(.defaultLow, forSubviewAt: 1)

        rootView.addSubview(splitView)
        NSLayoutConstraint.activate([
            splitView.topAnchor.constraint(equalTo: rootView.topAnchor),
            splitView.bottomAnchor.constraint(equalTo: rootView.bottomAnchor),
            splitView.leadingAnchor.constraint(equalTo: rootView.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: rootView.trailingAnchor)
        ])

        splitView.setPosition(300, ofDividerAt: 0)
    }

    private func buildSidebar() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        searchField.translatesAutoresizingMaskIntoConstraints = false
        searchField.placeholderString = "Filter apps…"
        searchField.delegate = self

        filterControl.translatesAutoresizingMaskIntoConstraints = false
        filterControl.selectedSegment = 0
        filterControl.segmentStyle = .rounded
        filterControl.controlSize = .small
        filterControl.target = self
        filterControl.action = #selector(filterChanged(_:))

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("AppColumn"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 56
        tableView.style = .sourceList
        tableView.usesAlternatingRowBackgroundColors = false
        tableView.delegate = self
        tableView.dataSource = self

        let tableScroll = NSScrollView()
        tableScroll.translatesAutoresizingMaskIntoConstraints = false
        tableScroll.documentView = tableView
        tableScroll.hasVerticalScroller = true
        tableScroll.borderType = .noBorder
        tableScroll.drawsBackground = true

        let topSep = UIFactory.separator()
        let bottomSep = UIFactory.separator()

        let footer = NSView()
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.addSubview(sidebarCountLabel)

        container.addSubview(searchField)
        container.addSubview(filterControl)
        container.addSubview(topSep)
        container.addSubview(tableScroll)
        container.addSubview(bottomSep)
        container.addSubview(footer)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 250),

            searchField.topAnchor.constraint(equalTo: container.topAnchor, constant: 10),
            searchField.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            searchField.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            filterControl.topAnchor.constraint(equalTo: searchField.bottomAnchor, constant: 8),
            filterControl.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 10),
            filterControl.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -10),

            topSep.topAnchor.constraint(equalTo: filterControl.bottomAnchor, constant: 8),
            topSep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            topSep.trailingAnchor.constraint(equalTo: container.trailingAnchor),

            tableScroll.topAnchor.constraint(equalTo: topSep.bottomAnchor),
            tableScroll.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            tableScroll.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            tableScroll.bottomAnchor.constraint(equalTo: bottomSep.topAnchor),

            bottomSep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            bottomSep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            bottomSep.bottomAnchor.constraint(equalTo: footer.topAnchor),

            footer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footer.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footer.heightAnchor.constraint(equalToConstant: 28),

            sidebarCountLabel.leadingAnchor.constraint(equalTo: footer.leadingAnchor, constant: 12),
            sidebarCountLabel.trailingAnchor.constraint(equalTo: footer.trailingAnchor, constant: -12),
            sidebarCountLabel.centerYAnchor.constraint(equalTo: footer.centerYAnchor)
        ])

        return container
    }

    private func buildDetailContainer() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        detailView.delegate = self

        let footerSep = UIFactory.separator()
        let footerBar = NSView()
        footerBar.translatesAutoresizingMaskIntoConstraints = false
        footerBar.addSubview(statusFooterLabel)

        container.addSubview(detailView)
        container.addSubview(footerSep)
        container.addSubview(footerBar)

        NSLayoutConstraint.activate([
            container.widthAnchor.constraint(greaterThanOrEqualToConstant: 460),

            detailView.topAnchor.constraint(equalTo: container.topAnchor),
            detailView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            detailView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            detailView.bottomAnchor.constraint(equalTo: footerSep.topAnchor),

            footerSep.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerSep.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerSep.bottomAnchor.constraint(equalTo: footerBar.topAnchor),

            footerBar.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerBar.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerBar.bottomAnchor.constraint(equalTo: container.bottomAnchor),
            footerBar.heightAnchor.constraint(equalToConstant: 28),

            statusFooterLabel.leadingAnchor.constraint(equalTo: footerBar.leadingAnchor, constant: 14),
            statusFooterLabel.trailingAnchor.constraint(equalTo: footerBar.trailingAnchor, constant: -14),
            statusFooterLabel.centerYAnchor.constraint(equalTo: footerBar.centerYAnchor)
        ])

        return container
    }

    // MARK: - Data & Filtering

    private func applyFilterAndReloadTable() {
        let query = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()

        filteredApps = controller.apps.filter { state in
            switch filterMode {
            case .all:
                break
            case .protected:
                guard state.isProtected else { return false }
            case .unprotected:
                guard !state.isProtected else { return false }
            }

            if !query.isEmpty {
                let matchesName = state.app.name.lowercased().contains(query)
                let matchesBundle = state.app.bundleIdentifier.lowercased().contains(query)
                let matchesEngine = state.app.engine.displayName.lowercased().contains(query)
                if !matchesName && !matchesBundle && !matchesEngine {
                    return false
                }
            }
            return true
        }

        tableView.reloadData()

        if let currentID = selectedAppID,
           let idx = filteredApps.firstIndex(where: { $0.id == currentID }) {
            tableView.selectRowIndexes(IndexSet(integer: idx), byExtendingSelection: false)
        } else if !filteredApps.isEmpty {
            selectedAppID = filteredApps[0].id
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        } else {
            selectedAppID = nil
        }
    }

    private func updateDetailPane() {
        let selectedState = filteredApps.first(where: { $0.id == selectedAppID })
            ?? controller.apps.first(where: { $0.id == selectedAppID })
        let wrapperName = selectedState.map { controller.wrapperGenerator.wrapperName(for: $0.app) }
        detailView.update(
            state: selectedState,
            wrapperDirectoryURL: controller.settings.wrapperDirectoryURL,
            wrapperName: wrapperName
        )
    }

    private func updateSidebarSummary() {
        let total = controller.apps.count
        let protectedCount = controller.apps.filter(\.isProtected).count
        let noun = total == 1 ? "app" : "apps"
        sidebarCountLabel.stringValue = "\(total) \(noun) · \(protectedCount) protected"
    }

    private func cachedIcon(for app: DiscoveredApp) -> NSImage {
        if let existing = iconCache[app.id] {
            return existing
        }
        let icon = NSWorkspace.shared.icon(forFile: app.bundleURL.path)
        iconCache[app.id] = icon
        return icon
    }

    private func setStatus(_ message: String, isError: Bool = false) {
        statusFooterLabel.stringValue = message
        statusFooterLabel.textColor = isError ? .systemRed : .secondaryLabelColor
    }

    // MARK: - Actions

    @objc private func rescanClicked() {
        iconCache.removeAll()
        controller.rescan()
        setStatus("Rescanned applications — \(controller.apps.count) found.")
    }

    @objc private func addAppClicked() {
        promptAddApp()
    }

    @objc private func openWrappersClicked() {
        openSafeLaunchFolder()
    }

    @objc private func settingsClicked() {
        openSettings()
    }

    @objc private func filterChanged(_ sender: NSSegmentedControl) {
        filterMode = FilterMode(rawValue: sender.selectedSegment) ?? .all
        applyFilterAndReloadTable()
        updateDetailPane()
    }

    private func handleAddApps(_ urls: [URL]) {
        var addedLast: DiscoveredApp?
        var addedCount = 0
        for url in urls {
            do {
                if let app = try controller.addManualApp(at: url) {
                    addedLast = app
                    addedCount += 1
                }
            } catch {
                showErrorAlert(error)
            }
        }

        if let last = addedLast {
            filterMode = .all
            filterControl.selectedSegment = 0
            searchQuery = ""
            searchField.stringValue = ""
            selectedAppID = last.id
            reloadUI()
            setStatus("Added \(addedCount == 1 ? last.name : "\(addedCount) apps") to list.")
        } else {
            setStatus("Selected bundle could not be added (already managed or invalid .app).", isError: true)
        }
    }

    private func handleSafeLaunchRequest(for app: DiscoveredApp) {
        if controller.launcher.isRunning(app) {
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = "\(app.name) is already running"
            alert.informativeText = "macOS ignores new GPU launch flags when an app is already open. Would you like to quit \(app.name) and relaunch it with SafeGPU's selected preset?"
            alert.addButton(withTitle: "Quit & Relaunch Safe")
            alert.addButton(withTitle: "Bring to Front")
            alert.addButton(withTitle: "Cancel")

            let runModalHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    Task { @MainActor in
                        self.setStatus("Closing \(app.name)…")
                        let closed = await self.controller.terminate(app)
                        if !closed {
                            self.setStatus("\(app.name) did not quit in time. Please close it manually and try again.", isError: true)
                            return
                        }
                        self.performDirectSafeLaunch(for: app)
                    }
                case .alertSecondButtonReturn:
                    self.performDirectSafeLaunch(for: app)
                default:
                    break
                }
            }

            if let window {
                alert.beginSheetModal(for: window, completionHandler: runModalHandler)
            } else {
                runModalHandler(alert.runModal())
            }
            return
        }

        performDirectSafeLaunch(for: app)
    }

    private func performDirectSafeLaunch(for app: DiscoveredApp) {
        do {
            try controller.launchSafe(app)
            let preset = controller.settings.presetByAppPath[app.id] ?? .standard
            setStatus("Launched \(app.name) with \(preset.displayName) preset.")
        } catch {
            showErrorAlert(error)
        }
    }

    private func showErrorAlert(_ error: Error) {
        setStatus(error.localizedDescription, isError: true)
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}

// MARK: - NSToolbarDelegate

extension MainWindowController: NSToolbarDelegate {
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            ToolbarID.rescan,
            ToolbarID.addApp,
            .flexibleSpace,
            ToolbarID.openWrappers,
            ToolbarID.settings
        ]
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        toolbarAllowedItemIdentifiers(toolbar)
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: itemIdentifier)
        item.target = self

        switch itemIdentifier {
        case ToolbarID.rescan:
            item.label = "Rescan"
            item.toolTip = "Rescan /Applications and ~/Applications"
            item.image = UIFactory.symbolImage("arrow.clockwise", size: 14)
            item.action = #selector(rescanClicked)
        case ToolbarID.addApp:
            item.label = "Add App"
            item.toolTip = "Manually add any .app bundle"
            item.image = UIFactory.symbolImage("plus", size: 14)
            item.action = #selector(addAppClicked)
        case ToolbarID.openWrappers:
            item.label = "SafeLaunch"
            item.toolTip = "Open the Wrapper .app folder in Finder"
            item.image = UIFactory.symbolImage("folder", size: 14)
            item.action = #selector(openWrappersClicked)
        case ToolbarID.settings:
            item.label = "Settings"
            item.toolTip = "Configure Wrapper output folder"
            item.image = UIFactory.symbolImage("gearshape", size: 14)
            item.action = #selector(settingsClicked)
        default:
            return nil
        }

        return item
    }
}

// MARK: - NSSplitViewDelegate

extension MainWindowController: NSSplitViewDelegate {
    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        250
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
        380
    }
}

// MARK: - NSSearchFieldDelegate

extension MainWindowController: NSSearchFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchQuery = searchField.stringValue
        applyFilterAndReloadTable()
        updateDetailPane()
    }
}

// MARK: - NSTableViewDataSource & NSTableViewDelegate

extension MainWindowController: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        filteredApps.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        guard row >= 0 && row < filteredApps.count else { return nil }
        let state = filteredApps[row]
        let cell = (tableView.makeView(withIdentifier: AppListCellView.identifier, owner: self) as? AppListCellView)
            ?? AppListCellView()
        cell.identifier = AppListCellView.identifier
        cell.configure(with: state, icon: cachedIcon(for: state.app))
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = tableView.selectedRow
        if row >= 0 && row < filteredApps.count {
            selectedAppID = filteredApps[row].id
        } else {
            selectedAppID = nil
        }
        updateDetailPane()
    }
}

// MARK: - AppDetailViewDelegate

extension MainWindowController: AppDetailViewDelegate {
    func detailView(_ view: AppDetailView, didSelectPreset preset: GPUPreset, for app: DiscoveredApp) {
        do {
            try controller.setPreset(preset, for: app)
            setStatus("Preset for \(app.name) set to \(preset.displayName).")
        } catch {
            showErrorAlert(error)
        }
    }

    func detailView(_ view: AppDetailView, didRequestSafeLaunch app: DiscoveredApp) {
        handleSafeLaunchRequest(for: app)
    }

    func detailView(_ view: AppDetailView, didRequestApplyConfigPatch app: DiscoveredApp) {
        if controller.launcher.isRunning(app) {
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = "\(app.name) is currently running"
            alert.informativeText = "Some apps overwrite their config files when they quit. Quit \(app.name) before patching so hardware acceleration stays disabled?"
            alert.addButton(withTitle: "Quit & Patch")
            alert.addButton(withTitle: "Patch Anyway")
            alert.addButton(withTitle: "Cancel")

            let handleResponse: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }
                switch response {
                case .alertFirstButtonReturn:
                    Task { @MainActor in
                        self.setStatus("Closing \(app.name)…")
                        let closed = await self.controller.terminate(app)
                        if !closed {
                            self.setStatus("\(app.name) did not close in time. Please quit it manually first.", isError: true)
                            return
                        }
                        self.applyConfigPatchNow(for: app)
                    }
                case .alertSecondButtonReturn:
                    self.applyConfigPatchNow(for: app)
                default:
                    break
                }
            }

            if let window {
                alert.beginSheetModal(for: window, completionHandler: handleResponse)
            } else {
                handleResponse(alert.runModal())
            }
            return
        }

        applyConfigPatchNow(for: app)
    }

    private func applyConfigPatchNow(for app: DiscoveredApp) {
        do {
            try controller.applyConfigPatch(for: app)
            setStatus("✓ Config patch applied for \(app.name).")
        } catch {
            showErrorAlert(error)
        }
    }

    func detailView(_ view: AppDetailView, didRequestRevertConfigPatch app: DiscoveredApp) {
        do {
            try controller.revertConfigPatch(for: app)
            setStatus("Reverted config patch for \(app.name).")
        } catch {
            showErrorAlert(error)
        }
    }

    func detailView(_ view: AppDetailView, didRequestCreateOrUpdateWrapper app: DiscoveredApp) {
        do {
            let url = try controller.createOrUpdateWrapper(for: app)
            setStatus("✓ Created \(url.lastPathComponent) in \(url.deletingLastPathComponent().path).")
        } catch {
            showErrorAlert(error)
        }
    }

    func detailView(_ view: AppDetailView, didRequestDeleteWrapper app: DiscoveredApp) {
        do {
            try controller.deleteWrapper(for: app)
            setStatus("Deleted Wrapper .app for \(app.name).")
        } catch {
            showErrorAlert(error)
        }
    }

    func detailView(_ view: AppDetailView, didRequestRevealURL url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    func detailView(_ view: AppDetailView, didRequestRemoveManualApp app: DiscoveredApp) {
        do {
            try controller.removeManualApp(app)
            setStatus("Removed \(app.name) from manual list.")
        } catch {
            showErrorAlert(error)
        }
    }
}
