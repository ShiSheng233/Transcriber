import Testing
import TranscriberCore
@testable import WhisperDecoding

struct DecodedSegmentRepetitionLoopTests {
    private static let settings = ChickenRiceDefaults.decoding(task: .transcribe)

    private static func segment(averageLogProbability: Double, compressionRatio: Double) -> DecodedSegment {
        DecodedSegment(
            start: 0, end: 1, text: "text", tokens: [], temperature: 1,
            averageLogProbability: averageLogProbability, compressionRatio: compressionRatio, noSpeechProbability: 0
        )
    }

    @Test func aRepetitiveResultIsALoop() {
        #expect(Self.segment(averageLogProbability: -0.2, compressionRatio: 3.1).isRepetitionLoop(Self.settings))
    }

    @Test func anUnlikelyButVariedResultIsKept() {
        #expect(!Self.segment(averageLogProbability: -1.4, compressionRatio: 1.5).isRepetitionLoop(Self.settings))
        #expect(!Self.segment(averageLogProbability: -0.5, compressionRatio: 2.4).isRepetitionLoop(Self.settings))
    }
}
