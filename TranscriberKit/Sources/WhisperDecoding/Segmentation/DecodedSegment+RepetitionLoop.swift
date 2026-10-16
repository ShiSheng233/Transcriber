import TranscriberCore

extension DecodedSegment {
    /// Whether its window's text is still repetitive after the temperature
    /// fallback. faster-whisper keeps the best failed result when every
    /// temperature fails (`below_cr_threshold_results or all_results`), so
    /// repetition loops reach the subtitles (WhisperJAV, docs/CHANGELOG_v1.9.2.md).
    ///
    /// WhisperJAV also drops text below the average log probability
    /// threshold. That is left out: on the parity sample it removed a correct
    /// ChickenRice line the original keeps, since a translating model's log
    /// probabilities run lower than the transcription the threshold was set for.
    public func isRepetitionLoop(_ settings: DecodingSettings) -> Bool {
        compressionRatio > settings.compressionRatioThreshold
    }
}
