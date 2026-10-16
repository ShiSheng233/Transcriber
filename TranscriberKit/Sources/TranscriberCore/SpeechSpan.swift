/// A stretch of audio the VAD considers speech, half-open: `start..<end`.
public struct SpeechSpan: Hashable, Sendable, Codable {
    public var start: AudioTime
    public var end: AudioTime

    public init(start: AudioTime, end: AudioTime) {
        self.start = start
        self.end = end
    }

    public var duration: AudioTime {
        end - start
    }

    /// Without the VAD's padding on each side: about where speech itself
    /// starts and ends. `nil` when nothing is left.
    public func trimmed(by padding: AudioTime) -> SpeechSpan? {
        let trimmed = SpeechSpan(start: start + padding, end: end - padding)
        return trimmed.end > trimmed.start ? trimmed : nil
    }
}
