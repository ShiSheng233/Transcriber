import Foundation
import MediaDecoding
import TranscriberCore

/// Decodes media files into waveforms, one at a time, without keeping the
/// decoded audio, and keeps the most
/// recent ones so going back to a file is instant.
public actor WaveformLoader {
    /// Waveforms kept; each is about 1 MB per hour of audio.
    private static let cacheCapacity = 8

    private let decoder = MediaDecoder()
    private var cache: [URL: Waveform] = [:]
    private var recentURLs: [URL] = []

    public init() {}

    public func waveform(for url: URL) throws -> Waveform {
        if let cached = cache[url] {
            touch(url)
            return cached
        }
        // Summarized as it is decoded: a film's samples never sit in memory at once.
        var builder = Waveform.Builder()
        try decoder.decodeAudio(at: url) { builder.append($0) }
        let waveform = builder.finish()
        cache[url] = waveform
        touch(url)
        if recentURLs.count > Self.cacheCapacity {
            cache[recentURLs.removeFirst()] = nil
        }
        return waveform
    }

    private func touch(_ url: URL) {
        recentURLs.removeAll { $0 == url }
        recentURLs.append(url)
    }
}
