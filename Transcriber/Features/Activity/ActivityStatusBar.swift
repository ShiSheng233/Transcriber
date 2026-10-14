import AppKit
import TranscriberCore

/// The bottom of the sidebar: a spinner while working, the latest log line,
/// and a button that opens the full log.
final class ActivityStatusBar: NSView {
    private let viewModel: ActivityViewModel
    private let spinner = NSProgressIndicator()
    private let statusIcon = NSImageView()
    private let messageLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private var binder: ObservationBinder?

    init(viewModel: ActivityViewModel, showLog: @escaping () -> Void) {
        self.viewModel = viewModel
        super.init(frame: .zero)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        statusIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)

        messageLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        messageLabel.textColor = .secondaryLabelColor
        messageLabel.lineBreakMode = .byTruncatingTail
        messageLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        positionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        positionLabel.textColor = .tertiaryLabelColor

        let logButton = ClosureButton(
            image: NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: String(localized: "Activity")) ?? NSImage(),
            action: showLog
        )
        logButton.isBordered = false
        logButton.toolTip = String(localized: "Show Activity (⌥⌘L)")

        let stack = NSStackView(views: [spinner, statusIcon, messageLabel, positionLabel, logButton])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 0, left: 12, bottom: 0, right: 10)
        stack.setCustomSpacing(8, after: positionLabel)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(stack)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: separator.bottomAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(equalToConstant: 30),
        ])
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActivityStatusBar is created in code")
    }

    private func render() {
        let message = viewModel.statusText
        messageLabel.stringValue = message
        messageLabel.toolTip = message
        positionLabel.stringValue = viewModel.queuePositionText ?? ""
        positionLabel.isHidden = viewModel.queuePositionText == nil

        spinner.isHidden = !viewModel.isBusy  // a stopped spinner still takes space
        if viewModel.isBusy {
            spinner.startAnimation(nil)
            statusIcon.isHidden = true
        } else {
            spinner.stopAnimation(nil)
            let symbol: (name: String, color: NSColor)? = switch viewModel.latestLevel {
            case .error: ("xmark.octagon.fill", .systemRed)
            case .warning: ("exclamationmark.triangle.fill", .systemOrange)
            default: nil
            }
            statusIcon.isHidden = symbol == nil
            statusIcon.image = symbol.flatMap { NSImage(systemSymbolName: $0.name, accessibilityDescription: nil) }
            statusIcon.contentTintColor = symbol?.color
        }
    }
}

/// A button that runs a closure, for views without a target object.
final class ClosureButton: NSButton {
    private let handler: () -> Void

    init(image: NSImage, action: @escaping () -> Void) {
        handler = action
        super.init(frame: .zero)
        self.image = image
        imagePosition = .imageOnly
        bezelStyle = .accessoryBarAction
        target = self
        self.action = #selector(run(_:))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ClosureButton is created in code")
    }

    @objc private func run(_ sender: Any?) {
        handler()
    }
}
