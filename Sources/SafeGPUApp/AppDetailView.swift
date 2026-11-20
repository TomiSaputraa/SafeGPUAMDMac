import AppKit
import SafeGPUCore

@MainActor
protocol AppDetailViewDelegate: AnyObject {
    func detailView(_ view: AppDetailView, didSelectPreset preset: GPUPreset, for app: DiscoveredApp)
    func detailView(_ view: AppDetailView, didRequestSafeLaunch app: DiscoveredApp)
    func detailView(_ view: AppDetailView, didRequestApplyConfigPatch app: DiscoveredApp)
    func detailView(_ view: AppDetailView, didRequestRevertConfigPatch app: DiscoveredApp)
    func detailView(_ view: AppDetailView, didRequestCreateOrUpdateWrapper app: DiscoveredApp)
    func detailView(_ view: AppDetailView, didRequestDeleteWrapper app: DiscoveredApp)
    func detailView(_ view: AppDetailView, didRequestRevealURL url: URL)
    func detailView(_ view: AppDetailView, didRequestRemoveManualApp app: DiscoveredApp)
}

@MainActor
final class AppDetailView: NSView {
    weak var delegate: (any AppDetailViewDelegate)?

    private var currentState: ManagedAppState?
    private var wrapperDirectoryURL: URL = AppSettings.defaultWrapperDirectory()

    // Empty state
    private let emptyContainer = NSView()

    // Scrollable inspector
    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let mainStack = NSStackView()

    // Header
    private let appIconView = NSImageView()
    private let appNameLabel = UIFactory.label(size: 19, weight: .bold)
    private let engineBadge = PillBadgeView()
    private let runningBadge = PillBadgeView()
    private let bundleIDLabel = UIFactory.label(size: 11.5, color: .secondaryLabelColor, monospaced: true)
    private let appPathLabel = UIFactory.label(size: 11.5, color: .tertiaryLabelColor)
    private let revealAppButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let removeManualButton = NSButton(title: "Remove", target: nil, action: nil)

    // Preset card
    private var presetRadios: [GPUPreset: NSButton] = [:]
    private let launchSafeButton = NSButton(title: "Launch Safe Now", target: nil, action: nil)

    // Config Patch card
    private let configStatusBadge = PillBadgeView()
    private let configMethodLabel = UIFactory.label(size: 12, weight: .medium, color: .labelColor, wraps: true)
    private let configTargetLabel = UIFactory.label(size: 11.5, color: .secondaryLabelColor, monospaced: true, wraps: true)
    private let configUnsupportedLabel = UIFactory.label(
        "No known persistent GPU config file for this app. Use Wrapper .app or Launch Safe above.",
        size: 12,
        color: .secondaryLabelColor,
        wraps: true
    )
    private let runningWarningLabel = UIFactory.label(
        "App is currently running. Close it before patching so changes are not overwritten on exit.",
        size: 11.5,
        weight: .medium,
        color: .systemOrange,
        wraps: true
    )
    private let applyConfigButton = NSButton(title: "Apply Config Patch", target: nil, action: nil)
    private let revertConfigButton = NSButton(title: "Revert", target: nil, action: nil)
    private let configButtonsStack = NSStackView()

    // Wrapper card
    private let wrapperStatusBadge = PillBadgeView()
    private let wrapperNameLabel = UIFactory.label(size: 12, weight: .medium, color: .labelColor, wraps: true)
    private let wrapperPathLabel = UIFactory.label(size: 11.5, color: .secondaryLabelColor, monospaced: true, wraps: true)
    private let createWrapperButton = NSButton(title: "Create Wrapper .app", target: nil, action: nil)
    private let revealWrapperButton = NSButton(title: "Show in Finder", target: nil, action: nil)
    private let deleteWrapperButton = NSButton(title: "Delete Wrapper", target: nil, action: nil)

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        setupEmptyState()
        setupInspector()
        showEmptyState()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func update(state: ManagedAppState?, wrapperDirectoryURL: URL, wrapperName: String?) {
        self.currentState = state
        self.wrapperDirectoryURL = wrapperDirectoryURL

        guard let state else {
            showEmptyState()
            return
        }

        emptyContainer.isHidden = true
        scrollView.isHidden = false

        // Header
        appIconView.image = NSWorkspace.shared.icon(forFile: state.app.bundleURL.path)
        appNameLabel.stringValue = state.app.name
        engineBadge.configure(text: state.app.engine.displayName, style: .neutral)
        if state.isRunning {
            runningBadge.configure(text: "● Running", style: .green)
        } else {
            runningBadge.configure(text: "Not Running", style: .muted)
        }
        bundleIDLabel.stringValue = state.app.bundleIdentifier
        appPathLabel.stringValue = state.app.bundleURL.path
        removeManualButton.isHidden = !state.app.isManuallyAdded

        // Presets
        for (preset, radio) in presetRadios {
            radio.state = (preset == state.selectedPreset) ? .on : .off
        }

        // Config Patch
        switch state.configStatus {
        case .unsupported:
            configStatusBadge.configure(text: "Not Supported", style: .muted)
            configMethodLabel.isHidden = true
            configTargetLabel.isHidden = true
            runningWarningLabel.isHidden = true
            configUnsupportedLabel.isHidden = false
            configButtonsStack.isHidden = true

        case .notPatched(let kind):
            configStatusBadge.configure(text: "Not Patched", style: .neutral)
            configMethodLabel.isHidden = false
            configTargetLabel.isHidden = false
            configUnsupportedLabel.isHidden = true
            configButtonsStack.isHidden = false

            configMethodLabel.stringValue = "Method: \(kind.methodName)"
            configTargetLabel.stringValue = kind.targetDescription()
            runningWarningLabel.isHidden = !state.isRunning
            applyConfigButton.title = "Apply Config Patch"
            revertConfigButton.isHidden = true

        case .patched(let kind):
            configStatusBadge.configure(text: "Patched ✓", style: .green)
            configMethodLabel.isHidden = false
            configTargetLabel.isHidden = false
            configUnsupportedLabel.isHidden = true
            configButtonsStack.isHidden = false

            configMethodLabel.stringValue = "Method: \(kind.methodName)"
            configTargetLabel.stringValue = kind.targetDescription()
            runningWarningLabel.isHidden = !state.isRunning
            applyConfigButton.title = "Re-apply Patch"
            revertConfigButton.isHidden = false
        }

        // Wrapper .app
        let displayWrapperName = wrapperName ?? "\(state.app.name) (Safe).app"
        wrapperNameLabel.stringValue = "Shortcut: \(displayWrapperName)"

        switch state.wrapperStatus {
        case .notCreated:
            wrapperStatusBadge.configure(text: "Not Created", style: .neutral)
            wrapperPathLabel.stringValue = wrapperDirectoryURL.appendingPathComponent(displayWrapperName).path
            createWrapperButton.title = "Create Wrapper .app"
            revealWrapperButton.isEnabled = false
            deleteWrapperButton.isHidden = true

        case .ready(let url, let wrapperPreset):
            if state.isWrapperPresetOutdated {
                let currentLabel = wrapperPreset?.displayName ?? "Unknown"
                wrapperStatusBadge.configure(text: "Preset Changed (Was: \(currentLabel))", style: .orange)
                createWrapperButton.title = "Update Wrapper"
            } else {
                let presetName = wrapperPreset?.displayName ?? state.selectedPreset.displayName
                wrapperStatusBadge.configure(text: "Ready · \(presetName)", style: .blue)
                createWrapperButton.title = "Regenerate Wrapper"
            }
            wrapperPathLabel.stringValue = url.path
            revealWrapperButton.isEnabled = true
            deleteWrapperButton.isHidden = false
        }
    }

    private func showEmptyState() {
        emptyContainer.isHidden = false
        scrollView.isHidden = true
    }

    // MARK: - Setup UI

    private func setupEmptyState() {
        emptyContainer.translatesAutoresizingMaskIntoConstraints = false
        addSubview(emptyContainer)

        let icon = NSImageView()
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.image = UIFactory.symbolImage("checkmark.shield", size: 42, weight: .light)
        icon.contentTintColor = .tertiaryLabelColor

        let title = UIFactory.label("Select an Application", size: 16, weight: .semibold, color: .secondaryLabelColor)
        let subtitle = UIFactory.label(
            "Choose a detected Chromium/Electron app from the sidebar to apply a Config Patch, generate a Wrapper .app, or Launch Safe.\n\nYou can also drag & drop any .app bundle here.",
            size: 12.5,
            color: .tertiaryLabelColor,
            wraps: true
        )
        subtitle.alignment = .center

        let stack = NSStackView(views: [icon, title, subtitle])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 10
        emptyContainer.addSubview(stack)

        NSLayoutConstraint.activate([
            emptyContainer.topAnchor.constraint(equalTo: topAnchor),
            emptyContainer.bottomAnchor.constraint(equalTo: bottomAnchor),
            emptyContainer.leadingAnchor.constraint(equalTo: leadingAnchor),
            emptyContainer.trailingAnchor.constraint(equalTo: trailingAnchor),

            stack.centerXAnchor.constraint(equalTo: emptyContainer.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: emptyContainer.centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualToConstant: 360)
        ])
    }

    private func setupInspector() {
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        addSubview(scrollView)

        documentView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = documentView

        mainStack.translatesAutoresizingMaskIntoConstraints = false
        mainStack.orientation = .vertical
        mainStack.alignment = .leading
        mainStack.spacing = 14
        documentView.addSubview(mainStack)

        let headerView = buildHeaderSection()
        let presetCard = buildPresetCard()
        let configCard = buildConfigCard()
        let wrapperCard = buildWrapperCard()

        for section in [headerView, presetCard, configCard, wrapperCard] {
            mainStack.addArrangedSubview(section)
            section.widthAnchor.constraint(equalTo: mainStack.widthAnchor).isActive = true
        }

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),

            mainStack.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 18),
            mainStack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor, constant: 20),
            mainStack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor, constant: -20),
            mainStack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -20)
        ])
    }

    private func buildHeaderSection() -> NSView {
        let container = NSView()
        container.translatesAutoresizingMaskIntoConstraints = false

        appIconView.translatesAutoresizingMaskIntoConstraints = false
        appIconView.imageScaling = .scaleProportionallyUpOrDown

        let titleRow = NSStackView(views: [appNameLabel, engineBadge, runningBadge])
        titleRow.translatesAutoresizingMaskIntoConstraints = false
        titleRow.orientation = .horizontal
        titleRow.alignment = .centerY
        titleRow.spacing = 8

        revealAppButton.bezelStyle = .rounded
        revealAppButton.controlSize = .small
        revealAppButton.target = self
        revealAppButton.action = #selector(revealAppClicked)

        removeManualButton.bezelStyle = .rounded
        removeManualButton.controlSize = .small
        removeManualButton.contentTintColor = .systemRed
        removeManualButton.target = self
        removeManualButton.action = #selector(removeManualClicked)

        let pathRow = NSStackView(views: [appPathLabel, revealAppButton, removeManualButton])
        pathRow.translatesAutoresizingMaskIntoConstraints = false
        pathRow.orientation = .horizontal
        pathRow.alignment = .centerY
        pathRow.spacing = 8
        appPathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let infoStack = NSStackView(views: [titleRow, bundleIDLabel, pathRow])
        infoStack.translatesAutoresizingMaskIntoConstraints = false
        infoStack.orientation = .vertical
        infoStack.alignment = .leading
        infoStack.spacing = 4

        container.addSubview(appIconView)
        container.addSubview(infoStack)

        NSLayoutConstraint.activate([
            appIconView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            appIconView.topAnchor.constraint(equalTo: container.topAnchor, constant: 2),
            appIconView.widthAnchor.constraint(equalToConstant: 56),
            appIconView.heightAnchor.constraint(equalToConstant: 56),
            appIconView.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),

            infoStack.leadingAnchor.constraint(equalTo: appIconView.trailingAnchor, constant: 14),
            infoStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            infoStack.topAnchor.constraint(equalTo: container.topAnchor),
            infoStack.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        return container
    }

    private func buildPresetCard() -> NSView {
        let card = CardView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        card.addSubview(stack)

        let heading = UIFactory.label("GPU Launch Preset", size: 13.5, weight: .semibold)
        stack.addArrangedSubview(heading)

        for (index, preset) in GPUPreset.allCases.enumerated() {
            let radio = NSButton(
                radioButtonWithTitle: preset.displayName,
                target: self,
                action: #selector(presetRadioChanged(_:))
            )
            radio.tag = index
            radio.font = NSFont.systemFont(ofSize: 12.5, weight: .medium)
            presetRadios[preset] = radio

            let desc = UIFactory.label(preset.descriptionText, size: 11.5, color: .secondaryLabelColor, wraps: true)
            let flags = UIFactory.label(preset.flagsDisplay, size: 10.5, color: .tertiaryLabelColor, monospaced: true, wraps: true)

            let detailStack = NSStackView(views: [desc, flags])
            detailStack.orientation = .vertical
            detailStack.alignment = .leading
            detailStack.spacing = 2
            detailStack.edgeInsets = NSEdgeInsets(top: 0, left: 20, bottom: 2, right: 0)

            let optionStack = NSStackView(views: [radio, detailStack])
            optionStack.orientation = .vertical
            optionStack.alignment = .leading
            optionStack.spacing = 2
            stack.addArrangedSubview(optionStack)
            optionStack.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            detailStack.widthAnchor.constraint(equalTo: optionStack.widthAnchor).isActive = true
        }

        let sep = UIFactory.separator()
        stack.addArrangedSubview(sep)
        sep.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        launchSafeButton.bezelStyle = .rounded
        launchSafeButton.bezelColor = .controlAccentColor
        launchSafeButton.image = UIFactory.symbolImage("play.fill", size: 11, weight: .semibold)
        launchSafeButton.imagePosition = .imageLeading
        launchSafeButton.target = self
        launchSafeButton.action = #selector(launchSafeClicked)

        let launchHint = UIFactory.label(
            "Launches immediately with the selected preset flags.",
            size: 11.5,
            color: .secondaryLabelColor,
            wraps: true
        )

        let launchRow = NSStackView(views: [launchSafeButton, launchHint])
        launchRow.orientation = .horizontal
        launchRow.alignment = .centerY
        launchRow.spacing = 10
        stack.addArrangedSubview(launchRow)

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])

        return card
    }

    private func buildConfigCard() -> NSView {
        let card = CardView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        card.addSubview(stack)

        let heading = UIFactory.label("Config Patch (Native Setting)", size: 13.5, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: [heading, spacer, configStatusBadge])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        configTargetLabel.isSelectable = true

        let note = UIFactory.label(
            "Disables hardware acceleration in the app's own settings so it can open normally from Dock, Spotlight, and links.",
            size: 11.5,
            color: .secondaryLabelColor,
            wraps: true
        )

        applyConfigButton.bezelStyle = .rounded
        applyConfigButton.target = self
        applyConfigButton.action = #selector(applyConfigClicked)

        revertConfigButton.bezelStyle = .rounded
        revertConfigButton.target = self
        revertConfigButton.action = #selector(revertConfigClicked)

        configButtonsStack.orientation = .horizontal
        configButtonsStack.alignment = .centerY
        configButtonsStack.spacing = 8
        configButtonsStack.addArrangedSubview(applyConfigButton)
        configButtonsStack.addArrangedSubview(revertConfigButton)

        for v in [note, configMethodLabel, configTargetLabel, runningWarningLabel, configUnsupportedLabel, configButtonsStack] {
            stack.addArrangedSubview(v)
            if v !== configButtonsStack {
                v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])

        return card
    }

    private func buildWrapperCard() -> NSView {
        let card = CardView()
        let stack = NSStackView()
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        card.addSubview(stack)

        let heading = UIFactory.label("Wrapper .app (Safe Shortcut)", size: 13.5, weight: .semibold)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let headerRow = NSStackView(views: [heading, spacer, wrapperStatusBadge])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        stack.addArrangedSubview(headerRow)
        headerRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true

        let note = UIFactory.label(
            "Creates a badged launcher .app in your SafeLaunch folder (indexed by Spotlight and pinnable to Dock) using the GPU preset selected above.",
            size: 11.5,
            color: .secondaryLabelColor,
            wraps: true
        )

        wrapperPathLabel.isSelectable = true

        createWrapperButton.bezelStyle = .rounded
        createWrapperButton.target = self
        createWrapperButton.action = #selector(createWrapperClicked)

        revealWrapperButton.bezelStyle = .rounded
        revealWrapperButton.target = self
        revealWrapperButton.action = #selector(revealWrapperClicked)

        deleteWrapperButton.bezelStyle = .rounded
        deleteWrapperButton.contentTintColor = .systemRed
        deleteWrapperButton.target = self
        deleteWrapperButton.action = #selector(deleteWrapperClicked)

        let buttonsRow = NSStackView(views: [createWrapperButton, revealWrapperButton, deleteWrapperButton])
        buttonsRow.orientation = .horizontal
        buttonsRow.alignment = .centerY
        buttonsRow.spacing = 8

        for v in [note, wrapperNameLabel, wrapperPathLabel, buttonsRow] {
            stack.addArrangedSubview(v)
            if v !== buttonsRow {
                v.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            }
        }

        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 14),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -14),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 14),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -14)
        ])

        return card
    }

    // MARK: - Actions

    @objc private func presetRadioChanged(_ sender: NSButton) {
        guard let state = currentState else { return }
        let all = GPUPreset.allCases
        guard sender.tag >= 0 && sender.tag < all.count else { return }
        let chosen = all[sender.tag]
        for (preset, radio) in presetRadios {
            radio.state = (preset == chosen) ? .on : .off
        }
        delegate?.detailView(self, didSelectPreset: chosen, for: state.app)
    }

    @objc private func launchSafeClicked() {
        guard let state = currentState else { return }
        delegate?.detailView(self, didRequestSafeLaunch: state.app)
    }

    @objc private func applyConfigClicked() {
        guard let state = currentState else { return }
        delegate?.detailView(self, didRequestApplyConfigPatch: state.app)
    }

    @objc private func revertConfigClicked() {
        guard let state = currentState else { return }
        delegate?.detailView(self, didRequestRevertConfigPatch: state.app)
    }

    @objc private func createWrapperClicked() {
        guard let state = currentState else { return }
        delegate?.detailView(self, didRequestCreateOrUpdateWrapper: state.app)
    }

    @objc private func revealWrapperClicked() {
        guard let state = currentState, let url = state.wrapperStatus.url else { return }
        delegate?.detailView(self, didRequestRevealURL: url)
    }

    @objc private func deleteWrapperClicked() {
        guard let state = currentState else { return }
        delegate?.detailView(self, didRequestDeleteWrapper: state.app)
    }

    @objc private func revealAppClicked() {
        guard let state = currentState else { return }
        delegate?.detailView(self, didRequestRevealURL: state.app.bundleURL)
    }

    @objc private func removeManualClicked() {
        guard let state = currentState else { return }
        delegate?.detailView(self, didRequestRemoveManualApp: state.app)
    }
}
