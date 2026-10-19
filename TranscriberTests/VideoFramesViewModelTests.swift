import AudioOverview
import Foundation
import Testing
import TranscriberCore

/// Reading the shown file's frames, with small files written for each test
/// and read by the real loader (no disk cache).
struct VideoFramesViewModelTests {
    private static let loadTimeout = Duration.seconds(10)
    private static let pollInterval = Duration.milliseconds(10)

    private let video = TestVideoFile()
    private let audio = TestAudioFile()
    private let videoFrames = VideoFramesViewModel(loader: VideoFramesLoader())

    private func waitUntilRead() async throws {
        let deadline = ContinuousClock.now + Self.loadTimeout
        while videoFrames.availability == .reading {
            try #require(ContinuousClock.now < deadline, "the frames were never read")
            try await Task.sleep(for: Self.pollInterval)
        }
    }

    @Test func readsAVideosFramesAndMarksItsKeyframes() async throws {
        // 10 fps for three seconds, a keyframe at least every second.
        try await video.write(frameCount: 30, framesPerSecond: 10, keyframeInterval: 10)
        #expect(videoFrames.availability == .notRead)
        videoFrames.show(video.url)
        #expect(videoFrames.availability == .reading)
        try await waitUntilRead()
        let frames = try #require(videoFrames.frames)
        #expect(frames.frameCount == 30)
        #expect(videoFrames.unavailableReason == nil)
        #expect(videoFrames.keyframeBoundaries.first == .zero)
        #expect(videoFrames.keyframeBoundaries.count == frames.keyframes.count)
        // The second keyframe's boundary is halfway from the frame before it.
        let second = try #require(frames.keyframes.dropFirst().first)
        #expect(videoFrames.keyframeBoundaries[1] == frames.startTime(ofFrame: second))
        let visible = videoFrames.keyframeBoundaries(from: AudioTime(milliseconds: 1), through: videoFrames.keyframeBoundaries[1])
        #expect(Array(visible) == [videoFrames.keyframeBoundaries[1]])
    }

    @Test func anAudioFileHasNoVideo() async throws {
        try audio.writeTone(seconds: 1, between: 0.5)
        videoFrames.show(audio.url)
        try await waitUntilRead()
        #expect(videoFrames.availability == .noVideo)
        #expect(videoFrames.unavailableReason == "This file has no video.")
        #expect(videoFrames.keyframeBoundaries.isEmpty)
    }

    @Test func aMissingFileSaysTheFramesCouldNotBeRead() async throws {
        videoFrames.show(video.url)
        try await waitUntilRead()
        #expect(videoFrames.availability == .failed)
        #expect(videoFrames.unavailableReason == "The video's frames could not be read.")
    }

    @Test func showingNothingForgetsTheFrames() async throws {
        try await video.write(frameCount: 10, framesPerSecond: 10, keyframeInterval: 5)
        videoFrames.show(video.url)
        try await waitUntilRead()
        #expect(videoFrames.frames != nil)
        videoFrames.show(nil)
        #expect(videoFrames.availability == .notRead)
        #expect(videoFrames.frames == nil)
        #expect(videoFrames.keyframeBoundaries.isEmpty)
    }
}
