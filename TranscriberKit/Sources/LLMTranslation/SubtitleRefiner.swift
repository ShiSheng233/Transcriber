import Foundation
import TranscriberCore

/// Polishes or translates subtitle text with a language model, batch by batch.
///
/// Times never change: only each line's text is replaced. Every batch is sent
/// with a few lines of context on both sides; the reply must return exactly
/// the batch's ids. A reply that does not is retried once, after which lines
/// the model did not return keep their original text.
public struct SubtitleRefiner: Sendable {
    public enum Job: Sendable {
        case polishChinese
        case translate(targetLanguage: String)
    }

    public struct Configuration: Sendable {
        public var model: String
        public var batchSize = 40
        public var contextLineCount = 8
        public var temperature = 0.3

        public init(model: String) {
            self.model = model
        }
    }

    private let client: any StructuredChatCompleting
    private let configuration: Configuration

    public init(client: any StructuredChatCompleting, configuration: Configuration) {
        self.client = client
        self.configuration = configuration
    }

    /// - Parameter progress: called with (finished batches, total batches).
    public func refine(
        _ segments: [TimedText],
        job: Job,
        glossary: [(source: String, target: String)] = [],
        progress: @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> [TimedText] {
        guard !segments.isEmpty else {
            return []
        }
        let promptJob: SubtitlePrompt.Job = switch job {
        case .polishChinese: .polishChinese
        case .translate(let language): .translate(targetLanguage: language)
        }
        let system = ChatMessage(role: .system, content: SubtitlePrompt.systemMessage(for: promptJob, glossary: glossary))

        var refinedTexts = segments.map(\.text)
        let batchStarts = Array(stride(from: 0, to: segments.count, by: configuration.batchSize))
        for (batchIndex, start) in batchStarts.enumerated() {
            try Task.checkCancellation()
            let batch = start..<min(start + configuration.batchSize, segments.count)
            // Before the batch: already refined lines, so wording carries over.
            let contextBefore = Array(refinedTexts[max(0, start - configuration.contextLineCount)..<start])
            let contextAfter = segments[batch.upperBound..<min(batch.upperBound + configuration.contextLineCount, segments.count)].map(\.text)
            let lines = batch.map { (id: $0, text: segments[$0].text) }

            let replies = try await requestLines(lines, system: system, contextBefore: contextBefore, contextAfter: contextAfter)
            for index in batch {
                if let text = replies[index], !text.pythonStripped.isEmpty {
                    refinedTexts[index] = text
                }
            }
            progress(batchIndex + 1, batchStarts.count)
        }

        return zip(segments, refinedTexts).map { segment, text in
            TimedText(start: segment.start, end: segment.end, text: text)
        }
    }

    /// The reply's text per id; asks once more if the ids do not match.
    private func requestLines(
        _ lines: [(id: Int, text: String)],
        system: ChatMessage,
        contextBefore: [String],
        contextAfter: [String]
    ) async throws -> [Int: String] {
        let expectedIDs = Set(lines.map(\.id))
        let user = ChatMessage(role: .user, content: try SubtitlePrompt.userMessage(lines: lines, contextBefore: contextBefore, contextAfter: contextAfter))
        var bestReply: [Int: String] = [:]
        for _ in 0..<2 {
            let data = try await client.completeJSON(
                model: configuration.model,
                messages: [system, user],
                schemaName: SubtitlePrompt.schemaName,
                schema: SubtitlePrompt.schema,
                temperature: configuration.temperature
            )
            let reply = Self.decode(data).filter { expectedIDs.contains($0.key) }
            if reply.count > bestReply.count {
                bestReply = reply
            }
            if Set(reply.keys) == expectedIDs {
                return reply
            }
        }
        return bestReply
    }

    private static func decode(_ data: Data) -> [Int: String] {
        struct Reply: Decodable {
            struct Line: Decodable {
                let id: Int
                let text: String
            }

            let lines: [Line]
        }
        guard let reply = try? JSONDecoder().decode(Reply.self, from: data) else {
            return [:]
        }
        // A repeated id keeps its first text.
        return Dictionary(reply.lines.map { ($0.id, $0.text) }, uniquingKeysWith: { first, _ in first })
    }
}

extension Array where Element == TimedText {
    /// Bilingual lines: each translation followed by its original on the next line.
    public func withOriginalLines(from originals: [TimedText]) -> [TimedText] {
        zip(self, originals).map { translated, original in
            TimedText(start: translated.start, end: translated.end, text: "\(translated.text)\n\(original.text)")
        }
    }
}
