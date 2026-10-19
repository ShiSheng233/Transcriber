import Accelerate
import TranscriberCore

/// A file's audio as loudness per frequency band, one column per 20 ms,
/// for the editor's spectrogram display (after Aegisub's spectrum mode).
/// One byte per band: about 23 MB per hour of audio.
///
/// The frequency axis is mel-spaced from 50 Hz to 8 kHz, the Nyquist
/// frequency of the 16 kHz audio, which is the range Whisper's own features
/// cover. A mel axis gives the voice's pitch harmonics and first formants
/// (roughly 100 Hz to 3 kHz) most of the height, while sibilants and
/// fricatives (4 to 8 kHz) still show, squeezed into the top; a linear axis
/// would spend half the height above 4 kHz, where speech has little detail.
public struct Spectrogram: Sendable, Equatable {
    public static let columnDuration = AudioTime(milliseconds: 20)
    public static let bandCount = 128
    public static let lowestFrequency: Float = 50
    public static let highestFrequency = Float(AudioTime.sampleRate) / 2
    /// The level range a band's byte spans, in dB relative to a full-scale
    /// sine: 0 is that floor, 255 that ceiling. Anything quieter (silence
    /// too) is 0.
    public static let floorDecibels: Float = -100
    public static let ceilingDecibels: Float = 0
    public static let maximumLevel = UInt8.max

    /// Analysis window: 32 ms resolves the harmonics of voices above about
    /// 60 Hz (31 Hz per FFT bin) without smearing syllable onsets.
    static let windowLog2Length = 9
    static let windowLength = 1 << windowLog2Length
    /// Builders check for cancellation after this many columns (about 20 s).
    static let cancellationCheckInterval = 1_024

    /// Band levels column by column, lowest band first within a column.
    public let levels: [UInt8]
    public let columnCount: Int
    public let duration: AudioTime

    /// Throws `CancellationError` once the task is cancelled.
    public init(samples: [Float]) throws {
        var builder = try Builder()
        try builder.append(samples)
        self = builder.finish()
    }

    init(levels: [UInt8], columnCount: Int, duration: AudioTime) {
        self.levels = levels
        self.columnCount = columnCount
        self.duration = duration
    }

    /// Band 0 is the lowest frequency.
    public func level(column: Int, band: Int) -> UInt8 {
        levels[column * Self.bandCount + band]
    }

    /// The column that shows `time`, which may be past either end.
    public static func column(at time: AudioTime) -> Int {
        Int((Double(time.samples) / Double(columnDuration.samples)).rounded(.down))
    }

    public static func startTime(ofColumn column: Int) -> AudioTime {
        AudioTime(samples: column * columnDuration.samples)
    }

    /// The decibel level a band's byte stands for.
    public static func decibels(ofLevel level: UInt8) -> Float {
        floorDecibels + Float(level) / Float(maximumLevel) * (ceilingDecibels - floorDecibels)
    }

    /// Builds a spectrogram from audio handed over in pieces of any size.
    /// Column `n` covers `n × 20 ms ..< (n + 1) × 20 ms` and is measured
    /// with a window centred on that span; the audio is taken as silent
    /// before its start and after its end.
    public struct Builder {
        private let analyzer: ColumnAnalyzer
        private var levels: [UInt8] = []
        private var columnCount = 0
        private var sampleCount = 0
        /// Audio from the start of the next column's window on.
        private var pending: [Float]

        public init() throws {
            analyzer = try ColumnAnalyzer()
            // The first window starts this far before the audio.
            let lead = (Spectrogram.windowLength - Spectrogram.columnDuration.samples) / 2
            pending = [Float](repeating: 0, count: lead)
        }

        /// Throws `CancellationError` once the task is cancelled.
        public mutating func append(_ samples: [Float]) throws {
            try Task.checkCancellation()
            sampleCount += samples.count
            pending += samples
            try analyzePending(upTo: .max) { try Task.checkCancellation() }
        }

        public mutating func finish() -> Spectrogram {
            let hop = Spectrogram.columnDuration.samples
            let finalColumnCount = (sampleCount + hop - 1) / hop
            let missing = finalColumnCount - columnCount
            if missing > 0 {
                let needed = (missing - 1) * hop + Spectrogram.windowLength
                pending += [Float](repeating: 0, count: max(needed - pending.count, 0))
                analyzePending(upTo: finalColumnCount) {}
            }
            return Spectrogram(levels: levels, columnCount: columnCount, duration: AudioTime(samples: sampleCount))
        }

        /// Analyzes every whole window in `pending`, keeping what the next one needs.
        private mutating func analyzePending(upTo columnLimit: Int, checkpoint: () throws -> Void) rethrows {
            let hop = Spectrogram.columnDuration.samples
            let window = Spectrogram.windowLength
            let analyzer = analyzer
            let allowed = columnLimit - columnCount
            var newLevels: [UInt8] = []
            var start = 0
            var analyzed = 0
            defer {
                levels += newLevels
                columnCount += analyzed
                pending.removeFirst(start)
            }
            try pending.withUnsafeBufferPointer { buffer in
                while start + window <= buffer.count, analyzed < allowed {
                    newLevels += analyzer.levels(of: UnsafeBufferPointer(rebasing: buffer[start..<(start + window)]))
                    start += hop
                    analyzed += 1
                    if analyzed.isMultiple(of: Spectrogram.cancellationCheckInterval) {
                        try checkpoint()
                    }
                }
            }
        }
    }
}

/// Why a spectrogram could not be made.
public enum SpectrogramError: Error, Equatable {
    /// vDSP could not set up its FFT (out of memory).
    case transformUnavailable
}

extension Spectrogram {
    /// The FFT set-up, window and band edges, made once per builder. A class
    /// for its scratch buffers; never shared between builders.
    final class ColumnAnalyzer {
        private let transform: vDSP.FFT<DSPSplitComplex>
        private let window: [Float]
        /// Power of a full-scale sine's bin after windowing and vDSP's
        /// scaling, the 0 dB reference.
        private let fullScalePower: Float
        /// The FFT bins averaged for each band.
        private let bandBins: [Range<Int>]
        private var windowed: [Float]
        private var real: [Float]
        private var imaginary: [Float]
        private var power: [Float]

        init() throws {
            let length = Spectrogram.windowLength
            guard let transform = vDSP.FFT(log2n: vDSP_Length(Spectrogram.windowLog2Length), radix: .radix2, ofType: DSPSplitComplex.self) else {
                throw SpectrogramError.transformUnavailable
            }
            self.transform = transform
            window = vDSP.window(ofType: Float.self, usingSequence: .hanningDenormalized, count: length, isHalfWindow: false)
            // The real FFT doubles the true DFT, and a sine of amplitude A
            // reaches A × sum(window) / 2 in its bin: together A × sum(window).
            fullScalePower = pow(vDSP.sum(window), 2)
            bandBins = Self.bandBins(binCount: length / 2)
            windowed = [Float](repeating: 0, count: length)
            real = [Float](repeating: 0, count: length / 2)
            imaginary = [Float](repeating: 0, count: length / 2)
            power = [Float](repeating: 0, count: length / 2)
        }

        /// One column's band levels from one window of audio.
        func levels(of frame: UnsafeBufferPointer<Float>) -> [UInt8] {
            let halfLength = Spectrogram.windowLength / 2
            vDSP.multiply(frame, window, result: &windowed)
            real.withUnsafeMutableBufferPointer { realBuffer in
                imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                    guard let realPointer = realBuffer.baseAddress, let imaginaryPointer = imaginaryBuffer.baseAddress else { return }
                    var split = DSPSplitComplex(realp: realPointer, imagp: imaginaryPointer)
                    windowed.withUnsafeBytes { bytes in
                        // Even samples to the real parts, odd ones to the
                        // imaginary: the packed input of a real FFT.
                        if let pairs = bytes.bindMemory(to: DSPComplex.self).baseAddress {
                            vDSP_ctoz(pairs, 2, &split, 1, vDSP_Length(halfLength))
                        }
                    }
                    transform.forward(input: split, output: &split)
                    // The packed real FFT keeps the Nyquist bin in imagp[0];
                    // it lies past the top band, so bin 0 is the DC term alone.
                    imaginaryPointer[0] = 0
                    vDSP.squareMagnitudes(split, result: &power)
                }
            }
            return bandBins.map { bins in
                let bandPower = power[bins].reduce(0, +) / Float(bins.count)
                return Self.level(ofPower: bandPower / fullScalePower)
            }
        }

        /// Power relative to a full-scale sine, as one byte between the floor and the ceiling.
        static func level(ofPower relativePower: Float) -> UInt8 {
            guard relativePower > 0 else { return 0 }
            let decibels = 10 * log10(relativePower)
            let fraction = (decibels - Spectrogram.floorDecibels) / (Spectrogram.ceilingDecibels - Spectrogram.floorDecibels)
            return UInt8((min(max(fraction, 0), 1) * Float(Spectrogram.maximumLevel)).rounded())
        }

        /// Each band's FFT bins: those whose centre falls between the band's
        /// mel-spaced edges, or the one nearest its centre where bands are
        /// narrower than a bin (the lowest ones).
        static func bandBins(binCount: Int) -> [Range<Int>] {
            let binWidth = Spectrogram.highestFrequency / Float(binCount)
            let lowestMel = mel(ofFrequency: Spectrogram.lowestFrequency)
            let melStep = (mel(ofFrequency: Spectrogram.highestFrequency) - lowestMel) / Float(Spectrogram.bandCount)
            return (0..<Spectrogram.bandCount).map { band in
                let lowerBin = Int((frequency(ofMel: lowestMel + Float(band) * melStep) / binWidth).rounded(.up))
                let upperBin = min(Int((frequency(ofMel: lowestMel + Float(band + 1) * melStep) / binWidth).rounded(.up)), binCount)
                if upperBin > lowerBin {
                    return lowerBin..<upperBin
                }
                let centreBin = min(Int((frequency(ofMel: lowestMel + (Float(band) + 0.5) * melStep) / binWidth).rounded()), binCount - 1)
                return centreBin..<(centreBin + 1)
            }
        }

        /// The HTK mel scale (O'Shaughnessy 1987).
        private static let melScale: Float = 2_595
        private static let melCornerFrequency: Float = 700

        static func mel(ofFrequency frequency: Float) -> Float {
            melScale * log10(1 + frequency / melCornerFrequency)
        }

        static func frequency(ofMel mel: Float) -> Float {
            melCornerFrequency * (pow(10, mel / melScale) - 1)
        }
    }
}
