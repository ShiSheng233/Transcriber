/// A position or duration in audio, counted in samples at 16 kHz.
///
/// Every module passes time as `AudioTime` so that samples, milliseconds,
/// VAD frames and seconds are never mixed up at call sites.
public struct AudioTime: Hashable, Comparable, Sendable, Codable {
    /// Whisper and the VAD both consume 16 kHz mono audio.
    public static let sampleRate = 16_000
    public static let zero = AudioTime(samples: 0)

    private static let samplesPerMillisecond = sampleRate / 1_000

    public var samples: Int

    public init(samples: Int) {
        self.samples = samples
    }

    public init(milliseconds: Int) {
        self.samples = milliseconds * Self.samplesPerMillisecond
    }

    /// Rounds half to even, like Python's `round()`, which the original uses
    /// for every seconds-to-samples conversion.
    public init(seconds: Double) {
        self.samples = Int((seconds * Double(Self.sampleRate)).rounded(.toNearestOrEven))
    }

    public var milliseconds: Int {
        samples / Self.samplesPerMillisecond
    }

    public var seconds: Double {
        Double(samples) / Double(Self.sampleRate)
    }

    public static func < (lhs: AudioTime, rhs: AudioTime) -> Bool {
        lhs.samples < rhs.samples
    }

    public static func + (lhs: AudioTime, rhs: AudioTime) -> AudioTime {
        AudioTime(samples: lhs.samples + rhs.samples)
    }

    public static func - (lhs: AudioTime, rhs: AudioTime) -> AudioTime {
        AudioTime(samples: lhs.samples - rhs.samples)
    }
}
