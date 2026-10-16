import AppKit
import TranscriberCore

/// Aegisub's Select Lines, for finding what needs fixing: fast lines, very
/// short or long ones, overlaps, matching or empty text. The selection can
/// then be retimed, retranscribed or retranslated together. Not an undo step.
final class SelectLinesSheet: EditorSheet {
    private enum Key {
        static let prefix = "SelectLines"
    }

    private static let modes: [SubtitleSelection.Mode] = [.replace, .add, .intersect, .subtract]

    private let editor: SubtitleEditorViewModel
    private lazy var speedBox = checkbox(String(localized: "Faster than"))
    private lazy var speedField = numberField(width: 48)
    private lazy var shortBox = checkbox(String(localized: "Shorter than"))
    private lazy var shortField = numberField()
    private lazy var longBox = checkbox(String(localized: "Longer than"))
    private lazy var longField = numberField()
    private lazy var overlapBox = checkbox(String(localized: "Overlapping another line"))
    private lazy var textBox = checkbox(String(localized: "Text matches"))
    private lazy var textField = numberField(width: 160)
    private lazy var regexBox = checkbox(String(localized: "Regular expression"))
    private lazy var matchCaseBox = checkbox(String(localized: "Match case"))
    private lazy var emptyBox = checkbox(String(localized: "Empty text"))
    private lazy var combineButtons = radioButtons([String(localized: "All criteria"), String(localized: "Any criterion")])
    private lazy var modeButtons = radioButtons([
        String(localized: "Replace"), String(localized: "Add"), String(localized: "Intersect"), String(localized: "Subtract"),
    ])

    init(editor: SubtitleEditorViewModel) {
        self.editor = editor
        super.init(title: String(localized: "Select Lines"), confirmTitle: String(localized: "Select"))
        textField.alignment = .natural
        for view in [
            row("", [speedBox, speedField, NSTextField(labelWithString: String(localized: "characters per second"))]),
            row("", [shortBox, shortField, NSTextField(labelWithString: String(localized: "ms"))]),
            row("", [longBox, longField, NSTextField(labelWithString: String(localized: "ms"))]),
            row("", [overlapBox]),
            row("", [textBox, textField]),
            row("", [regexBox, matchCaseBox]),
            row("", [emptyBox]),
            row(String(localized: "Match:"), combineButtons),
            row(String(localized: "Selection:"), modeButtons),
        ] {
            form.addArrangedSubview(view)
        }
        restore()
    }

    private var boxes: [(NSButton, String)] {
        [(speedBox, "Speed"), (shortBox, "Short"), (longBox, "Long"), (overlapBox, "Overlap"), (textBox, "Text"),
         (regexBox, "Regex"), (matchCaseBox, "MatchCase"), (emptyBox, "Empty")]
    }

    private var fields: [(NSTextField, String, String)] {
        [(speedField, "SpeedValue", "15"), (shortField, "ShortValue", "500"), (longField, "LongValue", "10000"), (textField, "TextValue", "")]
    }

    private func restore() {
        for (box, key) in boxes {
            box.state = userDefaults.bool(forKey: Key.prefix + key) ? .on : .off
        }
        for (field, key, fallback) in fields {
            field.stringValue = userDefaults.string(forKey: Key.prefix + key) ?? fallback
        }
        Self.select(userDefaults.integer(forKey: Key.prefix + "Combine"), in: combineButtons)
        Self.select(0, in: modeButtons)
    }

    private var criteria: [SubtitleEditorViewModel.LineCriterion] {
        var criteria: [SubtitleEditorViewModel.LineCriterion] = []
        if speedBox.state == .on, let limit = Double(speedField.stringValue) {
            criteria.append(.readingSpeedAbove(limit))
        }
        if shortBox.state == .on, let milliseconds = Int(shortField.stringValue) {
            criteria.append(.durationBelow(AudioTime(milliseconds: milliseconds)))
        }
        if longBox.state == .on, let milliseconds = Int(longField.stringValue) {
            criteria.append(.durationAbove(AudioTime(milliseconds: milliseconds)))
        }
        if overlapBox.state == .on {
            criteria.append(.overlapping)
        }
        if textBox.state == .on {
            let options = SubtitleEditorViewModel.SearchOptions(matchesCase: matchCaseBox.state == .on, usesRegularExpression: regexBox.state == .on)
            criteria.append(.text(textField.stringValue, options))
        }
        if emptyBox.state == .on {
            criteria.append(.emptyText)
        }
        return criteria
    }

    private var matches: [Int] {
        editor.lines(matching: criteria, requiresAll: Self.selectedIndex(of: combineButtons) == 0)
    }

    override func update() {
        let count = matches.count
        summaryLabel.stringValue = criteria.isEmpty ? "" : String(localized: "\(count) lines match")
        confirmButton.isEnabled = count > 0
    }

    override func confirm() -> Bool {
        let matches = matches
        guard !matches.isEmpty else {
            NSSound.beep()
            return false
        }
        for (box, key) in boxes {
            userDefaults.set(box.state == .on, forKey: Key.prefix + key)
        }
        for (field, key, _) in fields {
            userDefaults.set(field.stringValue, forKey: Key.prefix + key)
        }
        userDefaults.set(Self.selectedIndex(of: combineButtons), forKey: Key.prefix + "Combine")
        editor.select(matches, mode: Self.modes[Self.selectedIndex(of: modeButtons)])
        return true
    }
}
