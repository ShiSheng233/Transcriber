import Testing
import TranscriberCore
@testable import SubtitlePostProcessing

struct SubtitleFilterTests {
    private static func line(_ startMilliseconds: Int, _ endMilliseconds: Int, _ text: String) -> TimedText {
        TimedText(start: AudioTime(milliseconds: startMilliseconds), end: AudioTime(milliseconds: endMilliseconds), text: text)
    }

    @Test(arguments: ["…", "……？", "♪", "♪～♪", "あっ…♡", "はぁ、はぁ", "んっ", "[喘ぎ声]", "(moans)", "【音楽 laugh】", "嗯…啊", "mmm"])
    func recognizesVocalSounds(_ text: String) {
        #expect(NonverbalLineFilter.isNonverbal(text))
    }

    @Test(arguments: ["はい、そうです", "あなた", "他喘不过气来", "笑", "ありがとう", "おはよう", "music box の話"])
    func keepsSpeech(_ text: String) {
        #expect(!NonverbalLineFilter.isNonverbal(text))
    }

    @Test func mergesThreeIdenticalLinesInARow() {
        let merged = RepeatedLineMerger.merged([
            Self.line(0, 1_000, "やめて"),
            Self.line(1_200, 2_000, "やめて"),
            Self.line(2_500, 3_000, " やめて "),
            Self.line(3_100, 4_000, "だめ"),
        ])
        #expect(merged == [Self.line(0, 3_000, "やめて"), Self.line(3_100, 4_000, "だめ")])
    }

    @Test func keepsTwoRepeatsAndRepeatsFarApart() {
        let pair = [Self.line(0, 1_000, "うん"), Self.line(1_100, 2_000, "うん")]
        #expect(RepeatedLineMerger.merged(pair) == pair)
        let spaced = [Self.line(0, 1_000, "うん"), Self.line(1_600, 2_000, "うん"), Self.line(2_100, 3_000, "うん")]
        #expect(RepeatedLineMerger.merged(spaced) == spaced)
    }

    @Test func dropsImplausibleReadingSpeeds() {
        let kept = ReadingSpeedFilter.filtered([
            Self.line(0, 1_000, "あいうえおかきくけこさしすせそたちつてと"),  // 20 cps
            Self.line(1_000, 2_000, "あいうえおかきくけこさしすせそたちつてとなにぬねのはひふへほまみむめもや"),  // 31 cps
            Self.line(2_000, 5_700, "息子"),  // 0.54 cps
            Self.line(6_000, 9_000, "そうなんですね"),  // 7 characters: never too slow
            Self.line(9_000, 10_000, "！？"),  // no letters
            Self.line(10_000, 11_000, "2025"),
        ])
        #expect(kept.map(\.text) == ["あいうえおかきくけこさしすせそたちつてと", "そうなんですね", "2025"])
    }

    @Test func noneLeavesSubtitlesAlone() {
        let lines = [Self.line(0, 100, "…"), Self.line(0, 100, "…"), Self.line(0, 100, "…")]
        #expect(SubtitleFilter.apply(lines, settings: .none) == lines)
    }
}
