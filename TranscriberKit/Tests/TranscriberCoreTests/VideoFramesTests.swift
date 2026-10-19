import Testing
@testable import TranscriberCore

/// Frames and keyframes, Aegisub's frame/time rules, and aligning lines to
/// frame boundaries.
struct VideoFramesTests {
    private func ms(_ milliseconds: Int) -> AudioTime {
        AudioTime(milliseconds: milliseconds)
    }

    /// 25 fps: a frame every 40 ms.
    private func constant(frameCount: Int = 100, keyframes: [Int] = [0, 50]) throws -> VideoFrames {
        try #require(VideoFrames(
            frameTimes: (0..<frameCount).map { ms($0 * 40) },
            keyframeTimes: keyframes.map { ms($0 * 40) }
        ))
    }

    @Test func aStartShowsOnTheFirstFrameAtOrAfterItAndAnEndIsExclusive() throws {
        let frames = try constant()
        #expect(frames.firstFrame(shownFrom: ms(40)) == 1)
        #expect(frames.firstFrame(shownFrom: ms(41)) == 2)
        #expect(frames.lastFrame(shownBefore: ms(80)) == 1)
        #expect(frames.lastFrame(shownBefore: ms(81)) == 2)
        #expect(frames.startTime(ofFrame: 1) == ms(20))
        #expect(frames.endTime(ofFrame: 1) == ms(60))
    }

    @Test func framesGoOnAtTheAverageRatePastEitherEnd() throws {
        let frames = try constant(frameCount: 10)
        #expect(frames.time(ofFrame: 25) == ms(1_000))
        #expect(frames.firstFrame(shownFrom: ms(1_000)) == 25)
        #expect(frames.firstFrame(shownFrom: ms(1_001)) == 26)
        #expect(frames.time(ofFrame: -1) == ms(-40))
        #expect(frames.startTime(ofFrame: 0) == .zero)
    }

    @Test func aVariableFrameRateUsesTheFramesOwnTimes() throws {
        // 25 fps, then 50 fps from 80 ms.
        let frames = try #require(VideoFrames(frameTimes: [0, 40, 80, 100, 120].map(ms), keyframeTimes: []))
        #expect(frames.firstFrame(shownFrom: ms(85)) == 3)
        #expect(frames.startTime(ofFrame: 3) == ms(90))
        #expect(frames.startTime(ofFrame: 1) == ms(20))
    }

    @Test func boundariesSitOnTheCentisecondGridBetweenFrames() throws {
        // 23.976 fps: frames 41.708 ms apart.
        let times = (0..<1_000).map { AudioTime(seconds: Double($0) * 1_001 / 24_000) }
        let frames = try #require(VideoFrames(frameTimes: times, keyframeTimes: []))
        #expect(frames.startTime(ofFrame: 1) == ms(20))
        for frame in [1, 2, 3, 500, 999] {
            let boundary = frames.startTime(ofFrame: frame)
            #expect(boundary.samples % ms(10).samples == 0)
            #expect(frames.time(ofFrame: frame - 1) < boundary && boundary <= frames.time(ofFrame: frame))
        }
    }

    @Test func timestampsAreSortedWithoutRepeatsAndStrayKeyframesIgnored() throws {
        let frames = try #require(VideoFrames(frameTimes: [80, 0, 40, 40].map(ms), keyframeTimes: [ms(40), ms(50)]))
        #expect(frames.frameTimes == [0, 40, 80].map(ms))
        #expect(frames.keyframes == [1])
        #expect(VideoFrames(frameTimes: [ms(0)], keyframeTimes: [ms(0)]) == nil)
        #expect(VideoFrames(frameTimes: [], keyframeTimes: []) == nil)
    }

    @Test func theClosestKeyframeIsTheEarlierOnATieAndTheLastFrameCounts() throws {
        let frames = try #require(VideoFrames(frameTimes: (0..<20).map { ms($0 * 40) }, keyframeTimes: [ms(0), ms(400)]))
        #expect(frames.closestKeyframe(to: 4) == 0)
        #expect(frames.closestKeyframe(to: 5) == 0)
        #expect(frames.closestKeyframe(to: 6) == 10)
        #expect(frames.closestKeyframe(to: 15) == 19)
        #expect(frames.closestKeyframe(to: 30) == 19)
        let noKeyframes = try #require(VideoFrames(frameTimes: (0..<20).map { ms($0 * 40) }, keyframeTimes: []))
        #expect(noKeyframes.closestKeyframe(to: 3) == 19)
    }

    // MARK: Aligning lines

    @Test func aligningKeepsEachLineOnItsFramesAndTwiceChangesNothing() throws {
        let frames = try constant()
        let lines = [
            TimedText(start: ms(41), end: ms(119), text: "a"),
            TimedText(start: ms(120), end: ms(1_001), text: "b"),
        ]
        let aligned = SubtitleEditing.alignedToFrames([], in: lines, frames: frames)
        #expect(aligned.lines.map(\.start) == [ms(60), ms(100)])
        #expect(aligned.lines.map(\.end) == [ms(100), ms(1_020)])
        #expect(aligned.selection.isEmpty)
        for (before, after) in zip(lines, aligned.lines) {
            #expect(frames.firstFrame(shownFrom: before.start) == frames.firstFrame(shownFrom: after.start))
            #expect(frames.lastFrame(shownBefore: before.end) == frames.lastFrame(shownBefore: after.end))
        }
        #expect(SubtitleEditing.alignedToFrames([], in: aligned.lines, frames: frames).lines == aligned.lines)
    }

    @Test func aligningOnlyTheChosenLines() throws {
        let frames = try constant()
        let lines = [TimedText(start: ms(41), end: ms(119), text: "a"), TimedText(start: ms(121), end: ms(199), text: "b")]
        let aligned = SubtitleEditing.alignedToFrames([1], in: lines, frames: frames)
        #expect(aligned.lines[0] == lines[0])
        #expect(aligned.lines[1].start == ms(140))
        #expect(aligned.selection == [1])
    }

    @Test func aLineShownOnNoFrameKeepsZeroLength() throws {
        let frames = try constant()
        let aligned = SubtitleEditing.alignedToFrames([], in: [TimedText(start: ms(45), end: ms(70), text: "")], frames: frames)
        #expect(aligned.lines[0].start == ms(60))
        #expect(aligned.lines[0].end == ms(60))
    }

    @Test func alignedTimesKeepTheirFramesWhenWrittenInCentisecondsOrMilliseconds() throws {
        // 29.97 fps over three hours, where a millisecond of rounding could cross a frame.
        let times = (0..<324_000).map { AudioTime(seconds: Double($0) * 1_001 / 30_000) }
        let frames = try #require(VideoFrames(frameTimes: times, keyframeTimes: []))
        for frame in stride(from: 1, to: 324_000, by: 997) {
            let boundary = frames.startTime(ofFrame: frame)
            let centiseconds = AudioTime(milliseconds: boundary.milliseconds / 10 * 10)
            let milliseconds = AudioTime(milliseconds: boundary.milliseconds)
            #expect(frames.firstFrame(shownFrom: centiseconds) == frame)
            #expect(frames.firstFrame(shownFrom: milliseconds) == frame)
        }
    }
}
