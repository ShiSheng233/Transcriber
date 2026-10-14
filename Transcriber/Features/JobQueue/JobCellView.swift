import AppKit

/// One queue row: the file's icon and name, a short status, and a progress
/// ring while it runs. The full status is in the tooltip.
final class JobCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("JobCell")

    private let iconView = NSImageView()
    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressRing = NSProgressIndicator()
    private let stateIcon = NSImageView()
    private var displayedSource: URL?

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        iconView.imageScaling = .scaleProportionallyUpOrDown
        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        for label in [nameLabel, detailLabel] {
            label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        }
        progressRing.style = .spinning
        progressRing.controlSize = .small
        progressRing.isIndeterminate = false
        progressRing.minValue = 0
        progressRing.maxValue = 1
        stateIcon.symbolConfiguration = .init(pointSize: 13, weight: .regular)

        let labels = NSStackView(views: [nameLabel, detailLabel])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        let row = NSStackView(views: [iconView, labels, progressRing, stateIcon])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.spacing = 8
        row.translatesAutoresizingMaskIntoConstraints = false
        addSubview(row)
        NSLayoutConstraint.activate([
            row.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            row.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            row.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 28),
            iconView.heightAnchor.constraint(equalToConstant: 28),
            progressRing.widthAnchor.constraint(equalToConstant: 16),
            progressRing.heightAnchor.constraint(equalToConstant: 16),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("JobCellView is created in code")
    }

    func configure(with row: JobQueueViewModel.Row) {
        if displayedSource != row.sourceURL {
            displayedSource = row.sourceURL
            iconView.image = NSWorkspace.shared.icon(forFile: row.sourceURL.path)
        }
        nameLabel.stringValue = row.fileName
        nameLabel.toolTip = row.sourceURL.path
        detailLabel.stringValue = row.shortStatus
        detailLabel.toolTip = row.statusText

        if let fraction = row.fractionCompleted, row.canCancel {
            progressRing.isHidden = false
            progressRing.doubleValue = fraction
        } else {
            progressRing.isHidden = true
        }
        let symbol: (name: String, color: NSColor)? = switch row.outcome {
        case .warning: ("exclamationmark.triangle.fill", .systemOrange)
        case .failed: ("xmark.circle.fill", .systemRed)
        case .none, .done: nil
        }
        stateIcon.isHidden = symbol == nil
        stateIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0.name, accessibilityDescription: row.statusText) }
        stateIcon.contentTintColor = symbol?.color
    }
}
