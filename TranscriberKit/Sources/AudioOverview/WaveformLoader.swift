import Foundation
import MediaDecoding
import TranscriberCore

/// Finds a media file's waveform: in memory, in the disk cache (written
/// when the file was transcribed), or by decoding the file, without keeping
/// the decoded audio. Keeps the most recent ones in memory.
public actor WaveformLoader {
    /// Waveforms kept in memory; each is about 3 MB per hour of audio.
    private static let memoryCapacity = 8

    private let decoder = MediaDecoder()
    private let diskCache: WaveformCache?
    private var memory: [URL: Waveform] = [:]
    private var recentURLs: [URL] = []

    public init(diskCache: WaveformCache? = nil) {
        self.diskCache = diskCache
    }

    public func waveform(for url: URL) throws -> Waveform {
        if let cached = memory[url] ?? diskCache?.waveform(for: url) {
            remember(cached, for: url)
            return cached
        }
        // Summarized as it is decoded: a film's samples never sit in memory at once.
        var builder = Waveform.Builder()
        try decoder.decodeAudio(at: url) { builder.append($0) }
        let waveform = builder.finish()
        diskCache?.store(waveform, for: url)
        remember(waveform, for: url)
        return waveform
    }

    private func remember(_ waveform: Waveform, for url: URL) {
        memory[url] = waveform
        recentURLs.removeAll { $0 == url }
        recentURLs.append(url)
        if recentURLs.count > Self.memoryCapacity {
            memory[recentURLs.removeFirst()] = nil
        }
    }
}
