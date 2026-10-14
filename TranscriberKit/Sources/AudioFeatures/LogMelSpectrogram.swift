import Accelerate
import Foundation

/// Whisper's audio front end, numerically matching Hugging Face
/// `WhisperFeatureExtractor` (the NumPy path the original pipeline uses for its VAD).
///
/// Steps: zero-pad or trim to 30 s, reflect-pad by half a window, 400-point STFT
/// with a periodic Hann window and hop 160, power spectrum, Slaney mel filters,
/// log10 with a 1e-10 floor, drop the last frame, clamp to (max - 8), then
/// scale with (x + 4) / 4.
public struct LogMelSpectrogram: Sendable {
    public static let sampleRate = 16_000
    public static let windowSampleCount = 30 * sampleRate
    public static let frameCount = 3_000

    private static let fftLength = 400
    private static let hopLength = 160
    private static let frequencyBinCount = fftLength / 2 + 1
    private static let powerFloor = 1e-10
    private static let dynamicRangeLog10 = 8.0

    public let melBandCount: Int

    private let window: [Double]
    /// `fftLength x (2 * frequencyBinCount)`: cosine columns, then sine columns.
    private let dftBasis: [Double]
    /// `frequencyBinCount x melBandCount`.
    private let melFilters: [Double]

    public init(melBandCount: Int = 80) {
        self.melBandCount = melBandCount
        self.window = Self.periodicHannWindow(length: Self.fftLength)
        self.dftBasis = Self.realDFTBasis(length: Self.fftLength, binCount: Self.frequencyBinCount)
        self.melFilters = MelFilterBank.make(
            melBandCount: melBandCount,
            frequencyBinCount: Self.frequencyBinCount,
            sampleRate: Self.sampleRate,
            maximumFrequency: Double(Self.sampleRate / 2)
        )
    }

    /// Features for one 30 s window. Shorter input is zero-padded, longer input is trimmed.
    public func features(for samples: some Collection<Float>) -> LogMelFeatures {
        let paddedSamples = Self.fitToWindow(samples)
        let frames = framedAndWindowed(Self.reflectPadded(paddedSamples))
        let stftFrameCount = frames.count / Self.fftLength

        let power = powerSpectrum(of: frames, frameCount: stftFrameCount)
        let melEnergies = multiply(
            power, rows: stftFrameCount, inner: Self.frequencyBinCount,
            by: melFilters, columns: melBandCount
        )
        return normalizedLogMel(melEnergies, stftFrameCount: stftFrameCount)
    }

    // MARK: - Steps

    private static func fitToWindow(_ samples: some Collection<Float>) -> [Double] {
        var window = samples.prefix(windowSampleCount).map(Double.init)
        window.append(contentsOf: repeatElement(0, count: windowSampleCount - window.count))
        return window
    }

    /// NumPy "reflect" padding by half a window on each side (edge sample not repeated).
    private static func reflectPadded(_ samples: [Double]) -> [Double] {
        let padding = fftLength / 2
        let head = samples[1...padding].reversed()
        let tail = samples[(samples.count - 1 - padding)..<(samples.count - 1)].reversed()
        return Array(head) + samples + Array(tail)
    }

    private func framedAndWindowed(_ samples: [Double]) -> [Double] {
        let frameCount = 1 + (samples.count - Self.fftLength) / Self.hopLength
        var frames = [Double](repeating: 0, count: frameCount * Self.fftLength)
        for frame in 0..<frameCount {
            let start = frame * Self.hopLength
            for offset in 0..<Self.fftLength {
                frames[frame * Self.fftLength + offset] = samples[start + offset] * window[offset]
            }
        }
        return frames
    }

    /// |rfft|^2 per frame, computed as a matrix product with the DFT basis
    /// (vDSP's FFT does not support a length of 400).
    private func powerSpectrum(of frames: [Double], frameCount: Int) -> [Double] {
        let binCount = Self.frequencyBinCount
        let spectrum = multiply(
            frames, rows: frameCount, inner: Self.fftLength,
            by: dftBasis, columns: 2 * binCount
        )
        var power = [Double](repeating: 0, count: frameCount * binCount)
        for frame in 0..<frameCount {
            let row = frame * 2 * binCount
            for bin in 0..<binCount {
                let real = spectrum[row + bin]
                let imaginary = spectrum[row + binCount + bin]
                power[frame * binCount + bin] = real * real + imaginary * imaginary
            }
        }
        return power
    }

    private func normalizedLogMel(_ melEnergies: [Double], stftFrameCount: Int) -> LogMelFeatures {
        let frameCount = Self.frameCount  // the last STFT frame is dropped
        var logMel = [Double](repeating: 0, count: melBandCount * frameCount)
        for band in 0..<melBandCount {
            for frame in 0..<frameCount {
                let energy = max(melEnergies[frame * melBandCount + band], Self.powerFloor)
                logMel[band * frameCount + frame] = log10(energy)
            }
        }

        let floor = (logMel.max() ?? 0) - Self.dynamicRangeLog10
        let values = logMel.map { Float((max($0, floor) + 4) / 4) }
        return LogMelFeatures(melBandCount: melBandCount, frameCount: frameCount, values: values)
    }

    // MARK: - Helpers

    private static func periodicHannWindow(length: Int) -> [Double] {
        (0..<length).map { 0.5 - 0.5 * cos(2 * Double.pi * Double($0) / Double(length)) }
    }

    /// Real DFT as a matrix: X[k] = sum x[n] (cos(2πkn/N) - i sin(2πkn/N)).
    /// The sign of the imaginary part does not matter for the power spectrum.
    private static func realDFTBasis(length: Int, binCount: Int) -> [Double] {
        var basis = [Double](repeating: 0, count: length * 2 * binCount)
        for sample in 0..<length {
            for bin in 0..<binCount {
                let angle = 2 * Double.pi * Double(bin * sample % length) / Double(length)
                basis[sample * 2 * binCount + bin] = cos(angle)
                basis[sample * 2 * binCount + binCount + bin] = sin(angle)
            }
        }
        return basis
    }

    /// Row-major `rows x inner` times `inner x columns`.
    private func multiply(
        _ left: [Double], rows: Int, inner: Int,
        by right: [Double], columns: Int
    ) -> [Double] {
        var product = [Double](repeating: 0, count: rows * columns)
        vDSP_mmulD(left, 1, right, 1, &product, 1, vDSP_Length(rows), vDSP_Length(columns), vDSP_Length(inner))
        return product
    }
}
