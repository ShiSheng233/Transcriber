import Foundation
import Synchronization
import Testing
import TranscriberCore
@testable import LLMTranslation

/// Answers every line with "R<id>", optionally prefixed by a time, and adds
/// fields a loose server might send; records the requests.
private final class TimeEchoingModel: StructuredChatCompleting {
    private let requests = Mutex<[[ChatMessage]]>([])
    private let prefixesTime: Bool

    init(prefixesTime: Bool) {
        self.prefixesTime = prefixesTime
    }

    var bodies: [[String: Any]] {
        requests.withLock { $0 }.compactMap { try? JSONSerialization.jsonObject(with: Data($0[1].content.utf8)) as? [String: Any] }
    }

    func completeJSON(model: String, messages: [ChatMessage], schemaName: String, schema: [String: any Sendable], temperature: Double) async throws -> Data {
        requests.withLock { $0.append(messages) }
        let payload = try JSONSerialization.jsonObject(with: Data(messages[1].content.utf8)) as? [String: Any]
        let lines = (payload?["lines"] as? [[String: Any]] ?? []).map { line -> [String: Any] in
            let id = line["id"] as? Int ?? 0
            return ["id": id, "text": (prefixesTime ? "[0:00.0] " : "") + "R\(id)", "start": "9:99.9", "end": "0:00.0"]
        }
        return try JSONSerialization.data(withJSONObject: ["lines": lines])
    }
}

struct LLMContextAndTimesTests {
    private static func segments(_ count: Int) -> [TimedText] {
        (0..<count).map { TimedText(start: AudioTime(seconds: Double($0 * 2)), end: AudioTime(seconds: Double($0 * 2) + 1.5), text: "line \($0)") }
    }

    private static func refiner(_ model: TimeEchoingModel, batchSize: Int) -> SubtitleRefiner {
        var configuration = SubtitleRefiner.Configuration(model: "test/model")
        configuration.batchSize = batchSize
        configuration.contextLineCount = 2
        return SubtitleRefiner(client: model, configuration: configuration)
    }

    @Test func sendsTimesAndTheSceneAnswersAsContext() async throws {
        let model = TimeEchoingModel(prefixesTime: false)
        _ = try await Self.refiner(model, batchSize: 2).refine(Self.segments(4), job: .polishChinese)
        let bodies = model.bodies
        let first = try #require(bodies.first { (($0["lines"] as? [[String: Any]])?.first?["id"] as? Int) == 0 })
        #expect((first["lines"] as? [[String: Any]])?[1]["start"] as? String == "0:02.0")
        #expect((first["lines"] as? [[String: Any]])?[1]["end"] as? String == "0:03.5")
        // One scene: the second batch sees what the first one wrote for its context.
        let second = try #require(bodies.first { (($0["lines"] as? [[String: Any]])?.first?["id"] as? Int) == 2 })
        let before = second["context_before"] as? [[String: Any]]
        #expect(before?.map { $0["text"] as? String } == ["line 0", "line 1"])
        #expect(before?.map { $0["output"] as? String } == ["R0", "R1"])
    }

    @Test func neverTakesTimesFromTheModel() async throws {
        let segments = Self.segments(3)
        let result = try await Self.refiner(TimeEchoingModel(prefixesTime: true), batchSize: 10).refine(segments, job: .translate(targetLanguage: "English"))
        #expect(result.segments.map(\.start) == segments.map(\.start))
        #expect(result.segments.map(\.end) == segments.map(\.end))
        #expect(result.segments.map(\.text) == ["R0", "R1", "R2"])  // the time it wrote into the text is gone
    }

    @Test func keepsATimeTheOriginalHad() {
        #expect(SubtitlePrompt.removingAddedTime(from: "10:30に会おう", original: "10:30に会おう") == "10:30に会おう")
        #expect(SubtitlePrompt.removingAddedTime(from: "[1:23.4] こんにちは", original: "こんにちは") == "こんにちは")
        #expect(SubtitlePrompt.removingAddedTime(from: "0:01.0–0:02.5 Hi", original: "やあ") == "Hi")
    }

    @Test func cachesBySentTextAndTimesNotEarlierAnswers() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("LLMCacheTest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = LLMReplyCache(directory: directory)
        var configuration = SubtitleRefiner.Configuration(model: "test/model")
        configuration.batchSize = 2
        let segments = Self.segments(4)

        let firstModel = TimeEchoingModel(prefixesTime: false)
        _ = try await SubtitleRefiner(client: firstModel, configuration: configuration, cache: cache).refine(segments, job: .polishChinese)
        let againModel = TimeEchoingModel(prefixesTime: false)
        let again = try await SubtitleRefiner(client: againModel, configuration: configuration, cache: cache).refine(segments, job: .polishChinese)
        #expect(againModel.bodies.isEmpty && again.reusedBatchCount == 2)

        var moved = segments
        moved[3].end = AudioTime(seconds: 9)
        let movedModel = TimeEchoingModel(prefixesTime: false)
        _ = try await SubtitleRefiner(client: movedModel, configuration: configuration, cache: cache).refine(moved, job: .polishChinese)
        // Asked again: the batch with the moved line, and the one that has it as context.
        #expect(movedModel.bodies.count == 2)
    }
}
