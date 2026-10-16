/// A piece of transcribed or translated text with its time range.
///
/// The original pipeline's `Segment` (start/end in milliseconds, text).
public struct TimedText: Hashable, Sendable, Codable {
    public var start: AudioTime
    public var end: AudioTime
    public var text: String
    /// How sure the speech model was; `nil` for lines it did not make
    /// (read from a file, typed, or edited by hand).
    public var confidence: RecognitionConfidence?

    public init(start: AudioTime, end: AudioTime, text: String, confidence: RecognitionConfidence? = nil) {
        self.start = start
        self.end = end
        self.text = text
        self.confidence = confidence
    }
}
