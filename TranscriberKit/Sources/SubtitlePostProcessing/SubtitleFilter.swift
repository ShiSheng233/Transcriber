import TranscriberCore

/// The optional line filters and fixes (`SubtitleFilterSettings`), in
/// WhisperJAV's order where it has them: vocal-sound lines go first, then
/// the text is evened out and repaired, invented outros and filler-only
/// lines go, repeats are merged, the content and reading-speed checks run on
/// what is left, and the timing is made readable last.
public enum SubtitleFilter {
    /// `audioDuration` is the length of the transcribed audio, for telling
    /// lines near its end.
    public static func apply(_ segments: [TimedText], settings: SubtitleFilterSettings, audioDuration: AudioTime) -> [TimedText] {
        var filtered = segments
        if settings.dropsNonverbalLines {
            filtered.removeAll { NonverbalLineFilter.isNonverbal($0.text) }
        }
        filtered = filtered.compactMap { segment in
            var line = segment
            if settings.normalizesText {
                line.text = JapaneseTextNormalizer.normalized(line.text)
            }
            if settings.shortensStretchedSounds {
                line.text = StretchedSoundShortener.shortened(line.text)
            }
            if settings.repairsLoopingLines {
                line.text = LineLoopRepair.repaired(line.text)
            }
            return line.text.pythonStripped.isEmpty ? nil : line
        }
        if settings.dropsFillerLines {
            filtered.removeAll { FillerLineFilter.isFillerOnly($0.text) }
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
        if settings.fixesTiming {
            filtered = SubtitleTimingFixer.fixed(filtered)
        }
        return filtered
    }
}
