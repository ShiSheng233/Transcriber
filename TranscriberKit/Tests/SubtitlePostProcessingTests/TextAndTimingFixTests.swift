import Testing
import TranscriberCore
@testable import SubtitlePostProcessing

struct TextAndTimingFixTests {
    @Test(arguments: [
        ("ｶﾞﾝﾊﾞﾚ", "ガンバレ"),
        ("ＡＢＣ１２３", "ABC123"),
        ("そうなの・・・", "そうなの…"),
        ("待って...", "待って…"),
        ("本当?!", "本当？！"),
        ("えっ~", "えっ〜"),
        ("今日は いい 天気", "今日はいい天気"),
        ("Hello world!", "Hello world!"),  // Latin text keeps its spaces and marks
        ("～ね！", "～ね！"),  // full-width marks stay (no NFKC)
    ])
    func normalizesWithoutNFKC(_ input: String, _ expected: String) {
        #expect(JapaneseTextNormalizer.normalized(input) == expected)
    }

    @Test(arguments: [
        ("ああああああ", "ああ"),
        ("すごーーーい", "すごーい"),
        ("えっっっ", "えっ"),
        ("なにそれ！！！！", "なにそれ！！"),
        ("………", "……"),
        ("ダメダメダメダメ", "ダメダメ"),
        ("ああ、そう", "ああ、そう"),
    ])
    func shortensStretchedSounds(_ input: String, _ expected: String) {
        #expect(StretchedSoundShortener.shortened(input) == expected)
    }

    @Test func repairsLinesThatLoop() {
        #expect(LineLoopRepair.repaired("好きです好きです好きです好きです") == "好きです好きです…")
        #expect(LineLoopRepair.repaired("ねえ、聞いてあなたが好きあなたが好きあなたが好き") == "ねえ、聞いてあなたが好きあなたが好き…")
        #expect(LineLoopRepair.repaired("今日はとても楽しかったです、また来ます") == "今日はとても楽しかったです、また来ます")
        #expect(LineLoopRepair.repaired("短い短い") == "短い短い")  // too short to judge
    }

    @Test func recognizesFillerOnlyLines() {
        #expect(FillerLineFilter.isFillerOnly("えーと、あの…"))
        #expect(FillerLineFilter.isFillerOnly("うーん"))
        #expect(!FillerLineFilter.isFillerOnly("うん"))
        #expect(!FillerLineFilter.isFillerOnly("あの人"))
        #expect(!FillerLineFilter.isFillerOnly("…"))
    }

    @Test func makesTimingReadable() {
        func line(_ start: Int, _ end: Int) -> TimedText {
            TimedText(start: AudioTime(milliseconds: start), end: AudioTime(milliseconds: end), text: "x")
        }
        let fixed = SubtitleTimingFixer.fixed([line(0, 300), line(500, 9_000), line(9_200, 10_000), line(20_000, 20_100)])
        #expect(fixed[0] == line(0, 500))  // extended, but not past the next start
        #expect(fixed[1] == line(500, 7_500))  // capped at 7 s
        #expect(fixed[2] == line(9_200, 10_033))  // 800 ms is under the minimum
        #expect(fixed[3] == line(20_000, 20_833))
        let gap = SubtitleTimingFixer.fixed([line(0, 1_000), line(1_200, 2_000)])
        #expect(gap[0].end == AudioTime(milliseconds: 1_117))  // gap closed to two frames
    }
}
