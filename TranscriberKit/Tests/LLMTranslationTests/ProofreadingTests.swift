import Foundation
import Testing
import TranscriberCore
@testable import LLMTranslation

/// Proofread Selected Lines: Japanese lines with mishearings fixed, nothing translated.
struct ProofreadingTests {
    private static let lines = [
        TimedText(start: .zero, end: AudioTime(seconds: 1), text: "お兄ちゃん、おはよう"),
        TimedText(start: AudioTime(seconds: 2), end: AudioTime(seconds: 3), text: "今日は天気がいい"),
        TimedText(start: AudioTime(seconds: 4), end: AudioTime(seconds: 5), text: "ゆいちゃんと遊ぶ"),
    ]

    @Test func asksOnlyForMishearingsAndKeepsOtherLinesAsContext() async throws {
        let model = StubModel { lines, _ in lines.map { ($0.id, $0.text.replacingOccurrences(of: "ゆい", with: "結衣")) } }
        let result = try await SubtitleRefiner(client: model, configuration: SubtitleRefiner.Configuration(model: "test/model"))
            .refine(Self.lines, job: .proofreadJapanese, lineIndices: [2], reusesCachedReplies: false)

        #expect(result.segments.map(\.text) == ["お兄ちゃん、おはよう", "今日は天気がいい", "結衣ちゃんと遊ぶ"])
        let request = try #require(model.recordedRequests.first)
        let system = request[0].content
        #expect(system.contains("proofread Japanese subtitles"))
        #expect(system.contains("do not translate"))
        #expect(system.contains("fillers"))
        let payload = try JSONSerialization.jsonObject(with: Data(request[1].content.utf8)) as? [String: Any]
        #expect((payload?["lines"] as? [[String: Any]])?.map { $0["id"] as? Int } == [2])
        #expect((payload?["context_before"] as? [[String: Any]])?.count == 2)
    }

    @Test func glossaryGivesOnlyTheJapaneseSpellings() {
        let system = SubtitlePrompt.systemMessage(for: .proofreadJapanese, glossary: [("結衣", "结衣"), ("先輩", "前辈")])
        #expect(system.contains("- 結衣"))
        #expect(system.contains("- 先輩"))
        #expect(!system.contains("前辈"))
        #expect(!system.contains("→"))
    }
}
