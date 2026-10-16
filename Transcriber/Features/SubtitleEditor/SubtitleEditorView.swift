import AppKit
import TranscriberCore

/// The editor pane, top to bottom as in Aegisub: the action bar, the
/// waveform (in timing mode), the edit box for the active line, and the grid
/// of lines. Text is kept as it is typed; Return moves to the next line (or
/// makes one after the last), Shift-Return adds a line break.
final class SubtitleEditorView: NSView {
    private enum Column {
        static let number = NSUserInterfaceItemIdentifier("Number")
        static let start = NSUserInterfaceItemIdentifier("Start")
        static let end = NSUserInterfaceItemIdentifier("End")
        static let duration = NSUserInterfaceItemIdentifier("Duration")
        static let speed = NSUserInterfaceItemIdentifier("CPS")
        static let source = NSUserInterfaceItemIdentifier("Source")
        static let text = NSUserInterfaceItemIdentifier("Text")
    }

    private let viewModel: SubtitleEditorViewModel
    /// Called when the user selects a line, to seek the player to it.
    var onUserSelectedLine: (Int) -> Void = { _ in }

    private static let waveformHeight: CGFloat = 96

    let actionBar = SubtitleEditorActionBar()
    private let waveformSlot = NSStackView()
    private let tableView = NSTableView()
    private let sourceLabel = NSTextField(wrappingLabelWithString: "")
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
        waveformSlot.orientation = .vertical
        waveformSlot.spacing = 0

        let column = NSStackView(views: [actionBar, Self.separator(), waveformSlot, editBox, gridScroll])
        column.orientation = .vertical
        column.spacing = 0
        column.distribution = .fill
        column.detachesHiddenViews = true
        column.translatesAutoresizingMaskIntoConstraints = false
        for view in column.arrangedSubviews {
            view.widthAnchor.constraint(equalTo: column.widthAnchor).isActive = true
        }
        // The grid takes the height the rest leaves.
        gridScroll.setContentHuggingPriority(.defaultLow, for: .vertical)
        gridScroll.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: topAnchor),
            column.leadingAnchor.constraint(equalTo: leadingAnchor),
            column.trailingAnchor.constraint(equalTo: trailingAnchor),
            column.bottomAnchor.constraint(equalTo: bottomAnchor),
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

    /// Shows the waveform between the action bar and the edit box, or
    /// removes it (`nil`).
    func showWaveform(_ waveform: NSView?) {
        let current = waveformSlot.arrangedSubviews
        guard current.first !== waveform else { return }
        current.forEach { $0.removeFromSuperview() }
        guard let waveform else { return }
        if !waveform.constraints.contains(where: { $0.firstAttribute == .height && $0.secondItem == nil }) {
            waveform.heightAnchor.constraint(equalToConstant: Self.waveformHeight).isActive = true
        }
        waveformSlot.addArrangedSubview(waveform)
        waveformSlot.addArrangedSubview(Self.separator())
    }

    private static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        return line
    }

    /// Whether the edit box's text view has the cursor, for Split at Playhead.
    var isEditingText: Bool {
        window?.firstResponder === textView
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
            (Column.source, String(localized: "Source"), nil),
            (Column.text, String(localized: "Text"), nil),
        ]
        for (identifier, title, width) in columns {
            let column = NSTableColumn(identifier: identifier)
            column.title = title
            if let width {
                column.width = width
                column.resizingMask = []
                column.headerCell.alignment = .right  // over right-aligned numbers
            } else {
                column.resizingMask = .autoresizingMask
            }
            tableView.addTableColumn(column)
        }
        tableView.style = .fullWidth
        tableView.rowHeight = 24
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = true
        tableView.columnAutoresizingStyle = .uniformColumnAutoresizingStyle
        tableView.tableColumn(withIdentifier: Column.source)?.isHidden = true
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

        sourceLabel.font = .systemFont(ofSize: NSFont.systemFontSize)
        sourceLabel.textColor = .secondaryLabelColor
        sourceLabel.isSelectable = true
        sourceLabel.maximumNumberOfLines = 2
        sourceLabel.lineBreakMode = .byTruncatingTail
        sourceLabel.toolTip = String(localized: "The line before the language model changed it")
        sourceLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let box = NSStackView(views: [timeRow, sourceLabel, textScroll])
        box.detachesHiddenViews = true
        box.orientation = .vertical
        box.alignment = .leading
        box.spacing = 6
        box.edgeInsets = NSEdgeInsets(top: 8, left: 10, bottom: 10, right: 10)
        textScroll.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true
        timeRow.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true
        sourceLabel.widthAnchor.constraint(equalTo: box.widthAnchor, constant: -20).isActive = true

        let separator = Self.separator()
        let container = NSStackView(views: [box, separator])
        container.orientation = .vertical
        container.spacing = 0
        separator.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        box.widthAnchor.constraint(equalTo: container.widthAnchor).isActive = true
        container.setContentHuggingPriority(.required, for: .vertical)
        return container
    }

    // MARK: Rendering

    private func render() {
        let showsSource = viewModel.showsSourceColumn
        if let sourceColumn = tableView.tableColumn(withIdentifier: Column.source), sourceColumn.isHidden == showsSource {
            sourceColumn.isHidden = !showsSource
            tableView.sizeToFit()
        }
        actionBar.validate()
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
                scrollToShow(row: first)
            }
        }
        renderEditBox()
    }

    /// Keeps a few rows of context below the row, like Aegisub's margin, so
    /// a followed line is never pinned to the bottom edge.
    private func scrollToShow(row: Int) {
        tableView.scrollRowToVisible(min(row + 3, tableView.numberOfRows - 1))
        tableView.scrollRowToVisible(max(row - 1, 0))
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
        let source = viewModel.showsSourceColumn ? viewModel.activeSource : nil
        sourceLabel.stringValue = source ?? ""
        sourceLabel.isHidden = source == nil
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
        let cell = (tableView.makeView(withIdentifier: identifier, owner: nil) as? SubtitleGridCellView)
            ?? SubtitleGridCellView(identifier: identifier)
        let overlapping = rowData.overlapsActiveLine
        switch identifier {
        case Column.number:
            cell.configure(text: rowData.isPlaying ? "▶ \(rowData.number)" : "\(rowData.number)", role: .number, alignment: .right, isPlaying: rowData.isPlaying)
        case Column.start:
            cell.configure(text: rowData.start, role: .time, alignment: .right, isOverlapping: overlapping)
        case Column.end:
            cell.configure(text: rowData.end, role: .time, alignment: .right, isOverlapping: overlapping)
        case Column.duration:
            cell.configure(text: rowData.duration, role: .time, alignment: .right)
        case Column.source:
            cell.configure(text: rowData.source.isEmpty ? "—" : rowData.source, role: .source, alignment: .natural)
        case Column.speed:
            cell.configure(text: rowData.charactersPerSecond, role: .time, alignment: .right, readingSpeedWarning: rowData.readingSpeedWarning)
        default:
            cell.configure(text: rowData.text, role: .text, alignment: .natural, isOverlapping: overlapping)
        }
        return cell
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

    func textDidBeginEditing(_ notification: Notification) {
        viewModel.isEditingInEditBox = true
    }

    func textDidEndEditing(_ notification: Notification) {
        viewModel.isEditingInEditBox = false
    }

    func controlTextDidBeginEditing(_ notification: Notification) {
        viewModel.isEditingInEditBox = true
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
        viewModel.isEditingInEditBox = false
        if let field = notification.object as? NSTextField, field === startField || field === endField {
            commit(timeField: field)
        }
    }
}
