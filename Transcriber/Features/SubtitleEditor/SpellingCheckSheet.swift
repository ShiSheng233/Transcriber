import AppKit
import TranscriberCore

/// Aegisub's spell checker: each misspelled word in its line, from the
/// active line once round the file, with the dictionary's suggestions.
/// Replace and Replace All are undo steps; Ignore skips the word once,
/// Ignore All until the app quits, Add to Dictionary for good. The sheet
/// stays open from word to word; the grid and the player follow the line.
final class SpellingCheckSheet: NSWindowController {
    private static let width: CGFloat = 460
    private static let suggestionListHeight: CGFloat = 120
    private static let inset: CGFloat = 20

    private let editor: SubtitleEditorViewModel
    private let showLine: (Int) -> Void
    private let locationLabel = NSTextField(labelWithString: "")
    private let contextLabel = NSTextField(wrappingLabelWithString: "")
    private let replacementField = NSTextField()
    private let suggestionTable = NSTableView()
    private let statusLabel = NSTextField(labelWithString: "")
    private lazy var replaceButton = button(String(localized: "Replace"), #selector(replace(_:)))
    private lazy var replaceAllButton = button(String(localized: "Replace All"), #selector(replaceAll(_:)))
    private lazy var ignoreButton = button(String(localized: "Ignore"), #selector(ignore(_:)))
    private lazy var ignoreAllButton = button(String(localized: "Ignore All"), #selector(ignoreAll(_:)))
    private lazy var learnButton = button(String(localized: "Add to Dictionary"), #selector(learn(_:)))
    private var misspelling: SubtitleEditorViewModel.Misspelling?
    /// Some word was shown since the sheet opened: the end is "done", not "none found".
    private var foundAny = false

    /// - Parameter showLine: moves the player to a line whose word is shown.
    init(editor: SubtitleEditorViewModel, showLine: @escaping (Int) -> Void) {
        self.editor = editor
        self.showLine = showLine
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 360), styleMask: [.titled], backing: .buffered, defer: true)
        panel.title = String(localized: "Check Spelling")
        super.init(window: panel)

        let titleLabel = NSTextField(labelWithString: String(localized: "Check Spelling"))
        titleLabel.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        locationLabel.textColor = .secondaryLabelColor
        locationLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        contextLabel.preferredMaxLayoutWidth = Self.width - 2 * Self.inset
        contextLabel.isSelectable = true
        contextLabel.maximumNumberOfLines = 4
        replacementField.placeholderString = String(localized: "Replace with")

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("Suggestion"))
        column.resizingMask = .autoresizingMask
        suggestionTable.addTableColumn(column)
        suggestionTable.headerView = nil
        suggestionTable.style = .inset
        suggestionTable.dataSource = self
        suggestionTable.delegate = self
        suggestionTable.target = self
        suggestionTable.doubleAction = #selector(replace(_:))
        let suggestionScroll = NSScrollView()
        suggestionScroll.documentView = suggestionTable
        suggestionScroll.hasVerticalScroller = true
        suggestionScroll.autohidesScrollers = true
        suggestionScroll.borderType = .bezelBorder
        suggestionScroll.heightAnchor.constraint(equalToConstant: Self.suggestionListHeight).isActive = true

        replaceButton.keyEquivalent = "\r"
        let done = button(String(localized: "Done"), #selector(done(_:)))
        done.keyEquivalent = "\u{1b}"
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let keepButtons = NSStackView(views: [ignoreButton, ignoreAllButton, learnButton])
        let endButtons = NSStackView(views: [statusLabel, spacer, done, replaceAllButton, replaceButton])

        let stack = NSStackView(views: [
            titleLabel, locationLabel, contextLabel,
            NSTextField(labelWithString: String(localized: "Replace with:")), replacementField,
            NSTextField(labelWithString: String(localized: "Suggestions:")), suggestionScroll,
            keepButtons, endButtons,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.setCustomSpacing(14, after: suggestionScroll)
        stack.edgeInsets = NSEdgeInsets(top: Self.inset, left: Self.inset, bottom: Self.inset, right: Self.inset)
        for view in [contextLabel, replacementField, suggestionScroll, endButtons] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -2 * Self.inset).isActive = true
        }
        stack.widthAnchor.constraint(equalToConstant: Self.width).isActive = true
        panel.contentView = stack
        panel.initialFirstResponder = replacementField
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SpellingCheckSheet is created in code")
    }

    /// Starts again from the active line: the lines may have changed since the last time.
    func begin(on window: NSWindow) {
        guard let sheet = self.window, window.attachedSheet == nil else { return }
        foundAny = false
        show(editor.firstMisspelling())
        sheet.contentView?.layoutSubtreeIfNeeded()
        if let size = sheet.contentView?.fittingSize {
            sheet.setContentSize(size)
        }
        window.beginSheet(sheet)
    }

    private func button(_ title: String, _ action: Selector) -> NSButton {
        NSButton(title: title, target: self, action: action)
    }

    private func show(_ next: SubtitleEditorViewModel.Misspelling?) {
        misspelling = next
        let dictionary = editor.spellingDictionaryName.map { String(localized: "Dictionary: \($0)") }
            ?? String(localized: "Each word is checked in the language it appears to be in")
        if let next {
            foundAny = true
            locationLabel.stringValue = String(localized: "Line \(next.lineIndex + 1) · \(dictionary)")
            contextLabel.attributedStringValue = Self.context(of: next)
            replacementField.stringValue = next.suggestions.first ?? next.word
            statusLabel.stringValue = ""
            showLine(next.lineIndex)
        } else {
            locationLabel.stringValue = dictionary
            contextLabel.stringValue = ""
            replacementField.stringValue = ""
            statusLabel.stringValue = foundAny
                ? String(localized: "The spelling check is complete.")
                : String(localized: "No misspelled words were found.")
        }
        suggestionTable.reloadData()
        for control in [replaceButton, replaceAllButton, ignoreButton, ignoreAllButton, learnButton] {
            control.isEnabled = next != nil
        }
        replacementField.isEnabled = next != nil
    }

    /// The line with its misspelled word marked.
    private static func context(of misspelling: SubtitleEditorViewModel.Misspelling) -> NSAttributedString {
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize + 2)
        let text = NSMutableAttributedString(string: misspelling.lineText, attributes: [.font: font, .foregroundColor: NSColor.labelColor])
        text.addAttributes(
            [
                .font: NSFont.boldSystemFont(ofSize: font.pointSize),
                .foregroundColor: NSColor.systemRed,
                .underlineStyle: NSUnderlineStyle.single.rawValue,
            ],
            range: NSRange(misspelling.range, in: misspelling.lineText)
        )
        return text
    }

    // MARK: Actions

    @objc private func replace(_ sender: Any?) {
        guard let misspelling else { return }
        show(editor.correctMisspelling(misspelling, to: replacementField.stringValue))
    }

    @objc private func replaceAll(_ sender: Any?) {
        guard let misspelling else { return }
        let outcome = editor.correctMisspellingEverywhere(misspelling, to: replacementField.stringValue)
        show(outcome.next)
        if outcome.next != nil {
            statusLabel.stringValue = String(localized: "\(outcome.changedLineCount) lines changed")
        }
    }

    @objc private func ignore(_ sender: Any?) {
        guard let misspelling else { return }
        show(editor.skipMisspelling(misspelling))
    }

    @objc private func ignoreAll(_ sender: Any?) {
        guard let misspelling else { return }
        show(editor.ignoreMisspellingEverywhere(misspelling))
    }

    @objc private func learn(_ sender: Any?) {
        guard let misspelling else { return }
        show(editor.learnMisspelling(misspelling))
    }

    @objc private func done(_ sender: Any?) {
        misspelling = nil
        if let sheet = window {
            sheet.sheetParent?.endSheet(sheet)
        }
    }
}

extension SpellingCheckSheet: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        misspelling?.suggestions.count ?? 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let identifier = NSUserInterfaceItemIdentifier("SuggestionCell")
        let label = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
            return label
        }()
        label.stringValue = misspelling?.suggestions[row] ?? ""
        return label
    }

    /// Choosing a suggestion makes it the replacement.
    func tableViewSelectionDidChange(_ notification: Notification) {
        let row = suggestionTable.selectedRow
        if let suggestions = misspelling?.suggestions, suggestions.indices.contains(row) {
            replacementField.stringValue = suggestions[row]
        }
    }
}
