import Foundation

/// A spell checker that knows a few misspelled Latin-script words and their
/// corrections, so tests never touch the system's checker or the user's
/// dictionary.
final class FakeSpellChecker: SpellChecking {
    /// Misspelled words and their suggestions, best first.
    private let corrections: [String: [String]]
    private(set) var ignoredWords: Set<String> = []
    private(set) var learnedWords: Set<String> = []
    /// The language of the last check.
    private(set) var checkedLanguage: String?

    init(corrections: [String: [String]]) {
        self.corrections = corrections
    }

    func misspelledWords(in text: String, language: String?) -> [Range<String.Index>] {
        checkedLanguage = language
        return text.ranges(of: /[A-Za-z]+/).filter { range in
            let word = String(text[range])
            return corrections[word] != nil && !ignoredWords.contains(word) && !learnedWords.contains(word)
        }
    }

    func suggestions(forWordAt range: Range<String.Index>, in text: String, language: String?) -> [String] {
        corrections[String(text[range])] ?? []
    }

    func ignore(_ word: String) {
        ignoredWords.insert(word)
    }

    func learn(_ word: String) {
        learnedWords.insert(word)
    }

    func dictionaryName(forLanguage language: String?) -> String? {
        language == "en" ? "English" : nil
    }
}
