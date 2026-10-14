import Testing
import TranscriberCore
@testable import SubtitlePostProcessing

struct SubtitleTextCleanupTests {
    private let all = TextCleanupSettings(dropsEllipsisOnlyLines: true, collapsesRepeats: true, appendsPeriod: true)

    private func cleaned(_ texts: [String], settings: TextCleanupSettings) -> [String] {
        let segments = texts.enumerated().map { index, text in
            TimedText(start: AudioTime(seconds: Double(index)), end: AudioTime(seconds: Double(index) + 1), text: text)
        }
        return SubtitleTextCleanup.apply(segments, settings: settings).map(\.text)
    }

    @Test func dropsLinesThatAreOnlyAnEllipsis() {
        #expect(cleaned(["…", "……？", "‥」", "...", "はい…"], settings: all) == ["はい…"])
        // Punctuation alone without an ellipsis is not dropped by this rule.
        #expect(SubtitleTextCleanup.isEllipsisOnly("？！") == false)
    }

    @Test func collapsesRunsRepeatedThreeTimesOrMore() {
        #expect(cleaned(["あああああああ", "だめだめだめ", "だめだめ"], settings: all) == ["あああ。", "だめ。", "だめだめ。"])  // as Python re.sub gives
    }

    @Test func appendsAPeriodUnlessTheLineEndsInPunctuation() {
        #expect(cleaned(["そうだね", "本当？", "うん、", "♪～"], settings: all) == ["そうだね。", "本当？", "うん、", "♪～"])
    }

    @Test func leavesTextAloneWhenOff() {
        #expect(cleaned(["…", "あああああああ", "そうだね"], settings: .none) == ["…", "あああああああ", "そうだね"])
    }
}
