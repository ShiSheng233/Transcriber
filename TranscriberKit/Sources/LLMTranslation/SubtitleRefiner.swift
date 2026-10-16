import Foundation
import Synchronization
import TranscriberCore

/// Polishes or translates subtitle text with a language model.
///
/// Times never change: the model sees each line's start and end to judge
/// pauses and pace, but its reply has no place for times, and only each
/// line's text is replaced (a time it writes into the text is removed).
/// Lines are sent in batches with a few lines of context on both sides;
/// context lines the scene already answered carry that answer too. Within a
/// scene (lines without a long pause) batches go one after another, each
/// with the summaries the model wrote for the earlier ones; scenes run at
/// the same time. The reply must return exactly the batch's ids: one that
/// does not is retried once, after which lines the model did not return keep
/// their original text. A batch whose request fails keeps its original lines
/// and is counted in the result; a rejected key, no credits, or every batch
/// failing ends the whole run. Complete replies are kept in an optional
/// cache, so running the same lines again reuses them.
///
/// Lines the speech model was unsure of are marked doubtful in the request.
/// With `marksHallucinations`, the model may also mark lines that cannot be
/// speech; they are reported in `droppedLines` for the caller to remove.
public struct SubtitleRefiner: Sendable {
    public enum Job: Sendable {
        /// Fix what the speech model misheard, in the subtitles' own language.
        case proofread
        case polishChinese
        case translate(targetLanguage: String)
        /// Existing subtitles in any language, e.g. imported from a file.
        case translateSubtitles(targetLanguage: String)
    }

    public struct Configuration: Sendable {
        public var model: String
        public var batchSize = 40
        public var contextLineCount = 8
        /// Scenes in flight at once.
        public var concurrentSceneCount = 4
        public var temperature = 0.3
        /// A pause this long starts a new scene (PySubtrans' `scene_threshold`,
        /// WhisperJAV's default of 120 s).
        public var sceneGap = AudioTime(seconds: 120)
        /// Longer scenes are split, so a film without long pauses still runs
        /// several requests at once; summaries do not cross the split.
        public var maximumBatchesPerScene = 5
        /// Summaries of earlier batches in the scene sent with each request.
        public var earlierBatchSummaryCount = 5
        /// Lets the model mark lines that cannot be speech, to be removed.
        public var marksHallucinations = false

        public init(model: String) {
            self.model = model
        }
    }

    private let client: any StructuredChatCompleting
    private let configuration: Configuration
    private let cache: LLMReplyCache?

    public init(client: any StructuredChatCompleting, configuration: Configuration, cache: LLMReplyCache? = nil) {
        self.client = client
        self.configuration = configuration
        self.cache = cache
    }

    public struct Result: Sendable {
        public let segments: [TimedText]
        /// The new text of every line the model answered, by index.
        public let answeredLines: [Int: String]
        /// Lines the model marked as not speech (with `marksHallucinations`);
        /// they keep their text in `segments`.
        public let droppedLines: Set<Int>
        /// Batches that kept their original text because the request failed.
        public let failedBatchCount: Int
        public let batchCount: Int
        /// Batches answered from the cache instead of the model.
        public let reusedBatchCount: Int
        /// The error of a failed batch, for a warning.
        public let firstFailure: String?
    }

    /// A finished batch, so its lines can be shown before the rest are done.
    public struct BatchProgress: Sendable {
        public let completed: Int
        public let total: Int
        /// New text by line index; empty for a batch that failed.
        public let lines: [Int: String]
        /// Lines marked as not speech.
        public let droppedLines: Set<Int>
    }

    /// - Parameters:
    ///   - lineIndices: only these lines are sent (the rest serve as context
    ///     and keep their text); `nil` sends every line.
    ///   - reusesCachedReplies: false asks the model again even for lines it
    ///     answered before, e.g. when the user wants a new translation.
    ///   - progress: called after every batch, in completion order.
    public func refine(
        _ segments: [TimedText],
        job: Job,
        glossary: [(source: String, target: String)] = [],
        lineIndices: [Int]? = nil,
        reusesCachedReplies: Bool = true,
        progress: @escaping @Sendable (BatchProgress) -> Void = { _ in }
    ) async throws -> Result {
        let selected = (lineIndices ?? Array(segments.indices)).filter(segments.indices.contains).sorted()
        let plan = RefinementPlan(
            lineIndices: Array(Set(selected)).sorted(),
            of: segments,
            batchSize: configuration.batchSize,
            sceneGap: configuration.sceneGap,
            maximumBatchesPerScene: configuration.maximumBatchesPerScene
        )
        guard plan.batchCount > 0 else {
            return Result(
                segments: segments, answeredLines: [:], droppedLines: [], failedBatchCount: 0, batchCount: 0, reusedBatchCount: 0, firstFailure: nil
            )
        }
        let promptJob: SubtitlePrompt.Job = switch job {
        case .proofread: .proofread
        case .polishChinese: .polishChinese
        case .translate(let language): .translate(targetLanguage: language)
        case .translateSubtitles(let language): .translateSubtitles(targetLanguage: language)
        }
        let system = ChatMessage(role: .system, content: SubtitlePrompt.systemMessage(
            for: promptJob, glossary: glossary, marksHallucinations: configuration.marksHallucinations
        ))
        let context = SceneContext(
            segments: segments, system: system, total: plan.batchCount,
            reusesCachedReplies: reusesCachedReplies, progress: progress
        )

        var answeredLines: [Int: String] = [:]
        var droppedLines = Set<Int>()
        var failures: [any Error] = []
        var reusedCount = 0
        try await withThrowingTaskGroup(of: [BatchOutcome].self) { group in
            var nextScene = 0
            func startNextScene() {
                let scene = plan.scenes[nextScene]
                nextScene += 1
                group.addTask { try await refineScene(scene, context: context) }
            }
            while nextScene < min(max(configuration.concurrentSceneCount, 1), plan.scenes.count) {
                startNextScene()
            }
            while let outcomes = try await group.next() {
                for outcome in outcomes {
                    switch outcome.result {
                    case .success(let answer):
                        answeredLines.merge(answer.lines) { _, new in new }
                        droppedLines.formUnion(answer.dropped)
                        reusedCount += outcome.wasCached ? 1 : 0
                    case .failure(let error):
                        failures.append(error)
                    }
                }
                if nextScene < plan.scenes.count {
                    startNextScene()
                }
            }
        }
        if failures.count == plan.batchCount, let error = failures.first {
            throw error  // nothing came back: the run failed
        }

        let refined = segments.enumerated().map { index, segment in
            var refined = segment
            refined.text = answeredLines[index] ?? segment.text
            return refined
        }
        return Result(
            segments: refined,
            answeredLines: answeredLines,
            droppedLines: droppedLines,
            failedBatchCount: failures.count,
            batchCount: plan.batchCount,
            reusedBatchCount: reusedCount,
            firstFailure: failures.first?.localizedDescription
        )
    }

    /// What every scene of one run shares, including the count of finished batches.
    private final class SceneContext: Sendable {
        let segments: [TimedText]
        let system: ChatMessage
        let total: Int
        let reusesCachedReplies: Bool
        let progress: @Sendable (BatchProgress) -> Void
        private let completedCount = Mutex(0)

        init(
            segments: [TimedText],
            system: ChatMessage,
            total: Int,
            reusesCachedReplies: Bool,
            progress: @escaping @Sendable (BatchProgress) -> Void
        ) {
            self.segments = segments
            self.system = system
            self.total = total
            self.reusesCachedReplies = reusesCachedReplies
            self.progress = progress
        }

        func reportBatch(lines: [Int: String], dropped: Set<Int>) {
            let completed = completedCount.withLock { count in
                count += 1
                return count
            }
            progress(BatchProgress(completed: completed, total: total, lines: lines, droppedLines: dropped))
        }
    }

    private struct BatchAnswer: Sendable {
        /// New text by line index.
        let lines: [Int: String]
        /// Lines marked as not speech.
        let dropped: Set<Int>
    }

    private struct BatchOutcome: Sendable {
        let result: Swift.Result<BatchAnswer, any Error>
        let wasCached: Bool
    }

    /// The scene's batches in order, each with the summaries of those before.
    private func refineScene(_ scene: [RefinementPlan.Batch], context: SceneContext) async throws -> [BatchOutcome] {
        let segments = context.segments
        var sceneSummary: String?
        var batchSummaries: [String] = []
        var outcomes: [BatchOutcome] = []
        /// What the model wrote for this scene's lines so far, for later batches' context.
        var written: [Int: String] = [:]
        for batch in scene {
            try Task.checkCancellation()
            guard let first = batch.first, let last = batch.last else {
                continue
            }
            func contextLines(_ indices: Range<Int>) -> [SubtitlePrompt.ContextLine] {
                indices.map { SubtitlePrompt.ContextLine(text: segments[$0].text, start: segments[$0].start, end: segments[$0].end, output: written[$0]) }
            }
            let request = BatchRequest(
                lines: batch.map {
                    SubtitlePrompt.Line(
                        id: $0, text: segments[$0].text, start: segments[$0].start, end: segments[$0].end,
                        isDoubtful: segments[$0].confidence?.isDoubtful ?? false
                    )
                },
                contextBefore: contextLines(max(0, first - configuration.contextLineCount)..<first),
                contextAfter: contextLines((last + 1)..<min(last + 1 + configuration.contextLineCount, segments.count)),
                sceneSoFar: sceneSummary,
                earlierBatches: Array(batchSummaries.suffix(configuration.earlierBatchSummaryCount))
            )
            do {
                let (reply, wasCached) = try await requestLines(request, system: context.system, reusesCachedReplies: context.reusesCachedReplies)
                let dropped = configuration.marksHallucinations ? reply.droppedIDs : []
                var lines: [Int: String] = [:]
                for (index, text) in reply.textByID where !dropped.contains(index) {
                    let cleaned = SubtitlePrompt.removingAddedTime(from: text, original: segments[index].text)
                    if !cleaned.pythonStripped.isEmpty {
                        lines[index] = cleaned
                    }
                }
                written.merge(lines) { _, new in new }
                if let summary = reply.batchSummary?.pythonStripped, !summary.isEmpty {
                    batchSummaries.append(summary)
                }
                if let summary = reply.sceneSummary?.pythonStripped, !summary.isEmpty {
                    sceneSummary = summary
                }
                outcomes.append(BatchOutcome(result: .success(BatchAnswer(lines: lines, dropped: dropped)), wasCached: wasCached))
                context.reportBatch(lines: lines, dropped: dropped)
            } catch let error where Self.endsTheRun(error) {
                throw error
            } catch {
                outcomes.append(BatchOutcome(result: .failure(error), wasCached: false))
                context.reportBatch(lines: [:], dropped: [])
            }
        }
        return outcomes
    }

    /// Errors no other batch can avoid.
    private static func endsTheRun(_ error: any Error) -> Bool {
        switch error {
        case is CancellationError, LLMServiceError.invalidAPIKey, LLMServiceError.insufficientCredits: true
        default: false
        }
    }

    private struct BatchRequest {
        let lines: [SubtitlePrompt.Line]
        let contextBefore: [SubtitlePrompt.ContextLine]
        let contextAfter: [SubtitlePrompt.ContextLine]
        let sceneSoFar: String?
        let earlierBatches: [String]
    }

    /// The reply, limited to the batch's ids, and whether it came from the
    /// cache; asks once more if the ids do not match.
    private func requestLines(
        _ request: BatchRequest,
        system: ChatMessage,
        reusesCachedReplies: Bool
    ) async throws -> (SubtitlePrompt.Reply, wasCached: Bool) {
        let expectedIDs = Set(request.lines.map(\.id))
        // Without the summaries and the context's earlier answers: they depend
        // on earlier replies (see LLMReplyCache).
        func withoutOutputs(_ context: [SubtitlePrompt.ContextLine]) -> [SubtitlePrompt.ContextLine] {
            context.map { SubtitlePrompt.ContextLine(text: $0.text, start: $0.start, end: $0.end) }
        }
        let cacheKey = LLMReplyCache.Key(
            model: configuration.model,
            instructions: system.content,
            request: try SubtitlePrompt.userMessage(
                lines: request.lines,
                contextBefore: withoutOutputs(request.contextBefore),
                contextAfter: withoutOutputs(request.contextAfter),
                sortsKeys: true
            )
        )
        if reusesCachedReplies, let data = cache?.reply(for: cacheKey), let reply = Self.decode(data),
           Set(reply.textByID.keys) == expectedIDs {
            return (reply, true)
        }

        let user = ChatMessage(role: .user, content: try SubtitlePrompt.userMessage(
            lines: request.lines,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            sceneSoFar: request.sceneSoFar,
            earlierBatches: request.earlierBatches
        ))
        var bestReply: SubtitlePrompt.Reply?
        for _ in 0..<2 {
            let data = try await client.completeJSON(
                model: configuration.model,
                messages: [system, user],
                schemaName: SubtitlePrompt.schemaName,
                schema: SubtitlePrompt.schema(marksHallucinations: configuration.marksHallucinations),
                temperature: configuration.temperature
            )
            guard let reply = Self.decode(data)?.limited(to: expectedIDs) else {
                continue
            }
            if reply.lines.count > bestReply?.lines.count ?? -1 {
                bestReply = reply
            }
            if Set(reply.textByID.keys) == expectedIDs {
                cache?.store(data, for: cacheKey)
                return (reply, false)
            }
        }
        return (bestReply ?? SubtitlePrompt.Reply(lines: [], batchSummary: nil, sceneSummary: nil), false)
    }

    private static func decode(_ data: Data) -> SubtitlePrompt.Reply? {
        try? JSONDecoder().decode(SubtitlePrompt.Reply.self, from: data)
    }
}

extension SubtitlePrompt.Reply {
    /// Without lines the batch did not ask for.
    func limited(to ids: Set<Int>) -> SubtitlePrompt.Reply {
        SubtitlePrompt.Reply(lines: lines.filter { ids.contains($0.id) }, batchSummary: batchSummary, sceneSummary: sceneSummary)
    }
}

extension Array where Element == TimedText {
    /// Bilingual lines: each translation followed by its original on the next line.
    public func withOriginalLines(from originals: [TimedText]) -> [TimedText] {
        zip(self, originals).map { translated, original in
            var bilingual = translated
            bilingual.text = "\(translated.text)\n\(original.text)"
            return bilingual
        }
    }
}
