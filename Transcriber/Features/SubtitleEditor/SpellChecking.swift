import Foundation

/// The spell checker the editor asks, behind a protocol so the view model
/// stays free of AppKit; the app's is `SystemSpellChecker`.
///
/// `language` is the subtitles' language code (see `SpellingLanguage`), nil
/// when it is unknown; the checker picks the dictionary for it.
protocol SpellChecking: AnyObject {
    /// The misspelled words in `text`, in order.
    func misspelledWords(in text: String, language: String?) -> [Range<String.Index>]
    /// Replacements for the misspelled word at `range` in `text`, best first.
    func suggestions(forWordAt range: Range<String.Index>, in text: String, language: String?) -> [String]
    /// Stops reporting `word` until the app quits (Ignore All).
    func ignore(_ word: String)
    /// Adds `word` to the user's dictionary, shared with other apps.
    func learn(_ word: String)
    /// The dictionary's language as the user reads it; nil when each
    /// word's language is detected instead.
    func dictionaryName(forLanguage language: String?) -> String?
}
