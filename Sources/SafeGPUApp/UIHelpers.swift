import AppKit

@MainActor
final class FlippedView: NSView {
    override var isFlipped: Bool { true }
}

@MainActor
final class CardView: NSView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            layer?.cornerRadius = 10
            layer?.borderWidth = 1
            layer?.borderColor = NSColor.separatorColor.cgColor
        }
    }
}

@MainActor
final class PillBadgeView: NSView {
    enum Style {
        case neutral
        case green
        case blue
        case orange
        case muted

        var backgroundColor: NSColor {
            switch self {
            case .neutral: return NSColor.quaternaryLabelColor.withAlphaComponent(0.18)
            case .green: return NSColor.systemGreen.withAlphaComponent(0.18)
            case .blue: return NSColor.systemBlue.withAlphaComponent(0.16)
            case .orange: return NSColor.systemOrange.withAlphaComponent(0.20)
            case .muted: return NSColor.quaternaryLabelColor.withAlphaComponent(0.12)
            }
        }

        var textColor: NSColor {
            switch self {
            case .neutral: return NSColor.secondaryLabelColor
            case .green: return NSColor.systemGreen
            case .blue: return NSColor.systemBlue
            case .orange: return NSColor.systemOrange
            case .muted: return NSColor.tertiaryLabelColor
            }
        }
    }

    private let label = NSTextField(labelWithString: "")
    private var style: Style = .neutral

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true

        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        label.setContentHuggingPriority(.required, for: .horizontal)
        addSubview(label)

        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -7),
            label.topAnchor.constraint(equalTo: topAnchor, constant: 2.5),
            label.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2.5)
        ])

        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(text: String, style: Style) {
        self.label.stringValue = text
        self.style = style
        updateAppearance()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateAppearance()
    }

    private func updateAppearance() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = style.backgroundColor.cgColor
            layer?.cornerRadius = 5
            label.textColor = style.textColor
        }
    }
}

@MainActor
enum UIFactory {
    static func label(
        _ text: String = "",
        size: CGFloat = 13,
        weight: NSFont.Weight = .regular,
        color: NSColor = .labelColor,
        monospaced: Bool = false,
        wraps: Bool = false
    ) -> NSTextField {
        let field = wraps ? NSTextField(wrappingLabelWithString: text) : NSTextField(labelWithString: text)
        field.translatesAutoresizingMaskIntoConstraints = false
        field.font = monospaced
            ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        field.textColor = color
        if !wraps {
            field.lineBreakMode = .byTruncatingTail
        }
        return field
    }

    static func separator() -> NSBox {
        let sep = NSBox()
        sep.translatesAutoresizingMaskIntoConstraints = false
        sep.boxType = .separator
        return sep
    }

    static func symbolImage(_ name: String, size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage? {
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: weight)
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
    }
}
