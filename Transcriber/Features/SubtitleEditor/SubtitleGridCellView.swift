import AppKit

/// One grid cell: a single-line label centred vertically, or for a text
/// cell of a translated file, the original in small grey type above the
/// text. On a selected row (blue background) both turn white.
final class SubtitleGridCellView: NSTableCellView {
    enum Role {
        case number
        case time
        case text
    }

    private let label = NSTextField(labelWithString: "")
    /// The line before the language model changed it, above the text.
    private let originalLabel = NSTextField(labelWithString: "")
    private lazy var textStack: NSStackView = {
        let stack = NSStackView(views: [originalLabel, label])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        stack.detachesHiddenViews = true
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }()
    /// The CPS warning: a rounded red badge behind the number.
    private let badge = NSView()
    private var role = Role.text
    private var isPlaying = false
    private var isOverlapping = false
    private var isDoubtful = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        for field in [label, originalLabel] {
            field.lineBreakMode = .byTruncatingTail
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        originalLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        originalLabel.isHidden = true
        addSubview(badge)
        addSubview(textStack)
        textField = label
        NSLayoutConstraint.activate([
            textStack.centerYAnchor.constraint(equalTo: centerYAnchor),
            textStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            textStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            label.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            originalLabel.widthAnchor.constraint(equalTo: textStack.widthAnchor),
            badge.centerYAnchor.constraint(equalTo: centerYAnchor),
            badge.heightAnchor.constraint(equalToConstant: 18),
            badge.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -2),
            badge.widthAnchor.constraint(equalTo: label.widthAnchor, multiplier: 0.75, constant: 0),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SubtitleGridCellView is created in code")
    }

    func configure(
        text: String,
        role: Role,
        alignment: NSTextAlignment,
        isPlaying: Bool = false,
        isOverlapping: Bool = false,
        isDoubtful: Bool = false,
        readingSpeedWarning: Double = 0,
        original: String? = nil
    ) {
        self.role = role
        self.isDoubtful = isDoubtful
        self.isPlaying = isPlaying
        self.isOverlapping = isOverlapping
        label.stringValue = text
        label.alignment = alignment
        originalLabel.stringValue = original ?? ""
        originalLabel.isHidden = original == nil
        label.toolTip = role == .text ? text : nil
        originalLabel.toolTip = original
        label.font = role == .text
            ? .systemFont(ofSize: NSFont.systemFontSize)
            : .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: isPlaying ? .semibold : .regular)
        // Aegisub: from 15 CPS the cell turns red, fully at 30.
        badge.isHidden = readingSpeedWarning <= 0
        badge.layer?.backgroundColor = NSColor.systemRed.withAlphaComponent(0.2 + 0.6 * readingSpeedWarning).cgColor
        applyColors()
    }

    override var backgroundStyle: NSView.BackgroundStyle {
        didSet { applyColors() }
    }

    private func applyColors() {
        if backgroundStyle == .emphasized {
            label.textColor = .alternateSelectedControlTextColor  // white on the selection
            originalLabel.textColor = .alternateSelectedControlTextColor.withAlphaComponent(0.75)
            return
        }
        originalLabel.textColor = .secondaryLabelColor
        label.textColor = switch role {
        case _ where isOverlapping: .systemRed
        case .number where isPlaying: .controlAccentColor
        case .number where isDoubtful: .systemOrange
        case .text: .labelColor
        case .number, .time: .secondaryLabelColor
        }
    }
}
