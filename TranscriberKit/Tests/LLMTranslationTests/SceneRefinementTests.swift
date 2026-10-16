import Foundation
import Synchronization
import Testing
import TranscriberCore
@testable import LLMTranslation

/// Answers every line with "T<id>" and summarizes each batch as "batch <first id>".
final class SummarizingModel: StructuredChatCompleting {
    private let requests = Mutex<[String]>([])

    /// The user payloads in the order they arrived.
    var payloads: [[String: Any]] {
        requests.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] }
    }

    func completeJSON(model: String, messages: [ChatMessage], schemaName: String, schema: [String: any Sendable], temperature: Double) async throws -> Data {
        let payload = try JSONSerialization.jsonObject(with: Data(messages[1].content.utf8)) as? [String: Any] ?? [:]
        requests.withLock { $0.append(messages[1].content) }
        let ids = (payload["lines"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? Int }
        let first = ids.first ?? -1
        let scene = ((payload["scene_so_far"] as? String).map { $0 + " + " } ?? "") + "batch \(first)"
        return try JSONSerialization.data(withJSONObject: [
            "lines": ids.map { ["id": $0, "text": "T\($0)"] },
            "batch_summary": "batch \(first)",
            "scene_summary": scene,
        ])
    }
}

struct SceneRefinementTests {
    private static func lines(starts: [Double]) -> [TimedText] {
        starts.enumerated().map { index, start in
            TimedText(start: AudioTime(seconds: start), end: AudioTime(seconds: start + 1), text: "line \(index)")
        }
    }

    private static func configuration() -> SubtitleRefiner.Configuration {
        var configuration = SubtitleRefiner.Configuration(model: "test/model")
        configuration.batchSize = 2
        configuration.contextLineCount = 1
        configuration.maximumBatchesPerScene = 2
        return configuration
    }

    @Test func plansScenesAtLongPausesAndSplitsLongScenes() {
        // Lines 0–4 close together, then a 200 s pause before 5–6.
        let segments = Self.lines(starts: [0, 2, 4, 6, 8, 210, 212])
        let plan = RefinementPlan(lineIndices: Array(0..<7), of: segments, batchSize: 2, sceneGap: AudioTime(seconds: 120), maximumBatchesPerScene: 2)
        #expect(plan.scenes == [[[0, 1], [2, 3]], [[4]], [[5, 6]]])
    }

    @Test func plansOnlyTheChosenLines() {
        let segments = Self.lines(starts: [0, 2, 4, 6, 8])
        let plan = RefinementPlan(lineIndices: [1, 3, 4], of: segments, batchSize: 10, sceneGap: AudioTime(seconds: 120), maximumBatchesPerScene: 5)
        #expect(plan.scenes == [[[1]], [[3, 4]]])
    }

    @Test func laterBatchesCarryTheSceneSoFar() async throws {
        let model = SummarizingModel()
        let result = try await SubtitleRefiner(client: model, configuration: Self.configuration())
            .refine(Self.lines(starts: [0, 2, 4, 6]), job: .translate(targetLanguage: "English"))

        #expect(result.segments.map(\.text) == ["T0", "T1", "T2", "T3"])
        let second = try #require(model.payloads.first { ($0["lines"] as? [[String: Any]])?.first?["id"] as? Int == 2 })
        #expect(second["scene_so_far"] as? String == "batch 0")
        #expect(second["earlier_batches"] as? [String] == ["batch 0"])
        let first = try #require(model.payloads.first { ($0["lines"] as? [[String: Any]])?.first?["id"] as? Int == 0 })
        #expect(first["scene_so_far"] == nil)
    }

    @Test func retranslatesOnlyChosenLinesWithTheirNeighborsAsContext() async throws {
        let model = SummarizingModel()
        let segments = Self.lines(starts: [0, 2, 4, 6])
        let result = try await SubtitleRefiner(client: model, configuration: Self.configuration())
            .refine(segments, job: .translate(targetLanguage: "English"), lineIndices: [2])

        #expect(result.segments.map(\.text) == ["line 0", "line 1", "T2", "line 3"])
        #expect(result.batchCount == 1)
        let payload = try #require(model.payloads.only)
        #expect((payload["context_before"] as? [[String: Any]])?.map { $0["text"] as? String } == ["line 1"])
        #expect((payload["context_after"] as? [[String: Any]])?.map { $0["text"] as? String } == ["line 3"])
    }

    @Test func aSecondRunReusesCachedReplies() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let segments = Self.lines(starts: [0, 2, 4])
        let firstModel = SummarizingModel()
        _ = try await SubtitleRefiner(client: firstModel, configuration: Self.configuration(), cache: LLMReplyCache(directory: directory))
            .refine(segments, job: .polishChinese)

        let secondModel = SummarizingModel()
        let refiner = SubtitleRefiner(client: secondModel, configuration: Self.configuration(), cache: LLMReplyCache(directory: directory))
        let resumed = try await refiner.refine(segments, job: .polishChinese)
        #expect(resumed.segments.map(\.text) == ["T0", "T1", "T2"])
        #expect(resumed.reusedBatchCount == 2)
        #expect(secondModel.payloads.isEmpty)

        let asked = try await refiner.refine(segments, job: .polishChinese, lineIndices: [0, 1], reusesCachedReplies: false)
        #expect(asked.reusedBatchCount == 0)
        #expect(secondModel.payloads.count == 1)
    }
}

private extension Array {
    var only: Element? {
        count == 1 ? first : nil
    }
}
