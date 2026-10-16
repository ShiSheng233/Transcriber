import AppKit
import TranscriberCore

/// Adjust Timing, Aegisub's timing post-processor: lead-in and lead-out,
/// snapping to where the sound starts and ends, then closing small gaps.
/// Snapping needs the waveform, so it is only offered in timing mode.
final class TimingAdjustmentSheet: EditorSheet {
    private enum Key {
        static let prefix = "AdjustTiming"
    }

    private let editor: SubtitleEditorViewModel
    /// Where the sound starts and ends; `nil` until the waveform is loaded.
    private let soundSpans: () -> [SpeechSpan]?

    private lazy var leadInBox = checkbox(String(localized: "Lead-in"))
    private lazy var leadInField = numberField()
    private lazy var leadOutBox = checkbox(String(localized: "Lead-out"))
    private lazy var leadOutField = numberField()
    private lazy var snapBox = checkbox(String(localized: "Snap to sound"))
    private lazy var snapStartField = numberField()
    private lazy var snapEndField = numberField()
    private let snapNote = NSTextField(labelWithString: String(localized: "Turn on Timing Mode to analyze the audio first."))
    private lazy var continuousBox = checkbox(String(localized: "Close gaps shorter than"))
    private lazy var continuousField = numberField()
    private lazy var scopeButtons = radioButtons([String(localized: "Selected lines"), String(localized: "All lines")])

    private var options: [(box: NSButton, fields: [NSTextField], key: String, defaults: [Int?])] {
        let defaults = TimingPostProcessing.Settings.aegisub
        return [
            (leadInBox, [leadInField], "LeadIn", [defaults.leadIn?.milliseconds]),
            (leadOutBox, [leadOutField], "LeadOut", [defaults.leadOut?.milliseconds]),
            (snapBox, [snapStartField, snapEndField], "Snap", [defaults.startSnapDistance?.milliseconds, defaults.endSnapDistance?.milliseconds]),
            (continuousBox, [continuousField], "Continuous", [defaults.adjacentThreshold?.milliseconds]),
        ]
    }

    init(editor: SubtitleEditorViewModel, soundSpans: @escaping () -> [SpeechSpan]?) {
        self.editor = editor
        self.soundSpans = soundSpans
        super.init(title: String(localized: "Adjust Timing"), confirmTitle: String(localized: "Apply"))
        snapNote.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        snapNote.textColor = .secondaryLabelColor
        let milliseconds = { NSTextField(labelWithString: String(localized: "ms")) }
        for view in [
            row("", [leadInBox, leadInField, milliseconds()]),
            row("", [leadOutBox, leadOutField, milliseconds()]),
            row("", [snapBox, NSTextField(labelWithString: String(localized: "start within")), snapStartField,
                     NSTextField(labelWithString: String(localized: "end within")), snapEndField, milliseconds()]),
            row("", [snapNote]),
            row("", [continuousBox, continuousField, milliseconds()]),
            row(String(localized: "Lines:"), scopeButtons),
        ] {
            form.addArrangedSubview(view)
        }
        restore()
    }

    private func restore() {
        for option in options {
            let enabledKey = Key.prefix + option.key
            option.box.state = userDefaults.object(forKey: enabledKey) == nil || userDefaults.bool(forKey: enabledKey) ? .on : .off
            for (index, field) in option.fields.enumerated() {
                let key = Key.prefix + option.key + "\(index)"
                let stored = userDefaults.object(forKey: key) == nil ? option.defaults[index] ?? 0 : userDefaults.integer(forKey: key)
                field.integerValue = stored
            }
        }
    }

    override func begin(on window: NSWindow) {
        Self.select(editor.selection.isEmpty ? 1 : 0, in: scopeButtons)
        scopeButtons[0].isEnabled = !editor.selection.isEmpty
        super.begin(on: window)
    }

    private func milliseconds(_ field: NSTextField, if box: NSButton) -> AudioTime? {
        guard box.state == .on, box.isEnabled, let value = Int(field.stringValue), value >= 0 else { return nil }
        return AudioTime(milliseconds: value)
    }

    private var settings: TimingPostProcessing.Settings {
        TimingPostProcessing.Settings(
            leadIn: milliseconds(leadInField, if: leadInBox),
            leadOut: milliseconds(leadOutField, if: leadOutBox),
            adjacentThreshold: milliseconds(continuousField, if: continuousBox),
            adjacentBias: TimingPostProcessing.Settings.aegisub.adjacentBias,
            startSnapDistance: milliseconds(snapStartField, if: snapBox),
            endSnapDistance: milliseconds(snapEndField, if: snapBox)
        )
    }

    private var appliesToAllLines: Bool {
        Self.selectedIndex(of: scopeButtons) == 1
    }

    override func update() {
        let sound = soundSpans()
        snapBox.isEnabled = sound != nil
        snapNote.isHidden = sound != nil
        for option in options {
            option.fields.forEach { $0.isEnabled = option.box.state == .on && option.box.isEnabled }
        }
        let changed = editor.postProcessingChangeCount(settings, allLines: appliesToAllLines, sound: sound ?? [])
        summaryLabel.stringValue = String(localized: "Changes \(changed) of \(editor.lines.count) lines")
        confirmButton.isEnabled = changed > 0
    }

    override func confirm() -> Bool {
        for option in options {
            userDefaults.set(option.box.state == .on, forKey: Key.prefix + option.key)
            for (index, field) in option.fields.enumerated() {
                userDefaults.set(field.integerValue, forKey: Key.prefix + option.key + "\(index)")
            }
        }
        editor.postProcessTiming(settings, allLines: appliesToAllLines, sound: soundSpans() ?? [])
        return true
    }
}
