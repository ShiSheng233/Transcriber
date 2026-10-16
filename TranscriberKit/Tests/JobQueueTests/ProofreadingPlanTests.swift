import Foundation
import Testing
import TranscriberCore
@testable import JobQueue

/// Which lines Proofread Selected Lines sends and where the corrections go.
struct ProofreadingPlanTests {
    private static func line(_ start: Double, _ text: String) -> TimedText {
        TimedText(start: AudioTime(seconds: start), end: AudioTime(seconds: start + 1), text: text)
    }

    @Test func aTranslatedJobCorrectsTheOriginalsFoundByTimes() {
        let originals = [Self.line(0, "おはよう"), Self.line(2, "ゆいちゃん"), Self.line(4, "またね")]
        // The user retimed the third line and added one of their own.
        let lines = [Self.line(0, "早上好"), Self.line(2, "小唯"), Self.line(4.5, "再见"), Self.line(8, "新的")]

        let plan = ProofreadingPlan(chosen: [1, 2, 3], of: lines, originals: originals)

        #expect(plan.target == .originals)
        #expect(plan.segments == originals)  // all Japanese, so the context is too
        #expect(plan.lineIndices == [1])
        #expect(plan.skippedCount == 2)
        #expect(plan.corrections(from: [1: "結衣ちゃん", 0: "おはよう!"]) == [1: "結衣ちゃん"])  // only chosen lines
    }

    @Test func aJobWithoutTheLanguageModelCorrectsItsOwnLines() {
        let lines = [Self.line(0, "おはよう"), Self.line(2, "ゆいちゃん")]

        let plan = ProofreadingPlan(chosen: [1, 1, 5], of: lines, originals: [])

        #expect(plan.target == .lines)
        #expect(plan.lineIndices == [1])
        #expect(plan.skippedCount == 0)
        #expect(plan.corrections(from: [1: "ゆいちゃん"]).isEmpty)  // unchanged is not a correction
    }

    @Test func onlyTranslatedTranscriptsCanBeProofread() throws {
        let subtitles = Job(editing: URL(fileURLWithPath: "/tmp/a.srt"), mediaURL: nil, lines: [])
        #expect(!JobQueue.canProofread(subtitles))
    }
}
