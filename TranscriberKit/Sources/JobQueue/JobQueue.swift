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
    private static let logCapacity = 5_000
    private var logEntries: [LogEntry] = []
    private var logObservers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    /// When the running job's transcription started, for the speed figure.
    private var transcriptionStart: ContinuousClock.Instant?
    private var audioDuration: AudioTime?

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

    /// The kept history first, then every new entry.
    public func logs() -> AsyncStream<LogEntry> {
        let (stream, continuation) = AsyncStream<LogEntry>.makeStream(bufferingPolicy: .bufferingNewest(Self.logCapacity))
        let observerID = UUID()
        logObservers[observerID] = continuation
        for entry in logEntries {
            continuation.yield(entry)
        }
        continuation.onTermination = { [weak self] _ in
            Task { await self?.removeLogObserver(observerID) }
        }
        return stream
    }

    public func add(_ sourceURLs: [URL], model: RecognitionModel) {
        let known = Set(jobs.filter { !$0.status.isFinished }.map(\.sourceURL))
        let newJobs = sourceURLs.filter { !known.contains($0) }.map { Job(sourceURL: $0, model: model) }
        jobs += newJobs
        publish()
        for job in newJobs {
            log(.detail, job.id, "\(job.sourceURL.lastPathComponent): queued with \(model.displayName)")
        }
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

    /// Cancels the running job, waits for it to stop and frees the model.
    public func shutDown() async {
        runningTask?.cancel()
        await runningTask?.value
        await engine.unload()
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
        let fileName = job.sourceURL.lastPathComponent
        let jobStart = ContinuousClock.now
        log(.info, job.id, "\(fileName): started")
        do {
            update(job.id) { $0.status = .loadingModel }
            let pipeline = try await loadPipeline(for: job, settings: configuration.engine)
            update(job.id) { $0.status = .decodingAudio }
            log(.info, job.id, "Reading audio…")

            let jobID = job.id
            transcriptionStart = ContinuousClock.now
            audioDuration = nil
            var segments = try await withOrderedProgress { queue, progress in
                queue.record(progress, for: jobID)
            } work: { report in
                try await pipeline.transcribe(fileAt: job.sourceURL, progress: report)
            }
            try Task.checkCancellation()
            logTranscriptionSpeed(for: job.id, segmentCount: segments.count)

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
            if let folder = outputURLs.first?.deletingLastPathComponent().path {
                log(.detail, job.id, "Wrote \(outputURLs.map(\.lastPathComponent).joined(separator: ", ")) to \(folder)")
            }
            log(.info, job.id, "\(fileName): done in \(ActivityFormatting.seconds(ContinuousClock.now - jobStart)), \(segments.count) subtitles")
        } catch is CancellationError {
            update(job.id) {
                $0.status = .cancelled
                $0.segments = []
            }
            log(.warning, job.id, "\(fileName): cancelled")
        } catch {
            update(job.id) {
                $0.status = .failed(message: error.localizedDescription)
                $0.segments = []
            }
            log(.error, job.id, "\(fileName): \(error.localizedDescription)")
        }
    }

    private func loadPipeline(for job: Job, settings: EngineSettings) async throws -> TranscriptionPipeline {
        let model = job.model
        let engineName = settings.backend.displayName
        if await engine.isLoaded(model, settings: settings) {
            log(.detail, job.id, "\(model.displayName) is already loaded (\(engineName))")
            return try await engine.pipeline(for: model, settings: settings)
        }
        let weights = settings.backend.weights(of: model)
        let size = weights.flatMap(ActivityFormatting.fileSize(of:)).map { ", \($0)" } ?? ""
        log(.info, job.id, "Loading \(model.displayName) with \(engineName)…")
        log(.detail, job.id, "Weights: \(weights?.path ?? "none")\(size)")
        log(.detail, job.id, "Decoding: task \(model.decoding.task.rawValue), language \(model.decoding.languageCode), "
            + "temperatures \(model.decoding.temperatures.map { String(format: "%.1f", $0) }.joined(separator: "/")), "
            + "\(settings.concurrentChunkCount) chunk(s) at once")
        let start = ContinuousClock.now
        let pipeline = try await engine.pipeline(for: model, settings: settings)
        log(.info, job.id, "\(model.displayName) loaded in \(ActivityFormatting.seconds(ContinuousClock.now - start))")
        return pipeline
    }

    private func logTranscriptionSpeed(for jobID: UUID, segmentCount: Int) {
        guard let transcriptionStart, let audioDuration else {
            return
        }
        let elapsed = ContinuousClock.now - transcriptionStart
        let seconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        let speed = seconds > 0 ? String(format: " (%.1f× realtime)", audioDuration.seconds / seconds) : ""
        log(.info, jobID, "Transcribed \(ActivityFormatting.clock(audioDuration.seconds)) of audio in \(ActivityFormatting.seconds(elapsed))\(speed)")
    }

    /// The model's configuration says whether its output is polished or translated.
    private func refine(_ segments: [TimedText], of job: Job, with llm: LLMConfiguration) async throws -> [TimedText] {
        let refiner = SubtitleRefiner(
            client: makeChatClient(llm.apiKey),
            configuration: SubtitleRefiner.Configuration(model: llm.settings.model)
        )
        let refinerJob: SubtitleRefiner.Job = job.model.llmMode == .polish
            ? .polishChinese
            : .translate(targetLanguage: llm.settings.targetLanguage)
        let jobID = job.id
        update(jobID) { $0.status = .refining(completedBatches: 0, totalBatches: 1) }
        let action = job.model.llmMode == .polish ? "Polishing" : "Translating"
        log(.info, jobID, "\(action) \(segments.count) subtitles with \(llm.settings.model)…")
        let start = ContinuousClock.now
        let refined = try await withOrderedProgress { (queue, batches: (completed: Int, total: Int)) in
            queue.update(jobID) { $0.status = .refining(completedBatches: batches.completed, totalBatches: batches.total) }
            queue.log(.detail, jobID, "LLM batch \(batches.completed)/\(batches.total) done")
        } work: { report in
            try await refiner.refine(segments, job: refinerJob, glossary: llm.settings.glossaryEntries) { report(($0, $1)) }
        }
        log(.info, jobID, "LLM step finished in \(ActivityFormatting.seconds(ContinuousClock.now - start))")
        if case .translate = refinerJob, llm.settings.keepsOriginalLine {
            return refined.withOriginalLines(from: segments)
        }
        return refined
    }

    private func record(_ progress: TranscriptionPipeline.Progress, for jobID: UUID) {
        switch progress {
        case .decodedAudio(let duration):
            audioDuration = duration
            log(.detail, jobID, "Audio: \(ActivityFormatting.clock(duration.seconds)) at 16 kHz mono")
            update(jobID) { $0.status = .detectingSpeech }
            log(.info, jobID, "Detecting speech…")
        case .detectedSpeech(let spanCount, let speechDuration):
            log(.detail, jobID, "Speech: \(spanCount) span(s), \(ActivityFormatting.clock(speechDuration.seconds)) in total")
        case .plannedChunks(let count):
            update(jobID) { $0.status = .transcribing(completedChunks: 0, totalChunks: count) }
            log(.info, jobID, "Transcribing \(count) chunk(s)…")
        case .transcribedChunk(let completed, let count, let chunk, let segments):
            update(jobID) { job in
                job.status = .transcribing(completedChunks: completed, totalChunks: count)
                // A preview while the file runs; replaced by the final subtitles.
                job.segments = (job.segments + segments).sorted { $0.start < $1.start }
            }
            log(.detail, jobID, "Chunk \(completed)/\(count) "
                + "(\(ActivityFormatting.clock(chunk.startSeconds))–\(ActivityFormatting.clock(chunk.endSeconds))): \(segments.count) segment(s)")
        case .postProcessed(let segmentCount):
            log(.detail, jobID, "Merged into \(segmentCount) subtitle(s)")
        }
    }

    /// Runs `work` and handles everything it reports, in order, before
    /// returning, so later log lines never overtake its progress.
    private func withOrderedProgress<Progress: Sendable, Result: Sendable>(
        handle: @escaping @Sendable (isolated JobQueue, Progress) -> Void,
        work: (_ report: @escaping @Sendable (Progress) -> Void) async throws -> Result
    ) async throws -> Result {
        let (stream, continuation) = AsyncStream<Progress>.makeStream()
        let consumer = Task {
            for await progress in stream {
                handle(self, progress)
            }
        }
        do {
            let result = try await work { continuation.yield($0) }
            continuation.finish()
            await consumer.value
            return result
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
    }

    private func log(_ level: LogEntry.Level, _ jobID: UUID?, _ message: String) {
        let entry = LogEntry(level: level, jobID: jobID, message: message)
        logEntries.append(entry)
        if logEntries.count > Self.logCapacity {
            logEntries.removeFirst(logEntries.count - Self.logCapacity)
        }
        for continuation in logObservers.values {
            continuation.yield(entry)
        }
    }

    private func removeLogObserver(_ observerID: UUID) {
        logObservers[observerID] = nil
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
