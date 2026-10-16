import Foundation
import Synchronization
import Testing
import TranscriberCore
@testable import LLMTranslation

/// Marks lines containing "ご視聴" as not speech, and records what it was sent.
private final class DroppingModel: StructuredChatCompleting {
    private let requests = Mutex<[(messages: [ChatMessage], schema: [String: any Sendable])]>([])

    var recorded: [(messages: [ChatMessage], schema: [String: any Sendable])] {
        requests.withLock { $0 }
    }

    func completeJSON(model: String, messages: [ChatMessage], schemaName: String, schema: [String: any Sendable], temperature: Double) async throws -> Data {
        requests.withLock { $0.append((messages, schema)) }
        let payload = try JSONSerialization.jsonObject(with: Data(messages[1].content.utf8)) as? [String: Any]
        let lines = payload?["lines"] as? [[String: Any]] ?? []
        let reply = lines.map { line -> [String: Any] in
            let text = line["text"] as? String ?? ""
            return ["id": line["id"] ?? 0, "text": "fixed " + text, "drop": text.contains("ご視聴")]
        }
        return try JSONSerialization.data(withJSONObject: ["lines": reply])
    }
}

struct HallucinationRemovalTests {
    private static let doubtful = RecognitionConfidence(averageLogProbability: -1.4, noSpeechProbability: 0.6, compressionRatio: 1.1, isDoubtful: true)

    private static let lines = [
        TimedText(start: .zero, end: AudioTime(seconds: 1), text: "おはよう"),
        TimedText(start: AudioTime(seconds: 2), end: AudioTime(seconds: 3), text: "ご視聴ありがとうございました", confidence: doubtful),
    ]

    @Test func reportsLinesMarkedAsNotSpeech() async throws {
        let model = DroppingModel()
        var configuration = SubtitleRefiner.Configuration(model: "test/model")
        configuration.marksHallucinations = true
        let result = try await SubtitleRefiner(client: model, configuration: configuration).refine(Self.lines, job: .proofread)

        #expect(result.droppedLines == [1])
        #expect(result.segments.map(\.text) == ["fixed おはよう", "ご視聴ありがとうございました"])  // a dropped line keeps its text
        let request = try #require(model.recorded.first)
        #expect(request.messages[0].content.contains("\"drop\""))
        #expect(request.messages[1].content.contains("\"doubtful\":true"))
        let items = ((request.schema["properties"] as? [String: any Sendable])?["lines"] as? [String: any Sendable])?["items"] as? [String: any Sendable]
        #expect((items?["required"] as? [String]) == ["id", "text", "drop"])
    }

    @Test func ignoresDropMarksUnlessAskedFor() async throws {
        let model = DroppingModel()
        let result = try await SubtitleRefiner(client: model, configuration: SubtitleRefiner.Configuration(model: "test/model"))
            .refine(Self.lines, job: .proofread)
        #expect(result.droppedLines.isEmpty)
        #expect(result.segments[1].text == "fixed ご視聴ありがとうございました")
        #expect(result.segments[1].confidence == Self.doubtful)  // the refiner keeps what it does not change
        #expect(!(model.recorded.first?.messages[0].content.contains("\"drop\"") ?? true))
    }
}
