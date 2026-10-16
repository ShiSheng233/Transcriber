import TranscriberCore

/// Recognizes lines that are vocal sounds rather than speech, after
/// WhisperJAV's `SegmentFilterHelper._looks_nonverbal`
/// (whisperjav/modules/segment_filters.py).
///
/// Differences from WhisperJAV, for the Chinese output of ChickenRice and the
/// "…" lines of anime-whisper:
/// - A keyword ("moan", "喘ぎ") only counts in a bracketed descriptor such as
///   "[喘ぎ声]" or as the whole line; WhisperJAV matches it anywhere, which
///   would drop Chinese sentences containing 喘.
/// - Full-width brackets count as descriptor brackets.
/// - ♡ and ♥ are ignored like punctuation, and common Chinese interjections
///   count as vocal sounds next to the kana.
public enum NonverbalLineFilter {
    private static let keywords: Set<String> = [
        "music", "applause", "laugh", "laughs", "laughter", "sfx", "fx", "noise", "silence", "ambient",
        "moan", "moans", "moaning", "groan", "groans", "sigh", "sighs", "breath", "breathing",
        "喘", "喘ぎ", "喘ぎ声", "うめき", "うめき声",
    ]
    private static let noteCharacters: Set<Character> = ["♪", "♫"]
    /// Ignored when deciding whether a line is only vocal sounds.
    private static let ignoredCharacters = Set("!！?？。、,.・~〜～ー… 　♡♥")
    private static let descriptorBrackets = Set("[](){}<>（）【】")
    /// Romanized moans ("ah", "mmm"), kana used for vocal sounds, and Chinese interjections.
    private static let vocalCharacters = Set("ahmnou" + "ぁあァアんンっッふフぅゥうウおオえエはハほホ" + "啊嗯哈呃唔哦噢呜")
    private static let maximumVocalLength = 6

    public static func isNonverbal(_ text: String) -> Bool {
        let stripped = text.pythonStripped
        guard !stripped.isEmpty else {
            return false
        }
        if stripped.allSatisfy({ noteCharacters.contains($0) || ignoredCharacters.contains($0) }) {
            return true
        }
        let lowered = stripped.lowercased()
        let descriptor = String(lowered.drop(while: descriptorBrackets.contains).reversed().drop(while: descriptorBrackets.contains).reversed()).pythonStripped
        guard !descriptor.isEmpty else {
            return false
        }
        let isBracketed = descriptor.count < lowered.count
        if keywords.contains(descriptor) || (isBracketed && keywords.contains(where: descriptor.contains)) {
            return true
        }
        let sounds = descriptor.filter { !ignoredCharacters.contains($0) }
        return !sounds.isEmpty && sounds.count <= maximumVocalLength && sounds.allSatisfy(vocalCharacters.contains)
    }
}
