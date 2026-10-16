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
        let binSize = Self.binDuration.samples
        let binCount = (samples.count + binSize - 1) / binSize
        var peaks = [Float](repeating: 0, count: binCount)
        var levels = [Float](repeating: 0, count: binCount)
        samples.withUnsafeBufferPointer { buffer in
            for bin in 0..<binCount {
                let range = (bin * binSize)..<min((bin + 1) * binSize, buffer.count)
                var peak: Float = 0
                var sumOfSquares: Float = 0
                for index in range {
                    let sample = buffer[index]
                    peak = max(peak, abs(sample))
                    sumOfSquares += sample * sample
                }
                peaks[bin] = min(peak, 1)
                levels[bin] = min((sumOfSquares / Float(range.count)).squareRoot(), 1)
            }
        }
        self.peaks = peaks
        self.levels = levels
        duration = AudioTime(samples: samples.count)
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
