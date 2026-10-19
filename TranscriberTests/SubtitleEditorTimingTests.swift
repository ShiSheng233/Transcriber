import Foundation
import Testing
import TranscriberCore

/// Shifting, the waveform's drag previews, and what the playback commands play.
struct SubtitleEditorTimingTests {
    private let undoManager = UndoManager()

    private func ms(_ milliseconds: Int) -> AudioTime {
        AudioTime(milliseconds: milliseconds)
    }

    @Test func shiftWithoutSelectionMovesEveryLine() {
        let editor = TestLines.editor()
        editor.shift(byMilliseconds: 500)
        #expect(editor.lines.map(\.start) == [ms(500), ms(2_500), ms(4_500)])
        #expect(editor.selection.isEmpty)
    }

    @Test func shiftFromTheSelectedLineOnwardMovesOnlyTheChosenEdge() {
        let editor = TestLines.editor()
        editor.select([1])
        editor.shift(by: ms(250), changing: .start, scope: .selectedLineOnward)
        #expect(editor.lines.map(\.start) == [ms(0), ms(2_250), ms(4_250)])
        #expect(editor.lines.map(\.end) == TestLines.three.map(\.end))
    }

    @Test func shiftToPlayheadMovesTheSelectionByTheActiveLine() {
        let editor = TestLines.editor()
        editor.select([1, 2])
        editor.playbackTimeChanged(to: ms(2_500), isPlaying: false)
        editor.shiftToPlayback()
        #expect(editor.lines.map(\.start) == [ms(0), ms(2_500), ms(4_500)])
        #expect(editor.lines[1].end == ms(3_500))
    }

    @Test func makeContinuousStartsWhereThePreviousLineEnds() {
        let editor = TestLines.editor()
        editor.select([1])
        editor.makeContinuous(changing: .start)
        #expect(editor.lines[1].start == ms(1_000))
    }

    @Test func draggingAHandleWithShiftMovesTheTouchingNeighbourAsOneUndoStep() {
        let touching = [TestLines.line(0, 1_000, "a"), TestLines.line(1_000, 2_000, "b")]
        let editor = TestLines.editor(touching, undoManager: undoManager)
        editor.select([1])
        editor.previewTimes(of: 1, start: ms(800), end: ms(2_000), movesNeighbours: true)
        #expect(editor.lines == touching)
        #expect(editor.displayedLines[0].end == ms(800))
        #expect(editor.activeLine?.start == ms(800))
        undoManager.step { editor.commitTimingPreview(actionName: "Change Times") }
        #expect(editor.timingPreview == nil)
        #expect(editor.lines.map(\.start) == [ms(0), ms(800)])
        #expect(editor.lines[0].end == ms(800))
        undoManager.undo()
        #expect(editor.lines == touching)
    }

    @Test func aCancelledPreviewChangesNothing() {
        let editor = TestLines.editor()
        editor.select([0])
        editor.previewShift(by: ms(300))
        #expect(editor.displayedLines[0].start == ms(300))
        editor.cancelTimingPreview()
        #expect(editor.displayedLines == TestLines.three)
        editor.commitTimingPreview(actionName: "Shift Times")
        #expect(editor.lines == TestLines.three)
    }

    @Test func playbackAroundTheEdgesStaysInsideTheAudioAndTheLine() {
        let editor = TestLines.editor([TestLines.line(200, 1_000, "a"), TestLines.line(2_000, 2_300, "b")])
        editor.select([0])
        #expect(editor.playbackRange(.beforeStart)! == (ms(0), ms(200)))
        #expect(editor.playbackRange(.afterStart)! == (ms(200), ms(700)))
        #expect(editor.playbackRange(.beforeEnd)! == (ms(500), ms(1_000)))
        #expect(editor.playbackRange(.afterEnd)! == (ms(1_000), ms(1_500)))
        // A line shorter than the 500 ms context.
        editor.select([1])
        #expect(editor.playbackRange(.afterStart)! == (ms(2_000), ms(2_300)))
        #expect(editor.playbackRange(.beforeEnd)! == (ms(2_000), ms(2_300)))
    }

    @Test func playSelectionSpansEverySelectedLine() {
        let editor = TestLines.editor()
        #expect(editor.playbackRange(.selection) == nil)
        editor.select([0, 2])
        #expect(editor.playbackRange(.selection)! == (ms(0), ms(5_000)))
    }

    @Test func playingSelectsTheSpokenLineUnlessTypingInTheEditBox() {
        let editor = TestLines.editor()
        editor.playbackTimeChanged(to: ms(2_500), isPlaying: false)
        #expect(editor.playingIndex == 1)
        #expect(editor.selection.isEmpty)
        editor.playbackTimeChanged(to: ms(4_500), isPlaying: true)
        #expect(editor.selection == [2])
        editor.isEditingInEditBox = true
        editor.playbackTimeChanged(to: ms(500), isPlaying: true)
        #expect(editor.playingIndex == 0)
        #expect(editor.selection == [2])
    }

    @Test func splitAtPlayheadNeedsThePlayheadInsideTheLine() {
        let editor = TestLines.editor([TestLines.line(0, 1_000, "abcd")])
        editor.select([0])
        editor.playbackTimeChanged(to: ms(1_000), isPlaying: false)
        #expect(!editor.canSplitAtPlayback)
        editor.playbackTimeChanged(to: ms(250), isPlaying: false)
        #expect(editor.canSplitAtPlayback)
        editor.splitAtPlayback(atCharacter: nil)
        #expect(editor.lines == [TestLines.line(0, 250, "a"), TestLines.line(250, 1_000, "bcd")])
    }

    @Test func overlappingLinesAreMarkedAgainstTheActiveLine() {
        let editor = TestLines.editor([TestLines.line(0, 1_500, "a"), TestLines.line(1_000, 2_000, "b"), TestLines.line(3_000, 4_000, "c")])
        editor.select([0])
        #expect(editor.rows.map(\.overlapsActiveLine) == [false, true, false])
    }

    // MARK: Video frames

    /// 25 fps for ten seconds, keyframes at 0 and 2 s.
    private func video() throws -> VideoFrames {
        try #require(VideoFrames(frameTimes: (0..<250).map { ms($0 * 40) }, keyframeTimes: [ms(0), ms(2_000)]))
    }

    @Test func aligningToFramesMovesTheSelectionOrEverythingAsOneUndoStep() throws {
        let lines = [TestLines.line(41, 1_001, "a"), TestLines.line(2_001, 2_999, "b")]
        let editor = TestLines.editor(lines, undoManager: undoManager)
        let frames = try video()
        editor.select([1])
        undoManager.step { editor.alignTimesToFrames(frames) }
        #expect(editor.lines[0] == lines[0])
        #expect(editor.lines[1].start == ms(2_020) && editor.lines[1].end == ms(2_980))
        #expect(editor.selection == [1])
        #expect(undoManager.undoActionName == "Align Times to Video Frames")
        editor.select([])
        undoManager.step { editor.alignTimesToFrames(frames) }
        #expect(editor.lines[0].start == ms(60) && editor.lines[0].end == ms(1_020))
        undoManager.undo()
        undoManager.undo()
        #expect(editor.lines == lines)
    }

    @Test func aligningTimesAlreadyOnFramesAddsNoUndoStep() throws {
        let editor = TestLines.editor([TestLines.line(20, 1_020, "a")], undoManager: undoManager)
        let frames = try video()
        undoManager.step { editor.alignTimesToFrames(frames) }
        #expect(!undoManager.canUndo)
    }

    @Test func adjustTimingSnapsToKeyframesOnlyWithAVideo() throws {
        let editor = TestLines.editor([TestLines.line(1_850, 3_000, "a")])
        var settings = TimingPostProcessing.Settings(
            leadIn: nil, leadOut: nil, adjacentThreshold: nil, adjacentBias: 1, startSnapDistance: nil, endSnapDistance: nil
        )
        settings.keyframeSnap = .aegisub
        #expect(editor.postProcessingChangeCount(settings, allLines: true, sound: []) == 0)
        #expect(editor.postProcessingChangeCount(settings, allLines: true, sound: [], video: try video()) == 1)
        editor.postProcessTiming(settings, allLines: true, sound: [], video: try video())
        #expect(editor.lines[0].start == ms(1_980))
    }
}
