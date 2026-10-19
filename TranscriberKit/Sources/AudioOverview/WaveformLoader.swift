import Foundation
import MediaDecoding
import TranscriberCore

/// Finds a media file's waveform, and its spectrogram when asked: in
/// memory, in the disk cache (the waveform written when the file was
/// transcribed), or by decoding the file, without keeping the decoded
/// audio. One decode makes both when both are missing. Keeps the most
/// recent ones in memory.
public actor WaveformLoader {
    /// Waveforms kept in memory; each is about 3 MB per hour of audio.
    private static let memoryCapacity = 8
    /// Spectrograms kept in memory; each is about 23 MB per hour of audio.
    private static let spectrogramMemoryCapacity = 2

    private let decoder = MediaDecoder()
    private let diskCache: WaveformCache?
    private var memory: RecentlyUsed<Waveform>
    private var spectrograms: RecentlyUsed<Spectrogram>

    public init(diskCache: WaveformCache? = nil) {
        self.diskCache = diskCache
        memory = RecentlyUsed(capacity: Self.memoryCapacity)
        spectrograms = RecentlyUsed(capacity: Self.spectrogramMemoryCapacity)
    }

    /// With `includingSpectrogram`, a decode this needs also makes the
    /// spectrogram, so a later `spectrogram(for:)` finds it.
    public func waveform(for url: URL, includingSpectrogram: Bool = false) throws -> Waveform {
        if let cached = memory[url] ?? diskCache?.waveform(for: url) {
            memory[url] = cached
            return cached
        }
        return try decode(url, includingSpectrogram: includingSpectrogram && cachedSpectrogram(for: url) == nil).waveform
    }

    /// Stops early, throwing `CancellationError`, once the task is cancelled.
    public func spectrogram(for url: URL) throws -> Spectrogram {
        if let cached = cachedSpectrogram(for: url) {
            return cached
        }
        // Always made when asked for; nil would mean the builder was never created.
        guard let spectrogram = try decode(url, includingSpectrogram: true).spectrogram else {
            throw SpectrogramError.transformUnavailable
        }
        return spectrogram
    }

    private func cachedSpectrogram(for url: URL) -> Spectrogram? {
        guard let cached = spectrograms[url] ?? diskCache?.spectrogram(for: url) else { return nil }
        spectrograms[url] = cached
        return cached
    }

    /// Summarized as it is decoded: a film's samples never sit in memory at once.
    private func decode(_ url: URL, includingSpectrogram: Bool) throws -> (waveform: Waveform, spectrogram: Spectrogram?) {
        var builder = Waveform.Builder()
        var spectrogramBuilder = includingSpectrogram ? try Spectrogram.Builder() : nil
        try decoder.decodeAudio(at: url) { samples in
            builder.append(samples)
            try spectrogramBuilder?.append(samples)
        }
        let waveform = builder.finish()
        diskCache?.store(waveform, for: url)
        memory[url] = waveform
        let spectrogram = spectrogramBuilder?.finish()
        if let spectrogram {
            diskCache?.store(spectrogram, for: url)
            spectrograms[url] = spectrogram
        }
        return (waveform, spectrogram)
    }
}

/// The last few values looked up by URL, the oldest dropped first.
private struct RecentlyUsed<Value> {
    let capacity: Int
    private var values: [URL: Value] = [:]
    private var recentURLs: [URL] = []

    init(capacity: Int) {
        self.capacity = capacity
    }

    subscript(url: URL) -> Value? {
        get { values[url] }
        set {
            values[url] = newValue
            recentURLs.removeAll { $0 == url }
            guard newValue != nil else { return }
            recentURLs.append(url)
            if recentURLs.count > capacity {
                values[recentURLs.removeFirst()] = nil
            }
        }
    }
}
