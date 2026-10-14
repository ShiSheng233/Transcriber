import Foundation
import LLMTranslation
import TranscriberCore
import TranscriptionPipeline

/// Runs jobs one at a time (each one already uses the GPU fully) and
/// publishes a snapshot of all jobs after every change.
public actor JobQueue {
    public struct Configuration: Sendable {
        public var engine: EngineSettings
        public var output: OutputSettings
        /// `nil` skips the LLM step.
        public var llm: LLMConfiguration?

        public init(engine: EngineSettings, output: OutputSettings, llm: LLMConfiguration? = nil) {
            self.engine = engine
            self.output = output
            self.llm = llm
        }
    }

    public struct LLMConfiguration: Sendable {
        public var settings: LLMSettings
        public var apiKey: String

        public init(settings: LLMSettings, apiKey: String) {
            self.settings = settings
            self.apiKey = apiKey
        }

        var isUsable: Bool {
            settings.isEnabled && !settings.model.isEmpty && !apiKey.isEmpty
        }
    }

    private let engine: TranscriptionEngine
    private let makeChatClient: @Sendable (_ apiKey: String) -> any StructuredChatCompleting
    private var jobs: [Job] = []
    private var runningTask: Task<Void, Never>?
    private var runningJobID: UUID?
    private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]

    public init(
        engine: TranscriptionEngine = TranscriptionEngine(),
        makeChatClient: @escaping @Sendable (_ apiKey: String) -> any StructuredChatCompleting = { OpenRouterClient(apiKey: $0) }
    ) {
        self.engine = engine
        self.makeChatClient = makeChatClient
    }

    /// Current jobs first, then every change.
    public func snapshots() -> AsyncStream<[Job]> {
        let (stream, continuation) = AsyncStream<[Job]>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let observerID = UUID()
        observers[observerID] = continuation
        continuation.yield(jobs)
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeObserver(observerID) }
        }
        return stream
    }

    public func add(_ sourceURLs: [URL], task: TranscriptionTask) {
        let known = Set(jobs.filter { !$0.status.isFinished }.map(\.sourceURL))
        jobs += sourceURLs.filter { !known.contains($0) }.map { Job(sourceURL: $0, task: task) }
        publish()
    }

    public func remove(_ jobID: UUID) {
        if jobID == runningJobID {
            runningTask?.cancel()
        }
        jobs.removeAll { $0.id == jobID }
        publish()
    }

    public func removeFinished() {
        jobs.removeAll { $0.status.isFinished }
        publish()
    }

    public func cancel(_ jobID: UUID) {
        if jobID == runningJobID {
            runningTask?.cancel()
        } else {
            update(jobID) { $0.status = .cancelled }
        }
    }

    /// Processes queued jobs until none are left.
    public func start(configuration: Configuration) {
        guard runningTask == nil else {
            return
        }
        runningTask = Task { await processQueuedJobs(configuration: configuration) }
    }

    private func processQueuedJobs(configuration: Configuration) async {
        while let job = jobs.first(where: { $0.status == .queued }) {
            runningJobID = job.id
            await process(job, configuration: configuration)
            runningJobID = nil
            if Task.isCancelled {
                break
            }
        }
        runningTask = nil
    }

    private func process(_ job: Job, configuration: Configuration) async {
        do {
            update(job.id) { $0.status = .loadingModel }
            let pipeline = try await engine.pipeline(for: job.task, settings: configuration.engine)
            update(job.id) { $0.status = .decodingAudio }

            let jobID = job.id
            var segments = try await pipeline.transcribe(fileAt: job.sourceURL) { [weak self] progress in
                Task { await self?.record(progress, for: jobID) }
            }
            try Task.checkCancellation()

            if let llm = configuration.llm, llm.isUsable, !segments.isEmpty {
                do {
                    segments = try await refine(segments, of: job, with: llm)
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // The machine subtitles are still worth keeping.
                    update(job.id) { $0.warning = "LLM step skipped: \(error.localizedDescription)" }
                }
            }

            update(job.id) { $0.status = .exporting }
            let outputURLs = try SubtitleFileWriter.write(segments, for: job.sourceURL, settings: configuration.output)
            update(job.id) {
                $0.segments = segments
                $0.outputURLs = outputURLs
                $0.status = .completed
            }
        } catch is CancellationError {
            update(job.id) { $0.status = .cancelled }
        } catch {
            update(job.id) { $0.status = .failed(message: error.localizedDescription) }
        }
    }

    /// ChickenRice's Chinese is polished; whisper-ja's Japanese is translated.
    private func refine(_ segments: [TimedText], of job: Job, with llm: LLMConfiguration) async throws -> [TimedText] {
        let refiner = SubtitleRefiner(
            client: makeChatClient(llm.apiKey),
            configuration: SubtitleRefiner.Configuration(model: llm.settings.model)
        )
        let refinerJob: SubtitleRefiner.Job = job.task == .translate
            ? .polishChinese
            : .translate(targetLanguage: llm.settings.targetLanguage)
        let jobID = job.id
        update(jobID) { $0.status = .refining(completedBatches: 0, totalBatches: 1) }
        let refined = try await refiner.refine(segments, job: refinerJob, glossary: llm.settings.glossaryEntries) { [weak self] completed, total in
            Task { await self?.update(jobID) { $0.status = .refining(completedBatches: completed, totalBatches: total) } }
        }
        if case .translate = refinerJob, llm.settings.keepsOriginalLine {
            return refined.withOriginalLines(from: segments)
        }
        return refined
    }

    private func record(_ progress: TranscriptionPipeline.Progress, for jobID: UUID) {
        guard case .transcribedChunk(let index, let count) = progress else {
            if case .plannedChunks(let count) = progress {
                update(jobID) { $0.status = .transcribing(completedChunks: 0, totalChunks: count) }
            }
            return
        }
        update(jobID) { job in
            // Progress messages can arrive after the job moved on.
            if case .transcribing = job.status {
                job.status = .transcribing(completedChunks: index + 1, totalChunks: count)
            }
        }
    }

    private func update(_ jobID: UUID, _ change: (inout Job) -> Void) {
        guard let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        change(&jobs[index])
        publish()
    }

    private func publish() {
        for continuation in observers.values {
            continuation.yield(jobs)
        }
    }

    private func removeObserver(_ observerID: UUID) {
        observers[observerID] = nil
    }
}
