import AppKit

/// Building blocks for a System Settings–style form: a page holds titled
/// sections; a section is a rounded group of rows separated by hairlines; a
/// row has a title (and optional description) on the left and its control on
/// the right.
enum SettingsForm {
    static let pageWidth: CGFloat = 540
    private static let pageInset: CGFloat = 20
    private static let rowInsets = NSEdgeInsets(top: 9, left: 12, bottom: 9, right: 12)
    private static let minimumRowHeight: CGFloat = 40

    static func page(_ sections: [NSView]) -> NSView {
        let stack = verticalStack(sections, spacing: 22)
        stack.edgeInsets = NSEdgeInsets(top: pageInset, left: pageInset, bottom: pageInset + 4, right: pageInset)
        stack.widthAnchor.constraint(equalToConstant: pageWidth).isActive = true
        for section in sections {
            section.widthAnchor.constraint(equalToConstant: pageWidth - 2 * pageInset).isActive = true
        }
        return stack
    }

    static func section(_ title: String?, rows: [NSView], footer: String? = nil) -> NSView {
        var views: [NSView] = []
        if let title {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
            views.append(label)
        }
        let group = GroupBox(rows: rows)
        views.append(group)
        if let footer {
            let label = NSTextField(wrappingLabelWithString: footer)
            label.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            label.textColor = .secondaryLabelColor
            views.append(label)
        }
        let stack = verticalStack(views, spacing: 8)
        for view in views {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        }
        return stack
    }

    static func row(_ title: String, description: String? = nil, control: NSView) -> NSView {
        let titleLabel = NSTextField(labelWithString: title)
        var labels: [NSView] = [titleLabel]
        if let description {
            let descriptionLabel = NSTextField(wrappingLabelWithString: description)
            descriptionLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
            descriptionLabel.textColor = .secondaryLabelColor
            labels.append(descriptionLabel)
        }
        let labelStack = verticalStack(labels, spacing: 2)
        labelStack.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        labelStack.setContentHuggingPriority(.defaultLow, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)

        let row = NSStackView(views: [labelStack, control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.distribution = .fill  // the labels take the free space, the control sits at the trailing edge
        row.spacing = 16
        row.edgeInsets = rowInsets
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumRowHeight).isActive = true
        return row
    }

    /// A row holding a single control across the full width (e.g. a path).
    static func row(control: NSView) -> NSView {
        let row = NSStackView(views: [control])
        row.orientation = .horizontal
        row.alignment = .centerY
        row.edgeInsets = rowInsets
        row.heightAnchor.constraint(greaterThanOrEqualToConstant: minimumRowHeight).isActive = true
        return row
    }

    /// A folder icon and an abbreviated path ("~/…"), truncated in the middle.
    static func pathView() -> PathView {
        PathView()
    }

    static func popUp(_ titles: [String], target: AnyObject, action: Selector) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.addItems(withTitles: titles)
        popUp.target = target
        popUp.action = action
        return popUp
    }

    private static func verticalStack(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }
}

/// The rounded background of a section, with hairlines between its rows.
private final class GroupBox: NSView {
    init(rows: [NSView]) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 8
        layer?.cornerCurve = .continuous
        translatesAutoresizingMaskIntoConstraints = false

        let stack = NSStackView(views: rows)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 0
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        for (index, row) in rows.enumerated() {
            row.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            if index > 0 {
                SettingsForm.addDivider(above: row)
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("GroupBox is created in code")
    }

    override var wantsUpdateLayer: Bool {
        true
    }

    override func updateLayer() {
        layer?.backgroundColor = NSColor.quaternarySystemFill.cgColor
        layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        layer?.borderWidth = 0.5
    }
}

extension SettingsForm {
    /// Draws a hairline along the top of `row`, indented on the leading side
    /// like System Settings. It belongs to the row, so hiding the row hides it.
    static func addDivider(above row: NSView) {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        row.addSubview(line)
        NSLayoutConstraint.activate([
            line.topAnchor.constraint(equalTo: row.topAnchor),
            line.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 12),
            line.trailingAnchor.constraint(equalTo: row.trailingAnchor),
        ])
    }
}

/// Shows a folder as its Finder icon followed by its path.
final class PathView: NSStackView {
    private let iconView = NSImageView()
    private let pathLabel = NSTextField(labelWithString: "")

    init() {
        super.init(frame: .zero)
        orientation = .horizontal
        spacing = 6
        iconView.imageScaling = .scaleProportionallyUpOrDown
        iconView.widthAnchor.constraint(equalToConstant: 16).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 16).isActive = true
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        setContentHuggingPriority(.defaultLow, for: .horizontal)
        addArrangedSubview(iconView)
        addArrangedSubview(pathLabel)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("PathView is created in code")
    }

    var url: URL? {
        didSet {
            guard let url else {
                pathLabel.stringValue = ""
                iconView.image = nil
                return
            }
            pathLabel.stringValue = (url.path as NSString).abbreviatingWithTildeInPath
            pathLabel.toolTip = url.path
            iconView.image = NSWorkspace.shared.icon(forFile: url.path)
        }
    }
}
