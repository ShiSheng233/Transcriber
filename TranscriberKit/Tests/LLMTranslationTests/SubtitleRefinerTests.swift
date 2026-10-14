import Foundation
import Synchronization
import Testing
import TranscriberCore
@testable import LLMTranslation

/// A model stand-in that records requests and answers with a closure.
final class StubModel: StructuredChatCompleting {
    private let requests = Mutex<[[ChatMessage]]>([])
    private let answer: @Sendable (_ lines: [(id: Int, text: String)], _ attempt: Int) -> [(id: Int, text: String)]

    init(answer: @escaping @Sendable (_ lines: [(id: Int, text: String)], _ attempt: Int) -> [(id: Int, text: String)]) {
        self.answer = answer
    }

    var recordedRequests: [[ChatMessage]] {
        requests.withLock { $0 }
    }

    func completeJSON(model: String, messages: [ChatMessage], schemaName: String, schema: [String: any Sendable], temperature: Double) async throws -> Data {
        let attempt = requests.withLock { requests in
            requests.append(messages)
            return requests.count
        }
        let payload = try JSONSerialization.jsonObject(with: Data(messages[1].content.utf8)) as? [String: Any]
        let lines = (payload?["lines"] as? [[String: Any]] ?? []).compactMap { line -> (id: Int, text: String)? in
            guard let id = line["id"] as? Int, let text = line["text"] as? String else { return nil }
            return (id, text)
        }
        let reply = ["lines": answer(lines, attempt).map { ["id": $0.id, "text": $0.text] }]
        return try JSONSerialization.data(withJSONObject: reply)
    }
}

struct SubtitleRefinerTests {
    private static func segments(_ count: Int) -> [TimedText] {
        (0..<count).map { TimedText(start: AudioTime(seconds: Double($0)), end: AudioTime(seconds: Double($0) + 0.8), text: "line \($0)") }
    }

    private static func configuration(batchSize: Int, context: Int = 2) -> SubtitleRefiner.Configuration {
        var configuration = SubtitleRefiner.Configuration(model: "test/model")
        configuration.batchSize = batchSize
        configuration.contextLineCount = context
        return configuration
    }

    @Test func replacesTextAndKeepsTimes() async throws {
        let model = StubModel { lines, _ in lines.map { ($0.id, $0.text.uppercased()) } }
        let segments = Self.segments(5)
        let refined = try await SubtitleRefiner(client: model, configuration: Self.configuration(batchSize: 2))
            .refine(segments, job: .polishChinese)

        #expect(refined.map(\.text) == segments.map { $0.text.uppercased() })
        #expect(refined.map(\.start) == segments.map(\.start))
        #expect(refined.map(\.end) == segments.map(\.end))
        #expect(model.recordedRequests.count == 3)  // batches of 2, 2, 1
    }

    @Test func sendsRefinedContextBeforeAndOriginalContextAfter() async throws {
        let model = StubModel { lines, _ in lines.map { ($0.id, "R\($0.id)") } }
        _ = try await SubtitleRefiner(client: model, configuration: Self.configuration(batchSize: 2, context: 2))
            .refine(Self.segments(6), job: .translate(targetLanguage: "English"))

        let secondBatch = try JSONSerialization.jsonObject(with: Data(model.recordedRequests[1][1].content.utf8)) as? [String: Any]
        #expect(secondBatch?["context_before"] as? [String] == ["R0", "R1"])
        #expect(secondBatch?["context_after"] as? [String] == ["line 4", "line 5"])
        #expect(model.recordedRequests[0][0].content.contains("into English"))
    }

    @Test func retriesOnceWhenIDsDoNotMatch() async throws {
        let model = StubModel { lines, attempt in
            attempt == 1 ? Array(lines.map { ($0.id, "partial") }.dropLast()) : lines.map { ($0.id, "complete") }
        }
        let refined = try await SubtitleRefiner(client: model, configuration: Self.configuration(batchSize: 10))
            .refine(Self.segments(3), job: .polishChinese)
        #expect(refined.map(\.text) == ["complete", "complete", "complete"])
        #expect(model.recordedRequests.count == 2)
    }

    @Test func keepsOriginalTextForLinesTheModelNeverReturns() async throws {
        // Always drops the last line and invents an id that was not asked for.
        let model = StubModel { lines, _ in Array(lines.map { ($0.id, "new") }.dropLast()) + [(999, "invented")] }
        let refined = try await SubtitleRefiner(client: model, configuration: Self.configuration(batchSize: 10))
            .refine(Self.segments(3), job: .polishChinese)
        #expect(refined.map(\.text) == ["new", "new", "line 2"])
    }

    @Test func blankRepliesKeepTheOriginal() async throws {
        let model = StubModel { lines, _ in lines.map { ($0.id, "  ") } }
        let refined = try await SubtitleRefiner(client: model, configuration: Self.configuration(batchSize: 10))
            .refine(Self.segments(2), job: .polishChinese)
        #expect(refined.map(\.text) == ["line 0", "line 1"])
    }

    @Test func glossaryReachesTheInstructions() async throws {
        let model = StubModel { lines, _ in lines }
        var settings = LLMSettings.defaults
        settings.glossary = "お兄ちゃん = 哥哥\nbroken line\n先輩=前辈"
        _ = try await SubtitleRefiner(client: model, configuration: Self.configuration(batchSize: 10))
            .refine(Self.segments(1), job: .polishChinese, glossary: settings.glossaryEntries)
        let system = model.recordedRequests[0][0].content
        #expect(system.contains("お兄ちゃん → 哥哥"))
        #expect(system.contains("先輩 → 前辈"))
        #expect(settings.glossaryEntries.count == 2)
    }

    @Test func bilingualLinesPutTheOriginalUnderneath() {
        let original = [TimedText(start: .zero, end: AudioTime(seconds: 1), text: "こんにちは")]
        let translated = [TimedText(start: .zero, end: AudioTime(seconds: 1), text: "你好")]
        #expect(translated.withOriginalLines(from: original).map(\.text) == ["你好\nこんにちは"])
    }
}
