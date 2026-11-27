import Foundation
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
/// the same time. The model gets one more attempt at an incomplete reply;
/// lines without usable answers keep their original text. A failed request
/// also leaves its batch's lines unchanged and is counted in the result.
/// A rejected key, no credits, or every batch failing ends the whole run.
/// Complete replies are kept in an optional cache, so running the same
/// lines again reuses them.
///
/// Lines the speech model was unsure of are marked doubtful in the request.
/// With `marksHallucinations`, the model may also mark lines that cannot be
/// speech; they are reported in `droppedLines` for the caller to remove.
/// With `correctsSources`, a translation also returns each original line
/// with what the speech model misheard fixed, in `correctedSources`, so
/// proofreading costs no second pass.
public struct SubtitleRefiner: Sendable {
    public enum Job: Sendable {
        case polishChinese
        case translate(targetLanguage: String)
        /// Existing subtitles in any language, e.g. imported from a file.
        case translateSubtitles(targetLanguage: String)
        /// Japanese transcripts with what the speech model misheard fixed,
        /// nothing else; for chosen lines (a full run proofreads within the
        /// translation, see `correctsSources`).
        case proofreadJapanese
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
        /// For `.translate`: also return each original with its mishearings fixed.
        public var correctsSources = false

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
        /// With `correctsSources`, each answered line's original as the model
        /// corrected it, by index (unchanged lines included).
        public let correctedSources: [Int: String]
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
        let promptJob: SubtitlePrompt.Job = switch job {
        case .polishChinese: .polishChinese
        case .translate(let language): .translate(targetLanguage: language)
        case .translateSubtitles(let language): .translateSubtitles(targetLanguage: language)
        case .proofreadJapanese: .proofreadJapanese
        }
        let plan = RefinementPlan(
            lineIndices: Array(Set(selected)).sorted(),
            of: segments,
            batchSize: configuration.batchSize,
            sceneGap: configuration.sceneGap,
            maximumBatchesPerScene: configuration.maximumBatchesPerScene,
            minimumSceneCount: promptJob.translationTarget == nil ? 1 : configuration.concurrentSceneCount
        )
        guard plan.batchCount > 0 else {
            return Result(
                segments: segments, answeredLines: [:], correctedSources: [:], droppedLines: [], failedBatchCount: 0, batchCount: 0, reusedBatchCount: 0, firstFailure: nil
            )
        }
        let system = ChatMessage(role: .system, content: SubtitlePrompt.systemMessage(
            for: promptJob, glossary: glossary, correctsSources: correctsSources(for: job), marksHallucinations: configuration.marksHallucinations
        ))
        let context = SceneContext(
            segments: segments, system: system, translationTarget: promptJob.translationTarget,
            correctsSources: correctsSources(for: job), total: plan.batchCount,
            reusesCachedReplies: reusesCachedReplies, progress: progress
        )

        var answeredLines: [Int: String] = [:]
        var correctedSources: [Int: String] = [:]
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
                        correctedSources.merge(answer.sources) { _, new in new }
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
            correctedSources: correctedSources,
            droppedLines: droppedLines,
            failedBatchCount: failures.count,
            batchCount: plan.batchCount,
            reusedBatchCount: reusedCount,
            firstFailure: failures.first?.localizedDescription
        )
    }

    /// Only translations of transcripts proofread their originals.
    private func correctsSources(for job: Job) -> Bool {
        guard configuration.correctsSources, case .translate = job else {
            return false
        }
        return true
    }

    /// What every scene of one run shares, including the count of finished batches.
    private actor SceneContext {
        let segments: [TimedText]
        let system: ChatMessage
        let translationTarget: String?
        let correctsSources: Bool
        let total: Int
        let reusesCachedReplies: Bool
        let progress: @Sendable (BatchProgress) -> Void
        private var completed = 0

        init(
            segments: [TimedText],
            system: ChatMessage,
            translationTarget: String?,
            correctsSources: Bool,
            total: Int,
            reusesCachedReplies: Bool,
            progress: @escaping @Sendable (BatchProgress) -> Void
        ) {
            self.segments = segments
            self.system = system
            self.translationTarget = translationTarget
            self.correctsSources = correctsSources
            self.total = total
            self.reusesCachedReplies = reusesCachedReplies
            self.progress = progress
        }

        func reportBatch(lines: [Int: String], dropped: Set<Int>) {
            completed += 1
            progress(BatchProgress(completed: completed, total: total, lines: lines, droppedLines: dropped))
        }
    }

    private struct BatchAnswer: Sendable {
        /// New text by line index.
        var lines: [Int: String] = [:]
        /// Corrected originals by line index, when asked for.
        var sources: [Int: String] = [:]
        /// Lines marked as not speech.
        var dropped: Set<Int> = []
        var batchSummary: String?
        var sceneSummary: String?

        var count: Int { lines.count + dropped.count }
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
                let (answer, wasCached) = try await requestLines(request, context: context)
                written.merge(answer.lines) { _, new in new }
                if let summary = answer.batchSummary?.pythonStripped, !summary.isEmpty {
                    batchSummaries.append(summary)
                }
                if let summary = answer.sceneSummary?.pythonStripped, !summary.isEmpty {
                    sceneSummary = summary
                }
                outcomes.append(BatchOutcome(result: .success(answer), wasCached: wasCached))
                await context.reportBatch(lines: answer.lines, dropped: answer.dropped)
            } catch let error where Self.endsTheRun(error) {
                throw error
            } catch {
                outcomes.append(BatchOutcome(result: .failure(error), wasCached: false))
                await context.reportBatch(lines: [:], dropped: [])
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

    /// Usable answers for the requested ids; asks once more if any are missing.
    private func requestLines(_ request: BatchRequest, context: SceneContext) async throws -> (BatchAnswer, wasCached: Bool) {
        let originals = Dictionary(uniqueKeysWithValues: request.lines.map { ($0.id, $0.text) })
        // Without the summaries and the context's earlier answers: they depend
        // on earlier replies (see LLMReplyCache).
        func withoutOutputs(_ context: [SubtitlePrompt.ContextLine]) -> [SubtitlePrompt.ContextLine] {
            context.map { SubtitlePrompt.ContextLine(text: $0.text, start: $0.start, end: $0.end) }
        }
        let cacheKey = LLMReplyCache.Key(
            model: configuration.model,
            instructions: context.system.content,
            request: try SubtitlePrompt.userMessage(
                lines: request.lines,
                contextBefore: withoutOutputs(request.contextBefore),
                contextAfter: withoutOutputs(request.contextAfter),
                sortsKeys: true
            )
        )
        if context.reusesCachedReplies, let data = cache?.reply(for: cacheKey),
           let answer = resolve(data, originals: originals, context: context), answer.count == originals.count {
            return (answer, true)
        }

        let user = ChatMessage(role: .user, content: try SubtitlePrompt.userMessage(
            lines: request.lines,
            contextBefore: request.contextBefore,
            contextAfter: request.contextAfter,
            sceneSoFar: request.sceneSoFar,
            earlierBatches: request.earlierBatches
        ))
        var best = BatchAnswer()
        for _ in 0..<2 {
            let data: Data
            do {
                data = try await client.completeJSON(
                    model: configuration.model,
                    messages: [context.system, user],
                    schemaName: SubtitlePrompt.schemaName,
                    schema: SubtitlePrompt.schema(correctsSources: context.correctsSources, marksHallucinations: configuration.marksHallucinations),
                    temperature: configuration.temperature
                )
            } catch where best.count > 0 && !Self.endsTheRun(error) {
                break  // Keep the usable answers from the first attempt.
            }
            guard let answer = resolve(data, originals: originals, context: context) else { continue }
            if answer.count == originals.count {
                cache?.store(data, for: cacheKey)
                return (answer, false)
            }
            if answer.count > best.count {
                best = answer
            }
        }
        return (best, false)
    }

    private func resolve(_ data: Data, originals: [Int: String], context: SceneContext) -> BatchAnswer? {
        guard let reply = try? JSONDecoder().decode(SubtitlePrompt.Reply.self, from: data) else { return nil }
        var answer = BatchAnswer(batchSummary: reply.batchSummary, sceneSummary: reply.sceneSummary)
        for line in reply.lines {
            let id = line.id
            guard let original = originals[id], answer.lines[id] == nil, !answer.dropped.contains(id) else { continue }
            if configuration.marksHallucinations, line.drop == true {
                answer.dropped.insert(id)
                continue
            }
            let source = context.correctsSources ? line.source.map { SubtitlePrompt.removingAddedTime(from: $0, original: original) } : nil
            let cleaned = SubtitlePrompt.removingAddedTime(from: line.text, original: original)
            if let target = context.translationTarget {
                guard let translation = SubtitlePrompt.translationText(cleaned, original: original, correctedSource: source, target: target) else { continue }
                answer.lines[id] = translation
            } else {
                guard !cleaned.pythonStripped.isEmpty else { continue }
                answer.lines[id] = cleaned
            }
            if let source, !source.pythonStripped.isEmpty {
                answer.sources[id] = source
            }
        }
        return answer
    }
}
