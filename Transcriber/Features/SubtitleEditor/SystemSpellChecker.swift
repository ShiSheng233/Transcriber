import AppKit

/// `SpellChecking` with the system's spell checker and the user's own
/// dictionary (words learned here are learned in every app).
///
/// macOS has no spelling dictionary for Chinese or Japanese, the subtitles'
/// usual languages: their lines are checked with the language detected for
/// each word instead, which still catches misspelled Latin-script words
/// (names, English) in mixed text and never marks the CJK text itself.
/// Languages with a dictionary (English or French after translation) are
/// checked with it, so short lines are not mistaken for another language.
final class SystemSpellChecker: SpellChecking {
    /// One document for the whole app: Ignore All in Check Spelling and
    /// Ignore Spelling in the edit box's menu hide the same words.
    static let documentTag = NSSpellChecker.uniqueSpellDocumentTag()

    private let checker = NSSpellChecker.shared

    func misspelledWords(in text: String, language: String?) -> [Range<String.Index>] {
        let dictionary = dictionaryLanguage(for: language)
        let length = (text as NSString).length
        var ranges: [Range<String.Index>] = []
        var location = 0
        while location < length {
            let found = checker.checkSpelling(
                of: text, startingAt: location, language: dictionary, wrap: false, inSpellDocumentWithTag: Self.documentTag, wordCount: nil
            )
            guard found.location != NSNotFound, found.length > 0, found.location >= location, let range = Range(found, in: text) else {
                break
            }
            ranges.append(range)
            location = NSMaxRange(found)
        }
        return ranges
    }

    func suggestions(forWordAt range: Range<String.Index>, in text: String, language: String?) -> [String] {
        checker.guesses(
            forWordRange: NSRange(range, in: text), in: text, language: dictionaryLanguage(for: language), inSpellDocumentWithTag: Self.documentTag
        ) ?? []
    }

    func ignore(_ word: String) {
        checker.ignoreWord(word, inSpellDocumentWithTag: Self.documentTag)
    }

    func learn(_ word: String) {
        checker.learnWord(word)
    }

    func dictionaryName(forLanguage language: String?) -> String? {
        dictionaryLanguage(for: language).flatMap { Locale.current.localizedString(forIdentifier: $0) }
    }

    /// The installed dictionary for `language` ("pt" finds "pt_BR"); nil,
    /// meaning detect each word's language, when there is none.
    private func dictionaryLanguage(for language: String?) -> String? {
        guard let language else { return nil }
        let available = checker.availableLanguages
        let identifier = language.replacingOccurrences(of: "-", with: "_")
        if available.contains(identifier) {
            return identifier
        }
        guard let code = Locale.Language(identifier: language).languageCode?.identifier else { return nil }
        return available.first { $0 == code } ?? available.first { $0.hasPrefix(code + "_") }
    }
}
