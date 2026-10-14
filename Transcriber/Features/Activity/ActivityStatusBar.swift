import AppKit
import TranscriberCore

/// The bottom of the sidebar. While working: the step and file on the first
/// line, a progress bar with "153/309 · about 4 min left" on the second.
/// When idle: the last outcome. The button opens the full log.
final class ActivityStatusBar: NSView {
    private let viewModel: ActivityViewModel
    private let statusIcon = NSImageView()
    private let stepLabel = NSTextField(labelWithString: "")
    private let positionLabel = NSTextField(labelWithString: "")
    private let progressBar = NSProgressIndicator()
    private let progressLabel = NSTextField(labelWithString: "")
    private let progressRow: NSStackView
    private var binder: ObservationBinder?

    init(viewModel: ActivityViewModel, showLog: @escaping () -> Void) {
        self.viewModel = viewModel

        progressBar.style = .bar
        progressBar.controlSize = .small
        progressBar.minValue = 0
        progressBar.maxValue = 1
        progressBar.setContentHuggingPriority(.defaultLow, for: .horizontal)
        progressLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        progressLabel.textColor = .secondaryLabelColor
        progressLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        progressRow = NSStackView(views: [progressBar, progressLabel])
        progressRow.spacing = 8
        super.init(frame: .zero)

        statusIcon.symbolConfiguration = .init(pointSize: 11, weight: .regular)
        stepLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize, weight: .medium)
        stepLabel.lineBreakMode = .byTruncatingMiddle
        stepLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        positionLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        positionLabel.textColor = .tertiaryLabelColor

        let logButton = ClosureButton(
            image: NSImage(systemSymbolName: "list.bullet.rectangle", accessibilityDescription: String(localized: "Activity")) ?? NSImage(),
            action: showLog
        )
        logButton.isBordered = false
        logButton.toolTip = String(localized: "Show Activity (⌥⌘L)")

        let firstLine = NSStackView(views: [statusIcon, stepLabel, positionLabel])
        firstLine.spacing = 5
        let lines = NSStackView(views: [firstLine, progressRow])
        lines.orientation = .vertical
        lines.alignment = .leading
        lines.spacing = 4
        progressRow.widthAnchor.constraint(equalTo: lines.widthAnchor).isActive = true
        firstLine.widthAnchor.constraint(lessThanOrEqualTo: lines.widthAnchor).isActive = true

        let content = NSStackView(views: [lines, logButton])
        content.alignment = .centerY
        content.spacing = 8
        content.edgeInsets = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 10)
        content.translatesAutoresizingMaskIntoConstraints = false

        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false

        addSubview(separator)
        addSubview(content)
        NSLayoutConstraint.activate([
            separator.topAnchor.constraint(equalTo: topAnchor),
            separator.leadingAnchor.constraint(equalTo: leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: trailingAnchor),
            content.topAnchor.constraint(equalTo: separator.bottomAnchor),
            content.bottomAnchor.constraint(equalTo: bottomAnchor),
            content.leadingAnchor.constraint(equalTo: leadingAnchor),
            content.trailingAnchor.constraint(equalTo: trailingAnchor),
            heightAnchor.constraint(greaterThanOrEqualToConstant: 32),
        ])
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("ActivityStatusBar is created in code")
    }

    private func render() {
        if viewModel.isBusy {
            let step = viewModel.stepText ?? ""
            let file = viewModel.runningFileName.map { " · \($0)" } ?? ""
            stepLabel.stringValue = step + file
            stepLabel.textColor = .labelColor
            stepLabel.toolTip = step + file
            positionLabel.stringValue = viewModel.queuePositionText ?? ""
            positionLabel.isHidden = viewModel.queuePositionText == nil
            statusIcon.isHidden = true

            progressRow.isHidden = false
            if let fraction = viewModel.fractionCompleted {
                progressBar.isIndeterminate = false
                progressBar.doubleValue = fraction
            } else {
                progressBar.isIndeterminate = true
                progressBar.startAnimation(nil)
            }
            progressLabel.stringValue = viewModel.progressDetailText ?? ""
            progressLabel.isHidden = viewModel.progressDetailText == nil
        } else {
            progressBar.stopAnimation(nil)
            progressRow.isHidden = true
            positionLabel.isHidden = true
            stepLabel.stringValue = viewModel.idleText
            stepLabel.toolTip = viewModel.idleText
            stepLabel.textColor = .secondaryLabelColor
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
