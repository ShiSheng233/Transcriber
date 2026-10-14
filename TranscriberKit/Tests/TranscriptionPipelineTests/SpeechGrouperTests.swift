import Testing
import TranscriberCore
@testable import TranscriptionPipeline

struct SpeechGrouperTests {
    private func span(_ start: Double, _ end: Double) -> SpeechSpan {
        SpeechSpan(start: AudioTime(seconds: start), end: AudioTime(seconds: end))
    }

    private func groups(_ spans: [SpeechSpan]) -> [[Double]] {
        SpeechGrouper.groups(spans, settings: .chunks).map { [$0.startSeconds, $0.endSeconds] }
    }

    @Test func joinsCloseSpansUpToTheMaximumDuration() {
        // Gaps of 0.1 s join; the third span would make the group 2.6 s long.
        #expect(groups([span(0, 1), span(1.1, 2), span(2.1, 2.6)]) == [[0, 2], [2.1, 2.6]])
    }

    @Test func keepsSpansApartAcrossALongGap() {
        #expect(groups([span(0, 1), span(1.25, 2)]) == [[0, 1], [1.25, 2]])  // gap == 0.25 s is not < 0.25 s
        #expect(groups([span(0, 1), span(1.2, 2)]) == [[0, 2]])
    }

    @Test func leavesLongSpansAloneAndNumbersGroups() {
        let result = SpeechGrouper.groups([span(0, 4), span(4.1, 5)], settings: .chunks)
        #expect(result.map(\.index) == [0, 1])
        #expect(result.map(\.startSeconds) == [0, 4.1])
    }
}
