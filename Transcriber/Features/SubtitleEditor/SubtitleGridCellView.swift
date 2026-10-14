import AppKit

/// One grid cell: a single-line label centred vertically. On a selected row
/// (blue background) its text turns white, whatever role colour it has.
final class SubtitleGridCellView: NSTableCellView {
    enum Role {
        case number
        case time
        case text
    }

    private let label = NSTextField(labelWithString: "")
    /// The CPS warning: a rounded red badge behind the number.
    private let badge = NSView()
    private var role = Role.text
    private var isPlaying = false
    private var isOverlapping = false

    init(identifier: NSUserInterfaceItemIdentifier) {
        super.init(frame: .zero)
        self.identifier = identifier
        badge.wantsLayer = true
        badge.layer?.cornerRadius = 4
        badge.isHidden = true
        badge.translatesAutoresizingMaskIntoConstraints = false
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        addSubview(badge)
        addSubview(label)
        textField = label
        NSLayoutConstraint.activate([
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
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
        readingSpeedWarning: Double = 0
    ) {
        self.role = role
        self.isPlaying = isPlaying
        self.isOverlapping = isOverlapping
        label.stringValue = text
        label.alignment = alignment
        label.toolTip = role == .text ? text : nil
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
            return
        }
        label.textColor = switch role {
        case _ where isOverlapping: .systemRed
        case .number where isPlaying: .controlAccentColor
        case .text: .labelColor
        case .number, .time: .secondaryLabelColor
        }
    }
}
