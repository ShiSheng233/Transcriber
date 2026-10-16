import TranscriberCore

/// A file's audio reduced to one peak and one loudness value per 10 ms, small
/// enough to keep for a whole film: what the editor draws, and where it finds
/// speech boundaries to snap times to.
public struct Waveform: Sendable, Equatable {
    public static let binDuration = AudioTime(milliseconds: 10)

    /// Largest absolute sample in each bin, 0…1.
    public let peaks: [Float]
    /// Root mean square of each bin, 0…1.
    public let levels: [Float]
    public let duration: AudioTime

    public init(samples: [Float]) {
        var builder = Builder()
        builder.append(samples)
        self = builder.finish()
    }

    init(peaks: [Float], levels: [Float], duration: AudioTime) {
        self.peaks = peaks
        self.levels = levels
        self.duration = duration
    }

    /// Builds a waveform from audio handed over in pieces of any size.
    public struct Builder {
        private var peaks: [Float] = []
        private var levels: [Float] = []
        private var sampleCount = 0
        /// The bin being filled, carried over between pieces.
        private var binPeak: Float = 0
        private var binSumOfSquares: Float = 0
        private var binFill = 0

        public init() {}

        public mutating func append(_ samples: [Float]) {
            let binSize = Waveform.binDuration.samples
            for sample in samples {
                binPeak = max(binPeak, abs(sample))
                binSumOfSquares += sample * sample
                binFill += 1
                if binFill == binSize {
                    closeBin()
                }
            }
            sampleCount += samples.count
        }

        public mutating func finish() -> Waveform {
            if binFill > 0 {
                closeBin()
            }
            return Waveform(peaks: peaks, levels: levels, duration: AudioTime(samples: sampleCount))
        }

        private mutating func closeBin() {
            peaks.append(min(binPeak, 1))
            levels.append(min((binSumOfSquares / Float(binFill)).squareRoot(), 1))
            binPeak = 0
            binSumOfSquares = 0
            binFill = 0
        }
    }

    /// The largest peak between two times, for one column of a drawing.
    public func peak(from start: AudioTime, to end: AudioTime) -> Float {
        let range = binRange(from: start, to: end)
        return range.isEmpty ? 0 : peaks[range].max() ?? 0
    }

    private func binRange(from start: AudioTime, to end: AudioTime) -> Range<Int> {
        let binSize = Self.binDuration.samples
        let first = min(max(start.samples / binSize, 0), peaks.count)
        let last = min(max((end.samples + binSize - 1) / binSize, first), peaks.count)
        return first..<max(last, min(first + 1, peaks.count))
    }
}
