/// Speech segmentation parameters, named after the original `vad_parameters`.
///
/// Thresholds are stored as Python computes them (float64, e.g. `0.5 - 0.15`);
/// the segmenter rounds them to `Float` before comparing, see `SpeechSegmenter`.
public struct VADSettings: Hashable, Sendable, Codable {
    /// A frame at or above this probability starts or continues speech.
    public var threshold: Double
    /// A frame below this probability counts as silence; `nil` means
    /// `max(threshold - 0.15, 0.01)`, as in the original.
    public var negativeThreshold: Double?
    /// Speech shorter than this is dropped.
    public var minimumSpeechDuration: AudioTime
    /// Speech longer than this is cut; `nil` means no limit.
    public var maximumSpeechDuration: AudioTime?
    /// Silence must last this long to end speech.
    public var minimumSilenceDuration: AudioTime
    /// Added before and after each span, without overlapping its neighbors.
    public var speechPadding: AudioTime

    public init(
        threshold: Double,
        negativeThreshold: Double? = nil,
        minimumSpeechDuration: AudioTime,
        maximumSpeechDuration: AudioTime? = nil,
        minimumSilenceDuration: AudioTime,
        speechPadding: AudioTime
    ) {
        self.threshold = threshold
        self.negativeThreshold = negativeThreshold
        self.minimumSpeechDuration = minimumSpeechDuration
        self.maximumSpeechDuration = maximumSpeechDuration
        self.minimumSilenceDuration = minimumSilenceDuration
        self.speechPadding = speechPadding
    }

    public var resolvedNegativeThreshold: Double {
        negativeThreshold ?? max(threshold - 0.15, 0.01)
    }
}
