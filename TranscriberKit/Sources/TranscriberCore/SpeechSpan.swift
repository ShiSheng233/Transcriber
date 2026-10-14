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
}
