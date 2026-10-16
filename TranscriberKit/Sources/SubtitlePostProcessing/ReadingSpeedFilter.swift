import TranscriberCore

/// Drops lines whose timing cannot be right, after WhisperJAV's sanitizer
/// (whisperjav/modules/subtitle_sanitizer.py, constants in
/// whisperjav/config/sanitization_constants.py):
/// - no letters or digits left (`_HAS_LINGUISTIC_CONTENT`), e.g. "！？";
/// - faster than 30 characters per second: text squeezed into a short span;
/// - at most 4 characters at under 1 per second: a word stretched over
///   silence ("息子" over 3.7 s).
public enum ReadingSpeedFilter {
    /// `MAX_SAFE_CPS`.
    static let maximumCharactersPerSecond = 30.0
    /// `MIN_SAFE_CPS`.
    static let minimumCharactersPerSecond = 1.0
    /// Only text this short is checked against the minimum speed.
    static let shortTextMaximumLength = 4

    public static func filtered(_ segments: [TimedText]) -> [TimedText] {
        segments.filter { hasLinguisticContent($0.text) && hasPlausibleSpeed($0) }
    }

    static func hasLinguisticContent(_ text: String) -> Bool {
        text.unicodeScalars.contains { $0.properties.isAlphabetic || $0.properties.numericType != nil }
    }

    private static func hasPlausibleSpeed(_ segment: TimedText) -> Bool {
        // Python's len(): code points, without line breaks.
        let length = segment.text.replacingOccurrences(of: "\n", with: "").pythonStripped.unicodeScalars.count
        let durationSeconds = Double((segment.end - segment.start).milliseconds) / 1_000
        guard length > 0, durationSeconds > 0 else {
            return true
        }
        let charactersPerSecond = Double(length) / durationSeconds
        if charactersPerSecond > maximumCharactersPerSecond {
            return false
        }
        return !(length <= shortTextMaximumLength && charactersPerSecond < minimumCharactersPerSecond)
    }
}
