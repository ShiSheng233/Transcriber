import Accelerate
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

    /// Builds a waveform from audio handed over in pieces of any size. Whole
    /// bins are measured with vDSP: a film has over a hundred million samples.
    public struct Builder {
        private var peaks: [Float] = []
        private var levels: [Float] = []
        private var sampleCount = 0
        /// The start of a bin left unfinished by the previous piece.
        private var carry: [Float] = []

        public init() {}

        public mutating func append(_ samples: [Float]) {
            let binSize = Waveform.binDuration.samples
            sampleCount += samples.count
            var start = 0
            if !carry.isEmpty {
                let needed = min(binSize - carry.count, samples.count)
                carry += samples[..<needed]
                start = needed
                guard carry.count == binSize else { return }
                closeBin(carry[...])
                carry.removeAll(keepingCapacity: true)
            }
            let wholeBinCount = (samples.count - start) / binSize
            samples.withUnsafeBufferPointer { buffer in
                peaks.reserveCapacity(peaks.count + wholeBinCount)
                levels.reserveCapacity(levels.count + wholeBinCount)
                for bin in 0..<wholeBinCount {
                    let binStart = start + bin * binSize
                    let slice = UnsafeBufferPointer(rebasing: buffer[binStart..<(binStart + binSize)])
                    peaks.append(min(vDSP.maximumMagnitude(slice), 1))
                    levels.append(min(vDSP.rootMeanSquare(slice), 1))
                }
            }
            carry += samples[(start + wholeBinCount * binSize)...]
        }

        public mutating func finish() -> Waveform {
            if !carry.isEmpty {
                closeBin(carry[...])
                carry.removeAll()
            }
            return Waveform(peaks: peaks, levels: levels, duration: AudioTime(samples: sampleCount))
        }

        private mutating func closeBin(_ samples: ArraySlice<Float>) {
            peaks.append(min(vDSP.maximumMagnitude(samples), 1))
            levels.append(min(vDSP.rootMeanSquare(samples), 1))
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
