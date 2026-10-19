import AppKit

/// The edit box's text view. Its spelling marks come from the editor's
/// checker (see `SubtitleEditorView`), in the app's one spelling document,
/// and its menu's Check Spelling While Typing is the editor's remembered
/// choice rather than this view's own.
final class SubtitleTextView: NSTextView {
    override var spellCheckerDocumentTag: Int {
        SystemSpellChecker.documentTag
    }

    override func toggleContinuousSpellChecking(_ sender: Any?) {
        NSApp.sendAction(#selector(SubtitleEditorCommands.toggleSpellingWhileTyping(_:)), to: nil, from: sender)
    }
}
