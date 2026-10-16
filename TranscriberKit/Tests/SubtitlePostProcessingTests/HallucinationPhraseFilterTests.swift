import Testing
import TranscriberCore
@testable import SubtitlePostProcessing

struct HallucinationPhraseFilterTests {
    private static let tenMinutes = AudioTime(seconds: 600)

    private static func line(_ startSeconds: Double, _ endSeconds: Double, _ text: String) -> TimedText {
        TimedText(start: AudioTime(seconds: startSeconds), end: AudioTime(seconds: endSeconds), text: text)
    }

    private static func dialogueAround(_ text: String, at startSeconds: Double) -> [TimedText] {
        [
            line(startSeconds - 1.5, startSeconds - 0.5, "そうなんだ"),
            line(startSeconds, startSeconds + 2, text),
            line(startSeconds + 2.5, startSeconds + 3.5, "またね"),
        ]
    }

    @Test(arguments: [
        "ご視聴ありがとうございました",
        "ご視聴、ありがとうございました！",
        "最後までご視聴いただきありがとうございました。",
        "チャンネル登録よろしくお願いします",
        "ご視聴ありがとうございました。チャンネル登録お願いします",
        "高評価とチャンネル登録をお願いします",
        "字幕制作：山田",
        "字幕由Amara.org社区提供",
        "请不吝点赞 订阅 转发 打赏支持明镜与点点栏目",
        "中文字幕by某某",
    ])
    func dropsCreditsAnywhere(_ text: String) {
        let lines = Self.dialogueAround(text, at: 300)
        #expect(HallucinationPhraseFilter.filtered(lines, audioDuration: Self.tenMinutes).map(\.text) == ["そうなんだ", "またね"])
    }

    @Test(arguments: [
        "チャンネル登録したの？",
        "字幕を見て",
        "ありがとうございます",
        "今日はありがとうございました、また来てね",
        "谢谢你来看我",
    ])
    func keepsDialogue(_ text: String) {
        let lines = [Self.line(0, 2, text)]
        #expect(HallucinationPhraseFilter.filtered(lines, audioDuration: Self.tenMinutes) == lines)
    }

    @Test(arguments: ["ありがとうございました", "お疲れ様でした", "谢谢观看", "谢谢大家"])
    func dropsClosingAloneNearAnEnd(_ text: String) {
        let lines = [Self.line(10, 20, "はじめましょう"), Self.line(595, 597, text)]
        #expect(HallucinationPhraseFilter.filtered(lines, audioDuration: Self.tenMinutes).map(\.text) == ["はじめましょう"])
    }

    @Test func keepsClosingInConversation() {
        let lines = Self.dialogueAround("ありがとうございました", at: 590)
        #expect(HallucinationPhraseFilter.filtered(lines, audioDuration: Self.tenMinutes) == lines)
    }

    @Test func keepsClosingAloneMidway() {
        let lines = [Self.line(100, 101, "ねえ"), Self.line(300, 302, "ありがとうございました"), Self.line(400, 401, "うん")]
        #expect(HallucinationPhraseFilter.filtered(lines, audioDuration: Self.tenMinutes) == lines)
    }
}
