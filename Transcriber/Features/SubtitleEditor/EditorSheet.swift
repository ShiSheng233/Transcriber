import AppKit

/// A sheet over the main window with a form, Cancel and a default button,
/// for the editor's dialogs (Shift Times, Adjust Timing, Select Lines).
/// Subclasses fill `form`, refresh `summaryLabel` and act in `confirm()`.
class EditorSheet: NSWindowController {
    private static let width: CGFloat = 400
    private static let inset: CGFloat = 16

    let form = NSStackView()
    let summaryLabel = NSTextField(labelWithString: "")
    let confirmButton: NSButton
    /// Remembers the fields between uses (a per-person convenience).
    let userDefaults: UserDefaults

    init(title: String, confirmTitle: String, userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
        confirmButton = NSButton(title: confirmTitle, target: nil, action: nil)
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 200), styleMask: [.titled], backing: .buffered, defer: true)
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

        let stack = NSStackView(views: [titleLabel, form, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
        panel.contentView = stack
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("Editor sheets are created in code")
    }

    func begin(on window: NSWindow) {
        guard let sheet = self.window, window.attachedSheet == nil else { return }
        update()
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

    /// A row: a label in a fixed column, then controls.
    func row(_ title: String, _ controls: [NSView]) -> NSStackView {
        let label = NSTextField(labelWithString: title)
        label.alignment = .right
        label.widthAnchor.constraint(equalToConstant: 96).isActive = true
        let row = NSStackView(views: [label] + controls)
        row.spacing = 8
        return row
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
