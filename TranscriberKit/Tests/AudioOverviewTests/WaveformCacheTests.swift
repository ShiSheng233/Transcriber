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
}
