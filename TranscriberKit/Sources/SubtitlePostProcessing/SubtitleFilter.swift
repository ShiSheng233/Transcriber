import TranscriberCore

/// The optional line filters (`SubtitleFilterSettings`), in WhisperJAV's
/// order: vocal-sound lines go at recognition, then repeats are merged, then
/// the content and reading-speed checks run on what is left.
public enum SubtitleFilter {
    public static func apply(_ segments: [TimedText], settings: SubtitleFilterSettings) -> [TimedText] {
        var filtered = segments
        if settings.dropsNonverbalLines {
            filtered.removeAll { NonverbalLineFilter.isNonverbal($0.text) }
        }
        if settings.mergesRepeatedLines {
            filtered = RepeatedLineMerger.merged(filtered)
        }
        if settings.dropsImplausibleReadingSpeed {
            filtered = ReadingSpeedFilter.filtered(filtered)
        }
        return filtered
    }
}
