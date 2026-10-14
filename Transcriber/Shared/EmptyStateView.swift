import AppKit

/// A centered symbol with a title and a hint, for empty lists and panes.
final class EmptyStateView: NSView {
    private let imageView = NSImageView()
    private let titleLabel = NSTextField(labelWithString: "")
    private let messageLabel = NSTextField(wrappingLabelWithString: "")

    init(symbolName: String, title: String, message: String) {
        super.init(frame: .zero)
        imageView.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 34, weight: .light))
        imageView.contentTintColor = .tertiaryLabelColor
        titleLabel.font = .systemFont(ofSize: 15, weight: .semibold)
        titleLabel.textColor = .secondaryLabelColor
        titleLabel.alignment = .center
        messageLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        messageLabel.textColor = .tertiaryLabelColor
        messageLabel.alignment = .center

        let stack = NSStackView(views: [imageView, titleLabel, messageLabel])
        stack.orientation = .vertical
        stack.spacing = 6
        stack.setCustomSpacing(12, after: imageView)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            stack.widthAnchor.constraint(lessThanOrEqualTo: widthAnchor, constant: -40),
            messageLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 280),
        ])
        update(title: title, message: message)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("EmptyStateView is created in code")
    }

    func update(title: String, message: String) {
        titleLabel.stringValue = title
        messageLabel.stringValue = message
        messageLabel.isHidden = message.isEmpty
    }
}
