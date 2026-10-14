import Foundation
import TranscriberCore

/// Polishes or translates subtitle text with a language model, a few batches
/// at a time.
///
/// Times never change: only each line's text is replaced. Every batch is sent
/// with a few original lines of context on both sides; the reply must return
/// exactly the batch's ids. A reply that does not is retried once, after which
/// lines the model did not return keep their original text. A batch whose
/// request fails keeps its original lines and is counted in the result; a
/// rejected key, no credits, or every batch failing ends the whole run.
public struct SubtitleRefiner: Sendable {
    public enum Job: Sendable {
        case polishChinese
        case translate(targetLanguage: String)
        /// Existing subtitles in any language, e.g. imported from a file.
        case translateSubtitles(targetLanguage: String)
    }

    public struct Configuration: Sendable {
        public var model: String
        public var batchSize = 40
        public var contextLineCount = 8
        /// Batches in flight at once. Their "before" context is the original
        /// text, since earlier batches may not be done yet.
        public var concurrentBatchCount = 4
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

    public struct Result: Sendable {
        public let segments: [TimedText]
        /// Batches that kept their original text because the request failed.
        public let failedBatchCount: Int
        public let batchCount: Int
        /// The error of a failed batch, for a warning.
        public let firstFailure: String?
    }

    /// - Parameter progress: called with (finished batches, total batches).
    public func refine(
        _ segments: [TimedText],
        job: Job,
        glossary: [(source: String, target: String)] = [],
        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }
    ) async throws -> Result {
        guard !segments.isEmpty else {
            return Result(segments: [], failedBatchCount: 0, batchCount: 0, firstFailure: nil)
        }
        let promptJob: SubtitlePrompt.Job = switch job {
        case .polishChinese: .polishChinese
        case .translate(let language): .translate(targetLanguage: language)
        case .translateSubtitles(let language): .translateSubtitles(targetLanguage: language)
        }
        let system = ChatMessage(role: .system, content: SubtitlePrompt.systemMessage(for: promptJob, glossary: glossary))

        let batches = stride(from: 0, to: segments.count, by: configuration.batchSize).map {
            $0..<min($0 + configuration.batchSize, segments.count)
        }
        var refinedTexts = segments.map(\.text)
        var failures: [any Error] = []

        try await withThrowingTaskGroup(of: (Range<Int>, Swift.Result<[Int: String], any Error>).self) { group in
            var next = 0
            func startNextBatch() {
                let batch = batches[next]
                next += 1
                let contextBefore = segments[max(0, batch.lowerBound - configuration.contextLineCount)..<batch.lowerBound].map(\.text)
                let contextAfter = segments[batch.upperBound..<min(batch.upperBound + configuration.contextLineCount, segments.count)].map(\.text)
                let lines = batch.map { (id: $0, text: segments[$0].text) }
                group.addTask {
                    do {
                        return (batch, .success(try await requestLines(lines, system: system, contextBefore: contextBefore, contextAfter: contextAfter)))
                    } catch let error where Self.endsTheRun(error) {
                        throw error
                    } catch {
                        return (batch, .failure(error))
                    }
                }
            }
            while next < min(max(configuration.concurrentBatchCount, 1), batches.count) {
                startNextBatch()
            }
            var finished = 0
            while let (batch, outcome) = try await group.next() {
                switch outcome {
                case .success(let replies):
                    for index in batch {
                        if let text = replies[index], !text.pythonStripped.isEmpty {
                            refinedTexts[index] = text
                        }
                    }
                case .failure(let error):
                    failures.append(error)
                }
                finished += 1
                progress(finished, batches.count)
                if next < batches.count {
                    startNextBatch()
                }
            }
        }
        if failures.count == batches.count, let error = failures.first {
            throw error  // nothing came back: the run failed
        }

        let refined = zip(segments, refinedTexts).map { segment, text in
            TimedText(start: segment.start, end: segment.end, text: text)
        }
        return Result(
            segments: refined,
            failedBatchCount: failures.count,
            batchCount: batches.count,
            firstFailure: failures.first?.localizedDescription
        )
    }

    /// Errors no other batch can avoid.
    private static func endsTheRun(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, LLMServiceError.invalidAPIKey, LLMServiceError.insufficientCredits: true
        default: false
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
