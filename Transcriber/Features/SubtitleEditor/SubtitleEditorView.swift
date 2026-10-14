import AppKit
import TranscriberCore

/// The subtitle grid with the edit box under it, after Aegisub: select lines
/// in the grid, edit the active one's times and text below. Text is kept as
/// it is typed; Return moves to the next line (or makes one after the last),
/// Shift-Return adds a line break.
final class SubtitleEditorView: NSView {
    private enum Column {
        static let number = NSUserInterfaceItemIdentifier("Number")
        static let start = NSUserInterfaceItemIdentifier("Start")
        static let end = NSUserInterfaceItemIdentifier("End")
        static let duration = NSUserInterfaceItemIdentifier("Duration")
        static let speed = NSUserInterfaceItemIdentifier("CPS")
        static let text = NSUserInterfaceItemIdentifier("Text")
    }

    private let viewModel: SubtitleEditorViewModel
    /// Called when the user selects a line, to seek the player to it.
    var onUserSelectedLine: (Int) -> Void = { _ in }

    private let tableView = NSTableView()
    private let startField = NSTextField()
    private let endField = NSTextField()
    private let durationLabel = NSTextField(labelWithString: "")
    private let characterCountLabel = NSTextField(labelWithString: "")
    private let textView = NSTextView()
    private var displayedRows: [SubtitleEditorViewModel.Row] = []
    private var displayedActiveIndex: Int?
    private var isApplyingSelection = false
    private var binder: ObservationBinder?

    init(viewModel: SubtitleEditorViewModel) {
        self.viewModel = viewModel
        super.init(frame: .zero)
        buildGrid()
        let editBox = buildEditBox()
        let gridScroll = NSScrollView()
        gridScroll.documentView = tableView
        gridScroll.hasVerticalScroller = true
        gridScroll.autohidesScrollers = true
        gridScroll.translatesAutoresizingMaskIntoConstraints = false
        editBox.translatesAutoresizingMaskIntoConstraints = false
        addSubview(gridScroll)
        addSubview(editBox)
        NSLayoutConstraint.activate([
            gridScroll.topAnchor.constraint(equalTo: topAnchor),
            gridScroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            gridScroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            editBox.topAnchor.constraint(equalTo: gridScroll.bottomAnchor),
            editBox.leadingAnchor.constraint(equalTo: leadingAnchor),
            editBox.trailingAnchor.constraint(equalTo: trailingAnchor),
            editBox.bottomAnchor.constraint(equalTo: bottomAnchor),
            gridScroll.heightAnchor.constraint(greaterThanOrEqualToConstant: 120),
        ])
        binder = ObservationBinder { [weak self] in self?.render() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("SubtitleEditorView is created in code")
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        viewModel.undoManager = window?.undoManager
    }

    /// Puts the cursor in the text box (double-click in the grid).
    func focusText() {
        guard viewModel.canEditSelection else { return }
        window?.makeFirstResponder(textView)
    }

    /// Where the edit box's cursor is, for Split.
    var textCursorOffset: Int {
        let location = textView.selectedRange().location
        return textView.string.prefix(location == NSNotFound ? 0 : location).count
    }

    /// Text is committed as it is typed; kept for callers that need to be sure.
    func commitPendingText() {
        if viewModel.activeIndex != nil, viewModel.isEditable, textView.string != viewModel.activeLine?.text {
            viewModel.setText(textView.string)
        }
    }

    // MARK: Building

    private func buildGrid() {
        let columns: [(NSUserInterfaceItemIdentifier, String, CGFloat?)] = [
            (Column.number, "#", 48),
            (Column.start, String(localized: "Start"), 92),
            (Column.end, String(localized: "End"), 92),
            (Column.duration, String(localized: "Duration"), 80),
            (Column.speed, String(localized: "CPS"), 44),
            (Column.text, String(localized: "Text"), nil),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            if let width {
                column.width = width
                column.resizingMask = []
            } else {
                column.resizingMask = .autoresizingMask
            }
            tableView.addTableColumn(column)
        }
        tableView.style = .fullWidth
        tableView.rowHeight = 22
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(rowDoubleClicked(_:))
        tableView.menu = SubtitleEditorMenu.make()
    }

    private func buildEditBox() -> NSView {
        for field in [startField, endField] {
            field.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            field.alignment = .center
            field.delegate = self
            field.target = self
            field.action = #selector(timeFieldCommitted(_:))
            field.widthAnchor.constraint(equalToConstant: 96).isActive = true
        }
        startField.placeholderString = String(localized: "Start")
        endField.placeholderString = String(localized: "End")
        durationLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        durationLabel.textColor = .secondaryLabelColor
        characterCountLabel.font = .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        characterCountLabel.toolTip = String(localized: "Characters in the longest line / limit")
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let timeRow = NSStackView(views: [startField, NSTextField(labelWithString: "→"), endField, durationLabel, spacer, characterCountLabel])
        timeRow.spacing = 6

        textView.font = .systemFont(ofSize: NSFont.systemFontSize + 2)
        textView.isRichText = false
        // Undo is the editor's: typing in a line is one step, as in Aegisub.
        textView.allowsUndo = false
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isContinuousSpellCheckingEnabled = true
        textView.textContainerInset = NSSize(width: 4, height: 6)
        textView.delegate = self
        textView.autoresizingMask = [.width]
        let textScroll = NSScrollView()
        textScroll.documentView = textView
        textScroll.hasVerticalScroller = true
        textScroll.autohidesScrollers = true
        textScroll.borderType = .bezelBorder
        textScroll.heightAnchor.constraint(equalToConstant: 64).isActive = true

        let box = NSStackView(views: [timeRow, textScroll])
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        textScroll.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true
        timeRow.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true

        let separator = NSBox()
        separator.boxType = .separator
        let container = NSStackView(views: [separator, box])
        container.orientation = .vertical
        container.spacing = 0
        separator.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        box.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        return container
    }

    // MARK: Rendering

    private func render() {
        let rows = viewModel.rows
        if rows != displayedRows {
            if rows.count == displayedRows.count {
                // Reload only the rows that changed (typing, playhead): keeps editing smooth.
                let changed = IndexSet(rows.indices.filter { rows[$0] != displayedRows[$0] })
                displayedRows = rows
                tableView.reloadData(forRowIndexes: changed, columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
            } else {
                displayedRows = rows
                tableView.reloadData()
            }
        }
        let selection = IndexSet(viewModel.selection)
        if tableView.selectedRowIndexes != selection {
            isApplyingSelection = true
            tableView.selectRowIndexes(selection, byExtendingSelection: false)
            isApplyingSelection = false
            if let first = selection.first {
                tableView.scrollRowToVisible(first)
            }
        }
        renderEditBox()
    }

    private func renderEditBox() {
        let line = viewModel.activeLine
        let editable = viewModel.isEditable && line != nil
        for field in [startField, endField] {
            field.isEditable = editable
            field.isEnabled = line != nil
        }
        textView.isEditable = editable
        if startField.currentEditor() == nil {
            startField.stringValue = line.map { SubtitleTimeFormat.string($0.start) } ?? ""
        }
        if endField.currentEditor() == nil {
            endField.stringValue = line.map { SubtitleTimeFormat.string($0.end) } ?? ""
        }
        durationLabel.stringValue = line == nil ? "" : String(localized: "Duration \(viewModel.activeDuration)")
        if let count = viewModel.characterCount {
            characterCountLabel.stringValue = "\(count.count)/\(count.limit)"
            characterCountLabel.textColor = count.count > count.limit ? .systemRed : .secondaryLabelColor
        } else {
            characterCountLabel.stringValue = ""
        }
        // A different line, or the same line changed elsewhere (undo).
        let isEditingText = window?.firstResponder === textView
        if viewModel.activeIndex != displayedActiveIndex || (!isEditingText && textView.string != (line?.text ?? "")) {
            displayedActiveIndex = viewModel.activeIndex
            textView.string = line?.text ?? ""
        }
    }

    // MARK: Actions

    @objc private func rowDoubleClicked(_ sender: Any?) {
        focusText()
    }

    @objc private func timeFieldCommitted(_ sender: NSTextField) {
        commit(timeField: sender)
    }

    private func commit(timeField field: NSTextField) {
        let accepted = field === startField ? viewModel.setStart(field.stringValue) : viewModel.setEnd(field.stringValue)
        if !accepted {
            NSSound.beep()
            field.stringValue = viewModel.activeLine.map { SubtitleTimeFormat.string(field === startField ? $0.start : $0.end) } ?? ""
        }
    }
}

extension SubtitleEditorView: NSTableViewDataSource, NSTableViewDelegate {
    func numberOfRows(in tableView: NSTableView) -> Int {
        displayedRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let rowData = displayedRows[row]
        let identifier = tableColumn?.identifier ?? Column.text
        let label = (tableView.makeView(withIdentifier: identifier, owner: nil) as? NSTextField) ?? {
            let label = NSTextField(labelWithString: "")
            label.identifier = identifier
            label.lineBreakMode = .byTruncatingTail
            return label
        }()
        label.font = identifier == Column.text ? .systemFont(ofSize: NSFont.systemFontSize) : .monospacedDigitSystemFont(ofSize: NSFont.smallSystemFontSize, weight: .regular)
        label.textColor = rowData.overlapsActiveLine ? .systemRed : identifier == Column.text ? .labelColor : .secondaryLabelColor
        label.alignment = identifier == Column.text ? .natural : .right
        label.drawsBackground = false
        switch identifier {
        case Column.number:
            label.stringValue = rowData.isPlaying ? "▶ \(rowData.number)" : "\(rowData.number)"
            if rowData.isPlaying {
                label.textColor = .controlAccentColor
            }
        case Column.start:
            label.stringValue = rowData.start
        case Column.end:
            label.stringValue = rowData.end
        case Column.duration:
            label.stringValue = rowData.duration
        case Column.speed:
            label.stringValue = rowData.charactersPerSecond
            // Aegisub: from 15 CPS the cell turns red, fully at 30.
            if rowData.readingSpeedWarning > 0 {
                label.drawsBackground = true
                label.backgroundColor = NSColor.systemRed.withAlphaComponent(0.15 + 0.55 * rowData.readingSpeedWarning)
                label.textColor = .labelColor
            }
        default:
            label.stringValue = rowData.text
            label.toolTip = rowData.text
        }
        return label
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isApplyingSelection else { return }
        let indices = Array(tableView.selectedRowIndexes)
        viewModel.select(indices)
        if indices.count == 1, let index = indices.first {
            onUserSelectedLine(index)
        }
    }
}

extension SubtitleEditorView: NSTextViewDelegate, NSTextFieldDelegate {
    func textDidChange(_ notification: Notification) {
        viewModel.setText(textView.string)
    }

    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard commandSelector == #selector(NSResponder.insertNewline(_:)) else {
            return false
        }
        if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
            textView.insertText("\n", replacementRange: textView.selectedRange())
        } else {
            viewModel.advance()
        }
        return true
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        if let field = notification.object as? NSTextField, field === startField || field === endField {
            commit(timeField: field)
        }
    }
}
