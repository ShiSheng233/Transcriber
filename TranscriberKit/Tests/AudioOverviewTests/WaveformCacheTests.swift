import Foundation
import Testing
import TranscriberCore
@testable import AudioOverview

struct WaveformCacheTests {
    private static func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("WaveformCacheTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    @Test func keepsAWaveformUntilTheFileChanges() throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("media.wav")
        try Data(repeating: 1, count: 100).write(to: media)
        let cache = WaveformCache(directory: folder.appendingPathComponent("cache"))
        let waveform = Waveform(samples: (0..<500).map { Float($0 % 50) / 50 })

        #expect(cache.waveform(for: media) == nil)
        cache.store(waveform, for: media)
        #expect(cache.waveform(for: media) == waveform)

        try Data(repeating: 2, count: 200).write(to: media)  // another size: another file
        #expect(cache.waveform(for: media) == nil)
    }

    @Test func rejectsDamagedFiles() {
        let encoded = WaveformCache.encode(Waveform(samples: [0.5, -0.25]))
        #expect(WaveformCache.decode(encoded) == Waveform(samples: [0.5, -0.25]))
        #expect(WaveformCache.decode(encoded.dropLast()) == nil)
        #expect(WaveformCache.decode(Data()) == nil)
    }

    @Test func keepsASpectrogramBesideTheWaveform() throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("media.wav")
        try Data(repeating: 1, count: 100).write(to: media)
        let cache = WaveformCache(directory: folder.appendingPathComponent("cache"))
        let samples = (0..<5_000).map { Float($0 % 50) / 50 - 0.5 }
        let spectrogram = try Spectrogram(samples: samples)

        #expect(cache.spectrogram(for: media) == nil)
        cache.store(spectrogram, for: media)
        #expect(cache.spectrogram(for: media) == spectrogram)
        #expect(cache.waveform(for: media) == nil)
    }

    @Test func rejectsDamagedSpectrograms() throws {
        let spectrogram = try Spectrogram(samples: [Float](repeating: 0.25, count: 1_000))
        let encoded = WaveformCache.encode(spectrogram)
        #expect(WaveformCache.decodeSpectrogram(encoded) == spectrogram)
        #expect(WaveformCache.decodeSpectrogram(encoded.dropLast()) == nil)
        #expect(WaveformCache.decodeSpectrogram(Data()) == nil)
    }
}
