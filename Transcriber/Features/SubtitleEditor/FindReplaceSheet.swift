import AppKit
import TranscriberCore

/// Aegisub's Find/Replace, reduced to what fixes repeated transcription
/// mistakes: find next, replace all, match case, regular expression. Text
/// fields only; the sheet stays open between searches.
final class FindReplaceSheet: NSWindowController {
    private let editor: SubtitleEditorViewModel
    private let findField = NSTextField()
    private let replaceField = NSTextField()
    private let matchCaseBox = NSButton(checkboxWithTitle: String(localized: "Match case"), target: nil, action: nil)
    private let regexBox = NSButton(checkboxWithTitle: String(localized: "Regular expression"), target: nil, action: nil)
    private let statusLabel = NSTextField(labelWithString: "")

    /// What Find Next (Cmd-G) searches for after the sheet closed.
    private(set) var query = ""
    private(set) var options = SubtitleEditorViewModel.SearchOptions()

    init(editor: SubtitleEditorViewModel) {
        self.editor = editor
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 420, height: 170), styleMask: [.titled], backing: .buffered, defer: true)
        super.init(window: panel)

        findField.placeholderString = String(localized: "Find")
        replaceField.placeholderString = String(localized: "Replace with")
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        let findNext = NSButton(title: String(localized: "Find Next"), target: self, action: #selector(findNext(_:)))
        findNext.keyEquivalent = "\r"
        let replaceAll = NSButton(title: String(localized: "Replace All"), target: self, action: #selector(replaceAll(_:)))
        let done = NSButton(title: String(localized: "Done"), target: self, action: #selector(done(_:)))
        done.keyEquivalent = "\u{1b}"
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let options = NSStackView(views: [matchCaseBox, regexBox])
        let buttons = NSStackView(views: [statusLabel, spacer, done, replaceAll, findNext])
        let stack = NSStackView(views: [findField, replaceField, options, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 16, left: 16, bottom: 16, right: 16)
        for view in [findField, replaceField, buttons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -32).isActive = true
        }
        panel.contentView = stack
        panel.initialFirstResponder = findField
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("FindReplaceSheet is created in code")
    }

    func begin(on window: NSWindow) {
        statusLabel.stringValue = ""
        if let sheet = self.window {
            window.beginSheet(sheet)
        }
    }

    private func readFields() {
        query = findField.stringValue
        options = .init(matchesCase: matchCaseBox.state == .on, usesRegularExpression: regexBox.state == .on)
    }

    @objc private func findNext(_ sender: Any?) {
        readFields()
        statusLabel.stringValue = editor.findNext(query, options: options) ? "" : String(localized: "Not found")
    }

    @objc private func replaceAll(_ sender: Any?) {
        readFields()
        let count = editor.replaceAll(query, with: replaceField.stringValue, options: options)
        statusLabel.stringValue = String(localized: "\(count) lines changed")
    }

    @objc private func done(_ sender: Any?) {
        readFields()
        if let sheet = window {
            sheet.sheetParent?.endSheet(sheet)
        }
    }
}
