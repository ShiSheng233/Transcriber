/// A contiguous part of the audio transcribed on its own.
public struct AudioChunk: Hashable, Sendable, Codable {
    public var index: Int
    public var startSeconds: Double
    public var endSeconds: Double

    public init(index: Int, startSeconds: Double, endSeconds: Double) {
        self.index = index
        self.startSeconds = startSeconds
        self.endSeconds = endSeconds
    }

    /// The samples to transcribe, as the original cuts them:
    /// `int(round(seconds * 16000))`, clamped to the audio.
    public func sampleRange(inAudioOfLength sampleCount: Int) -> Range<Int> {
        let start = min(sampleCount, max(0, AudioTime(seconds: startSeconds).samples))
        let end = min(sampleCount, max(start, AudioTime(seconds: endSeconds).samples))
        return start..<end
    }

    /// Where the chunk's segment times are shifted to: `int(round(start * 1000))` ms.
    public var startOffset: AudioTime {
        AudioTime(milliseconds: Int((startSeconds * 1_000).rounded(.toNearestOrEven)))
    }

    public var endBoundary: AudioTime {
        AudioTime(milliseconds: Int((endSeconds * 1_000).rounded(.toNearestOrEven)))
    }
}
