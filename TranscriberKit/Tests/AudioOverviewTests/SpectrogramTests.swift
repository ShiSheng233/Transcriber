import Foundation
import Testing
import TranscriberCore
@testable import AudioOverview

struct SpectrogramTests {
    private static let rate = AudioTime.sampleRate
    private static let columnsPerSecond = rate / Spectrogram.columnDuration.samples

    private static func sine(frequency: Float, amplitude: Float, seconds: Int) -> [Float] {
        (0..<(seconds * rate)).map { amplitude * sin(2 * .pi * frequency * Float($0) / Float(rate)) }
    }

    /// The band whose FFT bins include `frequency`.
    private static func band(containing frequency: Float) -> Int? {
        let binWidth = Spectrogram.highestFrequency / Float(Spectrogram.windowLength / 2)
        let bin = Int((frequency / binWidth).rounded())
        return Spectrogram.ColumnAnalyzer.bandBins(binCount: Spectrogram.windowLength / 2).firstIndex { $0.contains(bin) }
    }

    @Test func aSineShowsInItsOwnBandAtItsLevel() throws {
        let frequency: Float = 1_000
        let amplitude: Float = 0.5
        let spectrogram = try Spectrogram(samples: Self.sine(frequency: frequency, amplitude: amplitude, seconds: 1))
        let expectedBand = try #require(Self.band(containing: frequency))
        // A column in the middle, away from the silence around the audio.
        let column = Self.columnsPerSecond / 2
        let bands = (0..<Spectrogram.bandCount).map { spectrogram.level(column: column, band: $0) }
        let loudest = try #require(bands.indices.max { bands[$0] < bands[$1] })
        #expect(loudest == expectedBand)
        // A sine of amplitude A is 20·log10(A) dB below full scale (−6 dB),
        // within one quantization step and the band's averaging.
        let expectedDecibels = 20 * log10(amplitude)
        #expect(abs(Spectrogram.decibels(ofLevel: bands[loudest]) - expectedDecibels) < 1)
        // Far from the tone there is (next to) nothing.
        let farBand = try #require(Self.band(containing: 6_000))
        #expect(Spectrogram.decibels(ofLevel: bands[farBand]) < expectedDecibels - 60)
    }

    @Test func aHigherSineShowsHigherUp() throws {
        let low = try Spectrogram(samples: Self.sine(frequency: 300, amplitude: 0.5, seconds: 1))
        let high = try Spectrogram(samples: Self.sine(frequency: 4_000, amplitude: 0.5, seconds: 1))
        let column = Self.columnsPerSecond / 2
        func loudestBand(_ spectrogram: Spectrogram) -> Int? {
            (0..<Spectrogram.bandCount).max { spectrogram.level(column: column, band: $0) < spectrogram.level(column: column, band: $1) }
        }
        #expect(try #require(loudestBand(low)) == Self.band(containing: 300))
        #expect(try #require(loudestBand(high)) == Self.band(containing: 4_000))
    }

    @Test func silenceIsTheFloorEverywhere() throws {
        let spectrogram = try Spectrogram(samples: [Float](repeating: 0, count: Self.rate))
        #expect(spectrogram.columnCount == Self.columnsPerSecond)
        #expect(spectrogram.levels.count == Self.columnsPerSecond * Spectrogram.bandCount)
        #expect(spectrogram.levels.allSatisfy { $0 == 0 })
        #expect(Spectrogram.decibels(ofLevel: 0) == Spectrogram.floorDecibels)
    }

    @Test func coversEveryStartedColumnAndNothingForNoAudio() throws {
        let spectrogram = try Spectrogram(samples: [Float](repeating: 0.1, count: Spectrogram.columnDuration.samples * 3 + 1))
        #expect(spectrogram.columnCount == 4)
        #expect(spectrogram.duration == AudioTime(samples: Spectrogram.columnDuration.samples * 3 + 1))
        let empty = try Spectrogram(samples: [])
        #expect(empty.columnCount == 0)
        #expect(empty.levels.isEmpty)
    }

    @Test func buildsTheSameSpectrogramFromPieces() throws {
        let samples = Self.sine(frequency: 440, amplitude: 0.3, seconds: 1) + Self.sine(frequency: 2_500, amplitude: 0.2, seconds: 1)
        var builder = try Spectrogram.Builder()
        for piece in [samples[..<7], samples[7..<5_000], samples[5_000..<5_001], samples[5_001...]] {
            try builder.append(Array(piece))
        }
        #expect(builder.finish() == (try Spectrogram(samples: samples)))
    }

    @Test func stopsOnceCancelled() async {
        let samples = Self.sine(frequency: 440, amplitude: 0.3, seconds: 60)
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try Spectrogram(samples: samples)
        }
        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test func melBandsRiseFromTheLowestToTheHighestFrequency() {
        let bands = Spectrogram.ColumnAnalyzer.bandBins(binCount: Spectrogram.windowLength / 2)
        #expect(bands.count == Spectrogram.bandCount)
        #expect(bands.allSatisfy { !$0.isEmpty })
        #expect(zip(bands, bands.dropFirst()).allSatisfy { $0.lowerBound <= $1.lowerBound })
        #expect(bands.last?.upperBound == Spectrogram.windowLength / 2)
        let mel = Spectrogram.ColumnAnalyzer.mel(ofFrequency: 1_000)
        #expect(abs(Spectrogram.ColumnAnalyzer.frequency(ofMel: mel) - 1_000) < 0.1)
    }
}
