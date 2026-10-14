/// Whisper decoding parameters, named after faster-whisper's `transcribe()` options.
public struct DecodingSettings: Hashable, Sendable, Codable {
    public var task: TranscriptionTask
    public var languageCode: String
    /// Tried in order until a result passes the quality checks.
    public var temperatures: [Float]
    /// Results whose text compresses better than this (zlib) are repetitive.
    public var compressionRatioThreshold: Double
    /// Results with a lower average log probability are retried.
    public var logProbabilityThreshold: Double
    /// With a low average log probability, a window above this is silence.
    public var noSpeechThreshold: Double
    /// Hypotheses sampled per window when the temperature is above zero.
    public var bestOf: Int
    public var repetitionPenalty: Float
    /// `suppress_blank`: the first token may not be a space or end of text.
    public var suppressesBlankStart: Bool
    /// The first timestamp may not be later than this.
    public var maximumInitialTimestampSeconds: Double
    /// Tokens generated per window at most (`min(max_length / 2, max_length - prompt)`).
    public var maximumGeneratedTokenCount: Int

    public init(
        task: TranscriptionTask,
        languageCode: String,
        temperatures: [Float],
        compressionRatioThreshold: Double,
        logProbabilityThreshold: Double,
        noSpeechThreshold: Double,
        bestOf: Int,
        repetitionPenalty: Float,
        suppressesBlankStart: Bool,
        maximumInitialTimestampSeconds: Double,
        maximumGeneratedTokenCount: Int
    ) {
        self.task = task
        self.languageCode = languageCode
        self.temperatures = temperatures
        self.compressionRatioThreshold = compressionRatioThreshold
        self.logProbabilityThreshold = logProbabilityThreshold
        self.noSpeechThreshold = noSpeechThreshold
        self.bestOf = bestOf
        self.repetitionPenalty = repetitionPenalty
        self.suppressesBlankStart = suppressesBlankStart
        self.maximumInitialTimestampSeconds = maximumInitialTimestampSeconds
        self.maximumGeneratedTokenCount = maximumGeneratedTokenCount
    }

    /// `int(round(max_initial_timestamp / time_precision))` with 20 ms steps.
    public var maximumInitialTimestampIndex: Int {
        Int((maximumInitialTimestampSeconds / 0.02).rounded(.toNearestOrEven))
    }
}
