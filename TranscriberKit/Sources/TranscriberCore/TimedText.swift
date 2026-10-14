/// A piece of transcribed or translated text with its time range.
///
/// The original pipeline's `Segment` (start/end in milliseconds, text).
public struct TimedText: Hashable, Sendable, Codable {
    public var start: AudioTime
    public var end: AudioTime
    public var text: String

    public init(start: AudioTime, end: AudioTime, text: String) {
        self.start = start
        self.end = end
        self.text = text
    }
}
