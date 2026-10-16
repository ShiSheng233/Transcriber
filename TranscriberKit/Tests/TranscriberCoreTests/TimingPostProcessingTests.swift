import Testing
@testable import TranscriberCore

struct TimingPostProcessingTests {
    private func line(_ start: Double, _ end: Double) -> TimedText {
        TimedText(start: AudioTime(seconds: start), end: AudioTime(seconds: end), text: "")
    }

    private func settings(
        leadIn: Int? = nil, leadOut: Int? = nil, adjacent: Int? = nil, bias: Double = 0.5, snap: Int? = nil
    ) -> TimingPostProcessing.Settings {
        TimingPostProcessing.Settings(
            leadIn: leadIn.map(AudioTime.init(milliseconds:)),
            leadOut: leadOut.map(AudioTime.init(milliseconds:)),
            adjacentThreshold: adjacent.map(AudioTime.init(milliseconds:)),
            adjacentBias: bias,
            snapDistance: snap.map(AudioTime.init(milliseconds:))
        )
    }

    @Test func padsWithoutCreatingOverlaps() {
        let lines = [line(0.1, 1), line(1.2, 2), line(5, 6)]
        let result = TimingPostProcessing.processed([], in: lines, settings: settings(leadIn: 200, leadOut: 300))
        #expect(result.lines == [line(0, 1), line(1, 2.3), line(4.8, 6.3)])
    }

    @Test func closesSmallGapsAndOverlapsAtTheBias() {
        let lines = [line(0, 1), line(1.2, 2), line(1.9, 3), line(5, 6)]
        let result = TimingPostProcessing.processed([], in: lines, settings: settings(adjacent: 300))
        #expect(result.lines == [line(0, 1.1), line(1.1, 1.95), line(1.95, 3), line(5, 6)])
        let keepFirstEnd = TimingPostProcessing.processed([0], in: lines, settings: settings(adjacent: 300, bias: 0))
        #expect(keepFirstEnd.lines[0] == line(0, 1) && keepFirstEnd.lines[1] == line(1, 2))
    }

    @Test func snapsToNearbySpeechBoundaries() {
        let speech = [SpeechSpan(start: AudioTime(seconds: 0.9), end: AudioTime(seconds: 2.1))]
        let lines = [line(1, 2), line(3, 4)]
        let result = TimingPostProcessing.processed([], in: lines, settings: settings(snap: 150), speech: speech)
        #expect(result.lines == [line(0.9, 2.1), line(3, 4)])
    }

    @Test func leavesUnchosenLinesAlone() {
        let lines = [line(1, 2), line(5, 6)]
        let result = TimingPostProcessing.processed([1], in: lines, settings: .aegisub)
        #expect(result.lines[0] == line(1, 2))
        #expect(result.lines[1] == line(4.8, 6.3))
        #expect(result.selection == [1])
    }
}
