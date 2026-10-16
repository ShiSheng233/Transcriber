import AppKit

/// A sheet over the main window with a form, Cancel and a default button,
/// for the editor's dialogs (Shift Times, Adjust Timing, Select Lines).
/// Subclasses fill `form`, refresh `summaryLabel` and act in `confirm()`.
class EditorSheet: NSWindowController {
    private static let minimumWidth: CGFloat = 400
    private static let inset: CGFloat = 20

    let form = NSStackView()
    let summaryLabel = NSTextField(labelWithString: "")
    let confirmButton: NSButton
    /// Remembers the fields between uses (a per-person convenience).
    let userDefaults: UserDefaults
    private let content = NSStackView()
    /// Every row's label, kept equally wide so the controls line up.
    private var rowLabels: [NSTextField] = []

    init(title: String, confirmTitle: String, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        confirmButton = NSButton(title: confirmTitle, target: nil, action: nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.minimumWidth, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = title
        super.init(window: panel)

        let titleLabel = NSTextField(labelWithString: title)
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        form.orientation = .vertical
        form.alignment = .leading
        form.spacing = 10
        summaryLabel.textColor = .secondaryLabelColor
        summaryLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        summaryLabel.lineBreakMode = .byTruncatingTail
        summaryLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        confirmButton.target = self
        confirmButton.action = #selector(confirmPressed(_:))
        confirmButton.keyEquivalent = "\r"
        let cancel = NSButton(title: String(localized: "Cancel"), target: self, action: #selector(cancelPressed(_:)))
        cancel.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [summaryLabel, spacer, cancel, confirmButton])

        [titleLabel, form, buttons].forEach(content.addArrangedSubview)
        content.orientation = .vertical
        content.alignment = .leading
        content.spacing = 14
        content.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        // At least this wide, wider when a row needs it, never clipping a row.
        content.widthAnchor.constraint(greaterThanOrEqualToConstant: Self.minimumWidth).isActive = true
        content.setHuggingPriority(.defaultHigh, for: .horizontal)
        buttons.widthAnchor.constraint(equalTo: content.widthAnchor, constant: -2 * Self.inset).isActive = true
        panel.contentView = content
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Editor sheets are created in code")
    }

    func begin(on window: NSWindow) {
        guard let sheet = self.window, window.attachedSheet == nil else { return }
        update()
        alignRowLabels()
        content.layoutSubtreeIfNeeded()
        sheet.setContentSize(content.fittingSize)
        window.beginSheet(sheet)
    }

    /// Recomputes the summary and whether the default button is enabled.
    func update() {}

    /// Applies the sheet; return false to keep it open.
    func confirm() -> Bool {
        true
    }

    @objc func fieldChanged(_ sender: Any?) {
        update()
    }

    private func end() {
        if let sheet = window {
            sheet.sheetParent?.endSheet(sheet)
        }
    }

    @objc private func confirmPressed(_ sender: Any?) {
        if confirm() {
            end()
        }
    }

    @objc private func cancelPressed(_ sender: Any?) {
        end()
    }

    // MARK: Building blocks

    /// A row: a label in a column as wide as the widest label, then controls.
    func row(_ title: String, _ controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.setContentCompressionResistancePriority(.required, for: .horizontal)
        rowLabels.append(label)
        let row = NSStackView(views: [label] + controls)
        row.spacing = 8
        return row
    }

    /// Labels in different rows can only be tied together once the rows are
    /// in the sheet, so this runs when it opens.
    private func alignRowLabels() {
        guard let first = rowLabels.first else { return }
        NSLayoutConstraint.activate(rowLabels.dropFirst().map { $0.widthAnchor.constraint(equalTo: first.widthAnchor) })
        rowLabels = []
    }

    func radioButtons(_ titles: [String]) -> [NSButton] {
        titles.map { NSButton(radioButtonWithTitle: $0, target: self, action: #selector(fieldChanged(_:))) }
    }

    func checkbox(_ title: String) -> NSButton {
        NSButton(checkboxWithTitle: title, target: self, action: #selector(fieldChanged(_:)))
    }

    /// A short number field that updates the sheet as it is typed.
    func numberField(width: CGFloat = 64) -> NSTextField {
        let field = NSTextField()
        field.alignment = .right
        field.widthAnchor.constraint(equalToConstant: width).isActive = true
        field.delegate = self
        return field
    }

    static func selectedIndex(of buttons: [NSButton]) -> Int {
        buttons.firstIndex { $0.state == .on } ?? 0
    }

    static func select(_ index: Int, in buttons: [NSButton]) {
        for (position, button) in buttons.enumerated() {
            button.state = position == index ? .on : .off
        }
    }
}

extension EditorSheet: NSTextFieldDelegate {
    func controlTextDidChange(_ notification: Notification) {
        update()
    }
}
