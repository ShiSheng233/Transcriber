import Foundation
import MediaDecoding
import TranscriberCore

/// Decodes media files into waveforms, one at a time, and keeps the most
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
        let audio = try decoder.decodeAudio(at: url)
        try Task.checkCancellation()
        let waveform = Waveform(samples: audio.samples)
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
