import TranscriberCore

/// The optional line filters (`SubtitleFilterSettings`), in WhisperJAV's
/// order: vocal-sound lines go at recognition, then invented outros and
/// credits, then repeats are merged, then the content and reading-speed
/// checks run on what is left.
public enum SubtitleFilter {
    /// `audioDuration` is the length of the transcribed audio, for telling
    /// lines near its end.
    public static func apply(_ segments: [TimedText], settings: SubtitleFilterSettings, audioDuration: AudioTime) -> [TimedText] {
        var filtered = segments
        if settings.dropsNonverbalLines {
            filtered.removeAll { NonverbalLineFilter.isNonverbal($0.text) }
        }
        if settings.dropsHallucinatedPhrases {
            filtered = HallucinationPhraseFilter.filtered(filtered, audioDuration: audioDuration)
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
