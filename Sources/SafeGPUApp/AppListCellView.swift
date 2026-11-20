import AppKit
import SafeGPUCore

@MainActor
final class AppListCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("AppListCellView")

    private let iconView = NSImageView()
    private let titleLabel = UIFactory.label(size: 13, weight: .semibold)
    private let engineBadge = PillBadgeView()
    private let configBadge = PillBadgeView()
    private let wrapperBadge = PillBadgeView()
    private let badgeStack = NSStackView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        setupUI()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    private func setupUI() {
        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.imageScaling = .scaleProportionallyUpOrDown

        badgeStack.translatesAutoresizingMaskIntoConstraints = false
        badgeStack.orientation = .horizontal
        badgeStack.alignment = .centerY
        badgeStack.spacing = 5
        badgeStack.addArrangedSubview(engineBadge)
        badgeStack.addArrangedSubview(configBadge)
        badgeStack.addArrangedSubview(wrapperBadge)

        let textStack = NSStackView(views: [titleLabel, badgeStack])
        textStack.translatesAutoresizingMaskIntoConstraints = false
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 4

        addSubview(iconView)
        addSubview(textStack)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 34),
            iconView.heightAnchor.constraint(equalToConstant: 34),

            textStack.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 10),
            textStack.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -10),
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor)
        ])
    }

    func configure(with state: ManagedAppState, icon: NSImage) {
        iconView.image = icon
        titleLabel.stringValue = state.app.name

        engineBadge.configure(text: state.app.engine.shortLabel, style: .neutral)

        if state.configStatus.isPatched {
            configBadge.isHidden = false
            configBadge.configure(text: "Config ✓", style: .green)
        } else {
            configBadge.isHidden = true
        }

        if state.wrapperStatus.exists {
            wrapperBadge.isHidden = false
            if state.isWrapperPresetOutdated {
                wrapperBadge.configure(text: "Wrapper !", style: .orange)
            } else {
                wrapperBadge.configure(text: "Wrapper ✓", style: .blue)
            }
        } else {
            wrapperBadge.isHidden = true
        }
    }
}
