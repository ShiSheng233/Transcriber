import AppKit
import TranscriberCore

/// Aegisub's Shift Times: move lines by a time or a number of frames,
/// earlier or later, the selection, all lines or from the active line on,
/// both edges or one. The fields are remembered.
final class ShiftTimesSheet: EditorSheet {
    private enum Key {
        static let amount = "ShiftTimesAmount"
        static let usesFrames = "ShiftTimesUsesFrames"
        static let framesPerSecond = "ShiftTimesFramesPerSecond"
        static let isEarlier = "ShiftTimesEarlier"
        static let edges = "ShiftTimesEdges"
    }

    private static let frameRates = [23.976, 24, 25, 29.97, 30, 50, 59.94, 60]
    private static let defaultFrameRateIndex = 0

    private let editor: SubtitleEditorViewModel
    private let amountField = NSTextField()
    private lazy var unitControl = NSSegmentedControl(
        labels: [String(localized: "Time"), String(localized: "Frames")], trackingMode: .selectOne,
        target: self, action: #selector(unitChanged(_:))
    )
    private let frameRatePopUp = NSPopUpButton()
    private lazy var directionButtons = radioButtons([String(localized: "Later"), String(localized: "Earlier")])
    private lazy var scopeButtons = radioButtons([
        String(localized: "Selected lines"), String(localized: "All lines"), String(localized: "Selected line onward"),
    ])
    private lazy var edgeButtons = radioButtons([String(localized: "Start and end"), String(localized: "Start only"), String(localized: "End only")])

    private static let scopes: [SubtitleEditorViewModel.ShiftScope] = [.selectedLines, .allLines, .selectedLineOnward]
    private static let edges: [SubtitleEditing.TimeEdges] = [.both, .start, .end]

    init(editor: SubtitleEditorViewModel) {
        self.editor = editor
        super.init(title: String(localized: "Shift Times"), confirmTitle: String(localized: "Shift"))
        amountField.font = .monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        amountField.widthAnchor.constraint(equalToConstant: 110).isActive = true
        amountField.delegate = self
        frameRatePopUp.addItems(withTitles: Self.frameRates.map { String(format: "%g fps", $0) })
        frameRatePopUp.target = self
        frameRatePopUp.action = #selector(fieldChanged(_:))
        for view in [
            row(String(localized: "Shift by:"), [amountField, unitControl, frameRatePopUp]),
            row(String(localized: "Direction:"), directionButtons),
            row(String(localized: "Lines:"), scopeButtons),
            row(String(localized: "Times:"), edgeButtons),
        ] {
            form.addArrangedSubview(view)
        }
        restore()
        window?.initialFirstResponder = amountField
    }

    private func restore() {
        let usesFrames = userDefaults.bool(forKey: Key.usesFrames)
        unitControl.selectedSegment = usesFrames ? 1 : 0
        amountField.stringValue = userDefaults.string(forKey: Key.amount) ?? (usesFrames ? "0" : "0:00:00.00")
        let rateIndex = userDefaults.object(forKey: Key.framesPerSecond) == nil ? Self.defaultFrameRateIndex : userDefaults.integer(forKey: Key.framesPerSecond)
        frameRatePopUp.selectItem(at: Self.frameRates.indices.contains(rateIndex) ? rateIndex : Self.defaultFrameRateIndex)
        Self.select(userDefaults.bool(forKey: Key.isEarlier) ? 1 : 0, in: directionButtons)
        Self.select(min(userDefaults.integer(forKey: Key.edges), Self.edges.count - 1), in: edgeButtons)
    }

    override func begin(on window: NSWindow) {
        // Lines: the selection when there is one, else all of them.
        Self.select(editor.selection.isEmpty ? 1 : 0, in: scopeButtons)
        scopeButtons[0].isEnabled = !editor.selection.isEmpty
        scopeButtons[2].isEnabled = !editor.selection.isEmpty
        super.begin(on: window)
    }

    /// The offset typed, signed; `nil` when the field is not a time or count.
    private var offset: AudioTime? {
        let text = amountField.stringValue
        let magnitude: AudioTime?
        if unitControl.selectedSegment == 1 {
            let rate = Self.frameRates[max(frameRatePopUp.indexOfSelectedItem, 0)]
            magnitude = Int(text.trimmingCharacters(in: .whitespaces)).map { AudioTime(seconds: Double($0) / rate) }
        } else {
            magnitude = SubtitleTimeFormat.time(from: text)
        }
        guard let magnitude else { return nil }
        return Self.selectedIndex(of: directionButtons) == 1 ? .zero - magnitude : magnitude
    }

    private var scope: SubtitleEditorViewModel.ShiftScope {
        Self.scopes[Self.selectedIndex(of: scopeButtons)]
    }

    override func update() {
        frameRatePopUp.isHidden = unitControl.selectedSegment == 0
        let count = editor.lineIndices(for: scope).count
        guard let offset, offset != .zero, count > 0 else {
            summaryLabel.stringValue = ""
            confirmButton.isEnabled = false
            return
        }
        confirmButton.isEnabled = true
        let seconds = String(format: "%.3f", abs(offset.seconds))
        summaryLabel.stringValue = offset > .zero
            ? String(localized: "Moves \(count) lines \(seconds) s later")
            : String(localized: "Moves \(count) lines \(seconds) s earlier")
    }

    override func confirm() -> Bool {
        guard let offset else { return false }
        userDefaults.set(amountField.stringValue, forKey: Key.amount)
        userDefaults.set(unitControl.selectedSegment == 1, forKey: Key.usesFrames)
        userDefaults.set(frameRatePopUp.indexOfSelectedItem, forKey: Key.framesPerSecond)
        userDefaults.set(Self.selectedIndex(of: directionButtons) == 1, forKey: Key.isEarlier)
        userDefaults.set(Self.selectedIndex(of: edgeButtons), forKey: Key.edges)
        editor.shift(by: offset, changing: Self.edges[Self.selectedIndex(of: edgeButtons)], scope: scope)
        return true
    }

    @objc private func unitChanged(_ sender: NSSegmentedControl) {
        amountField.stringValue = sender.selectedSegment == 1 ? "0" : "0:00:00.00"
        update()
    }
}
