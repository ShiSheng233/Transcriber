import Foundation
import TranscriberCore

/// Spell checking, as in Aegisub: the edit box's marks as text is typed, and
/// Check Spelling, which walks once through the file from the active line,
/// one misspelled word at a time. Each step returns the next word (nil when
/// the walk is done) and selects its line; corrections are undo steps.
extension SubtitleEditorViewModel {
    /// A misspelled word in its line, for Check Spelling.
    struct Misspelling: Equatable {
        let lineIndex: Int
        /// The line as it was checked; `range` is in this text.
        let lineText: String
        let range: Range<String.Index>
        let suggestions: [String]
        /// Lines still to check after this one before the walk ends.
        let remainingLineCount: Int

        var word: String {
            String(lineText[range])
        }
    }

    var canCheckSpelling: Bool {
        spellChecker != nil && isEditable && !lines.isEmpty
    }

    /// For the edit box's marks; empty while checking as typed is off.
    func misspelledWords(in text: String) -> [Range<String.Index>] {
        guard checksSpellingWhileTyping, let spellChecker else { return [] }
        return spellChecker.misspelledWords(in: text, language: spellingLanguage)
    }

    /// The dictionary Check Spelling uses, nil when each word's language is detected.
    var spellingDictionaryName: String? {
        spellChecker?.dictionaryName(forLanguage: spellingLanguage)
    }

    /// Starts at the active line (the first without one) and goes once round.
    func firstMisspelling() -> Misspelling? {
        guard canCheckSpelling else { return nil }
        return nextMisspelling(fromLine: activeIndex ?? 0, atUTF16Offset: 0, remainingLineCount: lines.count - 1)
    }

    /// Leaves the word as it is this time (Ignore).
    func skipMisspelling(_ misspelling: Misspelling) -> Misspelling? {
        let end = misspelling.range.upperBound.utf16Offset(in: misspelling.lineText)
        return nextMisspelling(after: misspelling, atUTF16Offset: isCurrent(misspelling) ? end : 0)
    }

    /// Leaves the word as it is everywhere until the app quits (Ignore All).
    func ignoreMisspellingEverywhere(_ misspelling: Misspelling) -> Misspelling? {
        spellChecker?.ignore(misspelling.word)
        return skipMisspelling(misspelling)
    }

    /// Adds the word to the user's dictionary (Add to Dictionary).
    func learnMisspelling(_ misspelling: Misspelling) -> Misspelling? {
        spellChecker?.learn(misspelling.word)
        return skipMisspelling(misspelling)
    }

    /// Replaces this occurrence as one undo step, then goes on after it. A
    /// line changed meanwhile is left alone and checked again.
    func correctMisspelling(_ misspelling: Misspelling, to replacement: String) -> Misspelling? {
        guard isEditable, isCurrent(misspelling) else {
            return nextMisspelling(after: misspelling, atUTF16Offset: 0)
        }
        var updated = lines
        updated[misspelling.lineIndex].text = misspelling.lineText.replacingCharacters(in: misspelling.range, with: replacement)
        replace(lines: updated, selection: [misspelling.lineIndex], actionName: String(localized: "Correct Spelling"))
        let replacementEnd = misspelling.range.lowerBound.utf16Offset(in: misspelling.lineText) + replacement.utf16.count
        return nextMisspelling(after: misspelling, atUTF16Offset: replacementEnd)
    }

    /// Replaces every occurrence of the misspelled word in every line, as
    /// one undo step, then goes on in this line.
    /// - Returns: how many lines changed, and the next word.
    func correctMisspellingEverywhere(_ misspelling: Misspelling, to replacement: String) -> (changedLineCount: Int, next: Misspelling?) {
        guard isEditable, let spellChecker, isCurrent(misspelling) else {
            return (0, nextMisspelling(after: misspelling, atUTF16Offset: 0))
        }
        let word = misspelling.word
        var updated = lines
        var changedLineCount = 0
        for index in updated.indices {
            var text = updated[index].text
            let ranges = spellChecker.misspelledWords(in: text, language: spellingLanguage).filter { text[$0] == word }
            guard !ranges.isEmpty else { continue }
            // Backwards, so the earlier ranges stay valid.
            for range in ranges.reversed() {
                text.replaceSubrange(range, with: replacement)
            }
            updated[index].text = text
            changedLineCount += 1
        }
        guard changedLineCount > 0 else {
            return (0, skipMisspelling(misspelling))  // no longer reported (ignored meanwhile)
        }
        replace(lines: updated, selection: [misspelling.lineIndex], actionName: String(localized: "Correct Spelling"))
        // Earlier words in the line may have changed too: its start is checked again.
        return (changedLineCount, nextMisspelling(after: misspelling, atUTF16Offset: 0))
    }

    // MARK: Private

    /// The line has not changed since the word was found.
    private func isCurrent(_ misspelling: Misspelling) -> Bool {
        lines.indices.contains(misspelling.lineIndex) && lines[misspelling.lineIndex].text == misspelling.lineText
    }

    /// Goes on in the word's line (the last one, if lines were deleted).
    private func nextMisspelling(after misspelling: Misspelling, atUTF16Offset offset: Int) -> Misspelling? {
        guard canCheckSpelling else { return nil }
        let lineIndex = min(misspelling.lineIndex, lines.count - 1)
        return nextMisspelling(fromLine: lineIndex, atUTF16Offset: offset, remainingLineCount: misspelling.remainingLineCount)
    }

    /// The first misspelled word from `offset` on in the line, else in the
    /// lines after it, wrapping to the first.
    private func nextMisspelling(fromLine startIndex: Int, atUTF16Offset offset: Int, remainingLineCount: Int) -> Misspelling? {
        guard let spellChecker else { return nil }
        var lineIndex = startIndex
        var offset = offset
        var remainingLineCount = remainingLineCount
        while true {
            let text = lines[lineIndex].text
            let ranges = spellChecker.misspelledWords(in: text, language: spellingLanguage)
            if let range = ranges.first(where: { $0.lowerBound.utf16Offset(in: text) >= offset }) {
                select([lineIndex])
                return Misspelling(
                    lineIndex: lineIndex, lineText: text, range: range,
                    suggestions: spellChecker.suggestions(forWordAt: range, in: text, language: spellingLanguage),
                    remainingLineCount: remainingLineCount
                )
            }
            guard remainingLineCount > 0 else { return nil }
            remainingLineCount -= 1
            lineIndex = (lineIndex + 1) % lines.count
            offset = 0
        }
    }
}
