import Foundation

/// Finds names and terms written in more than one way across a file, so
/// they can be unified in one step.
///
/// Only differences that can be told apart without a dictionary count:
/// full- and half-width forms, letter case, hiragana against katakana,
/// small against large kana, "～"/"〜" against "ー", and middle dots. A
/// kanji spelling against a kana one needs a reading, so it is never found.
///
/// Text is cut into runs of one script (katakana, hiragana, kanji, Latin
/// letters and digits, everything else). A term is matched only on whole
/// runs, so a name never matches inside a longer word. Candidates are
/// katakana and Latin runs at least `minimumTermLength` long that occur in
/// two or more spellings; hiragana runs only count as spellings of those.
/// Glossary terms (either side of an entry) are matched at any length, and
/// their own spelling is the one to keep.
public enum TermVariants {
    /// Shorter katakana or Latin runs are too often ordinary words.
    public static let minimumTermLength = 3

    public struct Spelling: Hashable, Sendable {
        public let text: String
        /// Occurrences in the lines; 0 for a glossary spelling not used.
        public let count: Int
    }

    public struct Group: Hashable, Sendable {
        /// What every spelling folds to; identifies the group.
        public let key: String
        /// Most frequent first.
        public let spellings: [Spelling]
        /// The glossary's spelling, when the term is in the glossary.
        public let glossarySpelling: String?

        /// The glossary's spelling, or else the most frequent one.
        public var suggestedSpelling: String {
            glossarySpelling ?? spellings.first?.text ?? key
        }

        public var occurrenceCount: Int {
            spellings.reduce(0) { $0 + $1.count }
        }
    }

    /// Groups of spellings of one term, most frequent term first.
    /// - Parameter glossaryTerms: names and terms with a known spelling.
    public static func groups(in texts: [String], glossaryTerms: [String] = [], minimumLength: Int = minimumTermLength) -> [Group] {
        let tokenized = texts.map(tokens(of:))
        var glossarySpellingByKey: [String: String] = [:]
        for term in glossaryTerms {
            let key = fold(term.trimmingCharacters(in: .whitespaces))
            if !key.isEmpty, glossarySpellingByKey[key] == nil {
                glossarySpellingByKey[key] = term.trimmingCharacters(in: .whitespaces)
            }
        }
        var keys = Set(glossarySpellingByKey.keys)
        for token in tokenized.joined() where token.script.startsTerm && token.folded.count >= minimumLength {
            keys.insert(token.folded)
        }

        var countsByKey: [String: [String: Int]] = [:]
        for lineTokens in tokenized {
            for occurrence in occurrences(of: keys, in: lineTokens) {
                countsByKey[occurrence.key, default: [:]][occurrence.spelling, default: 0] += 1
            }
        }

        let groups = countsByKey.compactMap { key, counts -> Group? in
            var counts = counts
            let glossarySpelling = glossarySpellingByKey[key]
            if let glossarySpelling {
                guard counts.keys.contains(where: { $0 != glossarySpelling }) else { return nil }
                if counts[glossarySpelling] == nil {
                    counts[glossarySpelling] = 0  // listed even when unused, to be chosen
                }
            } else if counts.count < 2 {
                return nil
            }
            let spellings = counts.map { Spelling(text: $0.key, count: $0.value) }
                .sorted { ($0.count, tieRank($1.text), $1.text) > ($1.count, tieRank($0.text), $0.text) }
            return Group(key: key, spellings: spellings, glossarySpelling: glossarySpelling)
        }
        return groups.sorted { ($0.occurrenceCount, $1.key) > ($1.occurrenceCount, $0.key) }
    }

    /// Each text with every spelling of the chosen terms replaced by the one
    /// to keep, matched the same way as `groups`.
    /// - Parameter spellings: the spelling to keep by group key.
    public static func unifying(_ texts: [String], to spellings: [String: String]) -> [String] {
        let keys = Set(spellings.keys)
        guard !keys.isEmpty else { return texts }
        return texts.map { text in
            let lineTokens = tokens(of: text)
            let found = occurrences(of: keys, in: lineTokens)
            guard !found.isEmpty else { return text }
            var result = ""
            var next = 0
            for occurrence in found {
                result += lineTokens[next..<occurrence.tokens.lowerBound].map(\.text).joined()
                result += spellings[occurrence.key] ?? occurrence.spelling
                next = occurrence.tokens.upperBound
            }
            result += lineTokens[next...].map(\.text).joined()
            return result
        }
    }

    // MARK: Folding

    private enum Script {
        case katakana
        case hiragana
        case kanji
        case latin
        case other

        /// Runs of these can be candidates on their own.
        var startsTerm: Bool {
            self == .katakana || self == .latin
        }
    }

    private struct Token {
        let text: String
        let folded: String
        let script: Script
    }

    private struct Occurrence {
        let key: String
        let spelling: String
        let tokens: Range<Int>
    }

    private static let katakana: [ClosedRange<UInt32>] = [0x30A1...0x30FA, 0x30FD...0x30FF, 0x31F0...0x31FF, 0xFF66...0xFF9F]
    private static let hiragana: ClosedRange<UInt32> = 0x3041...0x309F
    private static let kanji: [ClosedRange<UInt32>] = [0x3400...0x4DBF, 0x4E00...0x9FFF, 0xF900...0xFAFF, 0x20000...0x3134F, 0x3005...0x3005]
    private static let latin: [ClosedRange<UInt32>] = [
        0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0xFF10...0xFF19, 0xFF21...0xFF3A, 0xFF41...0xFF5A,
    ]
    /// Long vowel marks (and the tildes written for them); they continue the kana run before them.
    private static let longVowelMarks: Set<UInt32> = [0x30FC, 0xFF70, 0xFF5E, 0x301C, 0x7E]
    private static let longVowelMark: Unicode.Scalar = "ー"
    /// Middle dots between the parts of a name; they continue a katakana run and fold away.
    private static let middleDots: Set<UInt32> = [0x30FB, 0xFF65, 0xB7]
    /// Hiragana sit this far below the same katakana.
    private static let hiraganaToKatakanaOffset: UInt32 = 0x60
    private static let largeKana: [Unicode.Scalar: Unicode.Scalar] = [
        "ァ": "ア", "ィ": "イ", "ゥ": "ウ", "ェ": "エ", "ォ": "オ", "ッ": "ツ", "ャ": "ヤ", "ュ": "ユ", "ョ": "ヨ", "ヮ": "ワ", "ヵ": "カ", "ヶ": "ケ",
    ]

    private static func contains(_ ranges: [ClosedRange<UInt32>], _ value: UInt32) -> Bool {
        ranges.contains { $0.contains(value) }
    }

    private static func script(of character: Character) -> Script {
        guard let value = character.unicodeScalars.first?.value else { return .other }
        if contains(katakana, value) { return .katakana }
        if hiragana.contains(value) { return .hiragana }
        if contains(kanji, value) { return .kanji }
        if contains(latin, value) { return .latin }
        return .other
    }

    /// Runs of one script; long vowel marks join the kana run before them,
    /// middle dots the katakana run before them.
    private static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var run = ""
        var runScript = Script.other
        func flush() {
            guard !run.isEmpty else { return }
            tokens.append(Token(text: run, folded: fold(run), script: runScript))
            run = ""
        }
        for character in text {
            let value = character.unicodeScalars.first?.value ?? 0
            var script = script(of: character)
            if longVowelMarks.contains(value), runScript == .katakana || runScript == .hiragana {
                script = runScript
            } else if middleDots.contains(value), runScript == .katakana {
                script = .katakana
            } else if longVowelMarks.contains(value) || middleDots.contains(value) {
                script = .other
            }
            if script != runScript || script == .other {
                flush()
                runScript = script
            }
            run.append(character)
        }
        flush()
        return tokens
    }

    /// Between equally frequent spellings, full-width katakana or plain
    /// Latin (0) come before hiragana and half-width forms (1).
    private static func tieRank(_ text: String) -> Int {
        let isStandardWidth = text == text.precomposedStringWithCompatibilityMapping
        let startsTerm = text.first.map { script(of: $0).startsTerm } ?? false
        return isStandardWidth && startsTerm ? 0 : 1
    }

    /// The spelling every variant of a term shares.
    static func fold(_ text: String) -> String {
        var folded = String.UnicodeScalarView()
        for scalar in text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars {
            if middleDots.contains(scalar.value) {
                continue
            }
            if longVowelMarks.contains(scalar.value) {
                folded.append(longVowelMark)
                continue
            }
            var kana = scalar
            if hiragana.contains(scalar.value), let katakana = Unicode.Scalar(scalar.value + hiraganaToKatakanaOffset), (0x30A1...0x30F6).contains(katakana.value) {
                kana = katakana
            }
            folded.append(largeKana[kana] ?? kana)
        }
        return String(folded)
    }

    /// Where any of `keys` occurs on whole runs, the longest match first,
    /// left to right without overlaps.
    private static func occurrences(of keys: Set<String>, in tokens: [Token]) -> [Occurrence] {
        let longestKey = keys.map(\.count).max() ?? 0
        var found: [Occurrence] = []
        var start = 0
        while start < tokens.count {
            guard tokens[start].script != .other else {
                start += 1
                continue
            }
            var joined = ""
            var match: (key: String, end: Int)?
            for end in start..<tokens.count {
                joined += tokens[end].folded
                if joined.count > longestKey { break }
                if keys.contains(joined), tokens[end].script != .other {
                    match = (joined, end + 1)
                }
            }
            if let match {
                let spelling = tokens[start..<match.end].map(\.text).joined()
                found.append(Occurrence(key: match.key, spelling: spelling, tokens: start..<match.end))
                start = match.end
            } else {
                start += 1
            }
        }
        return found
    }
}
