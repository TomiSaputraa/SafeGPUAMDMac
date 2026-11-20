import AppKit
import SafeGPUCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let controller: SafeGPUController
    private let pathLabel = UIFactory.label(size: 12, color: .labelColor, monospaced: true, wraps: true)

    init(controller: SafeGPUController) {
        self.controller = controller
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 500, height: 190),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        panel.title = "SafeGPU Settings"
        panel.isReleasedWhenClosed = false
        super.init(window: panel)
        setupUI()
        refresh()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func refresh() {
        pathLabel.stringValue = controller.settings.wrapperDirectoryURL.path
    }

    private func setupUI() {
        guard let contentView = window?.contentView else { return }

        let heading = UIFactory.label("Wrapper .app Output Folder", size: 13.5, weight: .semibold)
        let desc = UIFactory.label(
            "Generated \"<AppName> (Safe).app\" shortcuts are saved here. Keeping them under ~/Applications ensures Spotlight indexes them automatically.",
            size: 11.5,
            color: .secondaryLabelColor,
            wraps: true
        )

        let pathCard = CardView()
        pathLabel.isSelectable = true
        pathCard.addSubview(pathLabel)
        NSLayoutConstraint.activate([
            pathLabel.topAnchor.constraint(equalTo: pathCard.topAnchor, constant: 8),
            pathLabel.bottomAnchor.constraint(equalTo: pathCard.bottomAnchor, constant: -8),
            pathLabel.leadingAnchor.constraint(equalTo: pathCard.leadingAnchor, constant: 10),
            pathLabel.trailingAnchor.constraint(equalTo: pathCard.trailingAnchor, constant: -10)
        ])

        let chooseBtn = NSButton(title: "Choose Folder…", target: self, action: #selector(chooseFolder))
        chooseBtn.bezelStyle = .rounded

        let resetBtn = NSButton(title: "Reset Default", target: self, action: #selector(resetDefault))
        resetBtn.bezelStyle = .rounded

        let openBtn = NSButton(title: "Open in Finder", target: self, action: #selector(openInFinder))
        openBtn.bezelStyle = .rounded

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let doneBtn = NSButton(title: "Done", target: self, action: #selector(closeSheet))
        doneBtn.bezelStyle = .rounded
        doneBtn.keyEquivalent = "\r"

        let buttonRow = NSStackView(views: [chooseBtn, resetBtn, openBtn, spacer, doneBtn])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8

        let stack = NSStackView(views: [heading, desc, pathCard, buttonRow])
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10

        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -16),
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -20),

            desc.widthAnchor.constraint(equalTo: stack.widthAnchor),
            pathCard.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = controller.settings.wrapperDirectoryURL
        panel.prompt = "Select Folder"

        if panel.runModal() == .OK, let url = panel.url {
            do {
                try controller.updateWrapperDirectory(url)
                refresh()
            } catch {
                showErrorAlert(error)
            }
        }
    }

    @objc private func resetDefault() {
        do {
            try controller.resetWrapperDirectory()
            refresh()
        } catch {
            showErrorAlert(error)
        }
    }

    @objc private func openInFinder() {
        let dir = controller.settings.wrapperDirectoryURL
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(dir)
    }

    @objc private func closeSheet() {
        guard let window else { return }
        if let parent = window.sheetParent {
            parent.endSheet(window)
        } else {
            window.close()
        }
    }

    private func showErrorAlert(_ error: Error) {
        let alert = NSAlert(error: error)
        if let window {
            alert.beginSheetModal(for: window)
        } else {
            alert.runModal()
        }
    }
}
