import Testing
@testable import TranscriberCore

struct RecognitionConfidenceTests {
    private static func confidence(_ logProbability: Double, noSpeech: Double = 0.1, ratio: Double = 1.5) -> RecognitionConfidence {
        RecognitionConfidence(
            averageLogProbability: logProbability, noSpeechProbability: noSpeech, compressionRatio: ratio, settings: ChickenRiceDefaults.decoding(task: .translate)
        )
    }

    @Test func doubtfulWhenWhispersOwnChecksStillFail() {
        #expect(!Self.confidence(-0.3).isDoubtful)
        #expect(Self.confidence(-1.5).isDoubtful)  // below log_prob_threshold (−1)
        #expect(Self.confidence(-0.3, ratio: 3).isDoubtful)  // above compression_ratio_threshold (2.4)
        #expect(!Self.confidence(-0.3, noSpeech: 0.9).isDoubtful)  // no_speech alone is the silence check, not a failure
    }

    @Test func combinesToTheLeastConfident() {
        let combined = Self.confidence(-0.3, noSpeech: 0.7).combined(with: Self.confidence(-1.5, ratio: 2))
        #expect(combined.averageLogProbability == -1.5)
        #expect(combined.noSpeechProbability == 0.7)
        #expect(combined.compressionRatio == 2)
        #expect(combined.isDoubtful)
        #expect((nil as RecognitionConfidence?).combined(with: nil) == nil)
    }

    @Test func editsKeepItUntilTheTextIsTyped() {
        let sure = Self.confidence(-0.3)
        let doubtful = Self.confidence(-1.5)
        let lines = [
            TimedText(start: .zero, end: AudioTime(seconds: 1), text: "a", confidence: sure),
            TimedText(start: AudioTime(seconds: 1), end: AudioTime(seconds: 2), text: "b", confidence: doubtful),
        ]
        #expect(SubtitleEditing.merge([0, 1], in: lines).lines[0].confidence?.isDoubtful == true)
        #expect(SubtitleEditing.split(1, atCharacter: 0, in: lines).lines[2].confidence == doubtful)
        #expect(SubtitleEditing.setText(1, to: "c", in: lines).lines[1].confidence == nil)
    }
}

struct SpeechSpanTests {
    @Test func trimsTheVADPadding() {
        let span = SpeechSpan(start: AudioTime(milliseconds: 1_000), end: AudioTime(milliseconds: 2_000))
        let padding = AudioTime(milliseconds: 200)
        #expect(span.trimmed(by: padding) == SpeechSpan(start: AudioTime(milliseconds: 1_200), end: AudioTime(milliseconds: 1_800)))
        #expect(SpeechSpan(start: .zero, end: AudioTime(milliseconds: 300)).trimmed(by: padding) == nil)
    }
}
