/// How sure the speech model was about a line, from the decoding it came
/// from. Kept so doubtful lines can be found, retranscribed or sent to the
/// language model; it never changes what the pipeline outputs.
public struct RecognitionConfidence: Hashable, Sendable, Codable {
    /// Mean log probability of the decoded tokens (faster-whisper `avg_logprob`).
    public var averageLogProbability: Double
    /// Probability that the window held no speech (`no_speech_prob`).
    public var noSpeechProbability: Double
    /// gzip compression ratio of the window's text; high means repetitive.
    public var compressionRatio: Double
    /// Whisper's own checks still failed at the last temperature: the text
    /// was too repetitive or too unlikely, and faster-whisper kept the best
    /// attempt anyway.
    public var isDoubtful: Bool

    public init(averageLogProbability: Double, noSpeechProbability: Double, compressionRatio: Double, isDoubtful: Bool) {
        self.averageLogProbability = averageLogProbability
        self.noSpeechProbability = noSpeechProbability
        self.compressionRatio = compressionRatio
        self.isDoubtful = isDoubtful
    }

    /// The decoding's numbers judged by the model's fallback thresholds.
    public init(averageLogProbability: Double, noSpeechProbability: Double, compressionRatio: Double, settings: DecodingSettings) {
        self.init(
            averageLogProbability: averageLogProbability,
            noSpeechProbability: noSpeechProbability,
            compressionRatio: compressionRatio,
            isDoubtful: compressionRatio > settings.compressionRatioThreshold
                || averageLogProbability < settings.logProbabilityThreshold
        )
    }

    /// For a line made of several: the least confident value of each.
    public func combined(with other: RecognitionConfidence) -> RecognitionConfidence {
        RecognitionConfidence(
            averageLogProbability: min(averageLogProbability, other.averageLogProbability),
            noSpeechProbability: max(noSpeechProbability, other.noSpeechProbability),
            compressionRatio: max(compressionRatio, other.compressionRatio),
            isDoubtful: isDoubtful || other.isDoubtful
        )
    }
}

extension Optional where Wrapped == RecognitionConfidence {
    /// Combines two lines' confidences; a line without one adds nothing.
    public func combined(with other: RecognitionConfidence?) -> RecognitionConfidence? {
        switch (self, other) {
        case let (first?, second?): first.combined(with: second)
        case let (first?, nil): first
        case let (nil, second): second
        }
    }
}
