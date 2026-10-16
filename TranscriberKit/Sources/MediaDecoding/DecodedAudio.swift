import TranscriberCore

/// A media file's first audio stream at 16 kHz mono, and where its
/// timestamps jumped.
public struct DecodedAudio: Sendable, Equatable {
    public var samples: [Float]
    /// Places where a frame's timestamp disagreed with the audio before it.
    /// With `MediaDecoder.TimestampHandling.followTimestamps` these were
    /// corrected; otherwise they are only reported.
    public var timestampJumps: [AudioTimestampJump]

    public init(samples: [Float], timestampJumps: [AudioTimestampJump]) {
        self.samples = samples
        self.timestampJumps = timestampJumps
    }

    public var duration: AudioTime {
        AudioTime(samples: samples.count)
    }
}

/// A frame that starts later (a hole) or earlier (an overlap) than the
/// previous frame ended.
public struct AudioTimestampJump: Sendable, Equatable {
    /// Where in the decoded samples the frame begins.
    public var position: AudioTime
    /// Positive for a hole (silence goes in), negative for an overlap
    /// (samples are dropped).
    public var offset: AudioTime

    public init(position: AudioTime, offset: AudioTime) {
        self.position = position
        self.offset = offset
    }
}
