import Foundation
import MediaDecoding
import TranscriberCore

/// Finds a media file's video frames and keyframes: in memory, in the disk
/// cache, or by reading the file's packets. Keeps the most recent in memory.
public actor VideoFramesLoader {
    /// Frame lists kept in memory; each is about 2 MB per hour of 60 fps video.
    private static let memoryCapacity = 8

    private let reader = VideoFrameReader()
    private let diskCache: VideoFramesCache?
    private var memory: [URL: VideoFrames] = [:]
    private var recentURLs: [URL] = []

    public init(diskCache: VideoFramesCache? = nil) {
        self.diskCache = diskCache
    }

    /// `nil` when the file has no video. The file is read off the actor and
    /// the reading stops when the calling task is cancelled.
    public nonisolated func frames(for url: URL) async throws -> VideoFrames? {
        if let cached = await cachedFrames(for: url) {
            return cached
        }
        guard let frames = try reader.frames(at: url) else {
            return nil
        }
        await remember(frames, for: url, storing: true)
        return frames
    }

    private func cachedFrames(for url: URL) -> VideoFrames? {
        guard let cached = memory[url] ?? diskCache?.frames(for: url) else {
            return nil
        }
        remember(cached, for: url, storing: false)
        return cached
    }

    private func remember(_ frames: VideoFrames, for url: URL, storing: Bool) {
        if storing {
            diskCache?.store(frames, for: url)
        }
        memory[url] = frames
        recentURLs.removeAll { $0 == url }
        recentURLs.append(url)
        if recentURLs.count > Self.memoryCapacity {
            memory[recentURLs.removeFirst()] = nil
        }
    }
}
