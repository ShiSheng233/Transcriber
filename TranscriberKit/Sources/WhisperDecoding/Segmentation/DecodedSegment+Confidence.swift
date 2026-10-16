import TranscriberCore

extension DecodedSegment {
    /// The segment's decoding numbers, judged by the model's thresholds.
    public func confidence(settings: DecodingSettings) -> RecognitionConfidence {
        RecognitionConfidence(
            averageLogProbability: averageLogProbability,
            noSpeechProbability: Double(noSpeechProbability),
            compressionRatio: compressionRatio,
            settings: settings
        )
    }
}
