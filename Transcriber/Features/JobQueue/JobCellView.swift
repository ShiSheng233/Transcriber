import AppKit

/// One queue row: file name, task, status text and progress.
final class JobCellView: NSTableCellView {
    static let identifier = NSUserInterfaceItemIdentifier("JobCell")

    private let nameLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let progressIndicator = NSProgressIndicator()

    override init(frame: NSRect) {
        super.init(frame: frame)
        identifier = Self.identifier

        nameLabel.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        nameLabel.lineBreakMode = .byTruncatingMiddle
        detailLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        progressIndicator.style = .bar
        progressIndicator.controlSize = .small
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1

        let stack = NSStackView(views: [nameLabel, detailLabel, progressIndicator])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 3
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 6),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("JobCellView is created in code")
    }

    func configure(with row: JobQueueViewModel.Row) {
        nameLabel.stringValue = row.fileName
        detailLabel.stringValue = "\(row.modelName) · \(row.statusText)"
        detailLabel.toolTip = row.statusText
        if let fraction = row.fractionCompleted, row.canCancel {
            progressIndicator.isHidden = false
            progressIndicator.doubleValue = fraction
        } else {
            progressIndicator.isHidden = true
        }
    }
}
