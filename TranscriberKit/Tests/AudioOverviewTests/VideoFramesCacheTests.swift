import Foundation
import Testing
import TranscriberCore
@testable import AudioOverview

struct VideoFramesCacheTests {
    private static func temporaryFolder() -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("VideoFramesCacheTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private static func frames() throws -> VideoFrames {
        try #require(VideoFrames(
            frameTimes: (0..<300).map { AudioTime(milliseconds: $0 * 40) },
            keyframeTimes: [AudioTime(milliseconds: 0), AudioTime(milliseconds: 4_000)]
        ))
    }

    @Test func keepsFramesUntilTheFileChanges() throws {
        let folder = Self.temporaryFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let media = folder.appendingPathComponent("film.mkv")
        try Data(repeating: 1, count: 100).write(to: media)
        let cache = VideoFramesCache(directory: folder.appendingPathComponent("cache"))
        let frames = try Self.frames()

        #expect(cache.frames(for: media) == nil)
        cache.store(frames, for: media)
        #expect(cache.frames(for: media) == frames)

        try Data(repeating: 2, count: 200).write(to: media)  // another size: another file
        #expect(cache.frames(for: media) == nil)
    }

    @Test func rejectsDamagedFiles() throws {
        let frames = try Self.frames()
        let encoded = VideoFramesCache.encode(frames)
        #expect(VideoFramesCache.decode(encoded) == frames)
        #expect(VideoFramesCache.decode(encoded.dropLast()) == nil)
        #expect(VideoFramesCache.decode(Data()) == nil)
    }
}
