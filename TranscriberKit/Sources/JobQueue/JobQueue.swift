import Foundation
import LLMTranslation
import SubtitleExport
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

        /// Local servers need no key; a missing one shows up as a rejected request.
        var isUsable: Bool {
            settings.isEnabled && !settings.model.isEmpty
        }
    }

    private let engine: TranscriptionEngine
    private let makeChatClient: @Sendable (_ baseURL: URL, _ apiKey: String) -> any StructuredChatCompleting
    private var jobs: [Job] = []
    private var runningTask: Task<Void, Never>?
    private var runningJobID: UUID?
    /// The running job alone, so cancelling it leaves the queue running.
    private var currentJobTask: Task<Void, Never>?
    /// Set by `stop()`: the interrupted job goes back to the queue.
    private var isStopping = false
    private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
    private static let logCapacity = 5_000
    private var logEntries: [LogEntry] = []
    private var logObservers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    /// When the running job's transcription started, for the speed figure.
    private var transcriptionStart: ContinuousClock.Instant?
    private var audioDuration: AudioTime?

    public init(
        engine: TranscriptionEngine = TranscriptionEngine(),
        makeChatClient: @escaping @Sendable (_ baseURL: URL, _ apiKey: String) -> any StructuredChatCompleting = { ChatCompletionsClient(baseURL: $0, apiKey: $1) }
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

    public var isRunning: Bool {
        runningTask != nil
    }

    /// Opens subtitle files for editing; they are ready at once. A file that
    /// cannot be read shows up as a failed job with the reason.
    public func openSubtitles(_ files: [(subtitleURL: URL, mediaURL: URL?)]) -> [UUID] {
        let open = Set(jobs.filter { $0.kind == .subtitleEditing }.map(\.sourceURL))
        var opened: [UUID] = []
        for file in files where !open.contains(file.subtitleURL) {
            var job: Job
            do {
                job = Job(editing: file.subtitleURL, mediaURL: file.mediaURL, lines: try SubtitleParser.parse(fileAt: file.subtitleURL))
                log(.info, job.id, "\(file.subtitleURL.lastPathComponent): opened, \(job.segments.count) subtitles")
            } catch {
                job = Job(editing: file.subtitleURL, mediaURL: file.mediaURL, lines: [])
                job.status = .failed(message: error.localizedDescription)
                log(.error, job.id, "\(file.subtitleURL.lastPathComponent): \(error.localizedDescription)")
            }
            jobs.append(job)
            opened.append(job.id)
        }
        publish()
        return opened
    }

    /// Queues subtitle files for translation by the language model; `mediaURL`
    /// is what the preview plays, if a media file sits next to the subtitles.
    /// With `lines`, those are translated instead of the file's contents.
    @discardableResult
    public func addSubtitleTranslations(_ files: [(subtitleURL: URL, mediaURL: URL?)], lines: [TimedText] = []) -> [UUID] {
        let known = Set(jobs.filter { !$0.status.isFinished && $0.kind == .subtitleTranslation }.map(\.sourceURL))
        let newJobs = files.filter { !known.contains($0.subtitleURL) }.map { Job(subtitlesAt: $0.subtitleURL, mediaURL: $0.mediaURL, lines: lines) }
        jobs += newJobs
        publish()
        for job in newJobs {
            log(.detail, job.id, "\(job.sourceURL.lastPathComponent): queued for translation")
        }
        return newJobs.map(\.id)
    }

    /// The editor's version of a finished job's subtitles; `save` writes them.
    public func replaceSegments(of jobID: UUID, with segments: [TimedText]) {
        update(jobID) { $0.segments = segments }
    }

    /// Writes a finished job's current subtitles over the files it produced.
    public func saveSubtitles(of jobID: UUID) throws -> [URL] {
        guard let job = jobs.first(where: { $0.id == jobID }), job.status.isFinished, !job.outputURLs.isEmpty else {
            throw JobQueueError.nothingToSave
        }
        try SubtitleFileWriter.rewrite(job.segments, to: job.outputURLs)
        log(.info, jobID, "Saved \(job.outputURLs.map(\.lastPathComponent).joined(separator: ", "))")
        return job.outputURLs
    }

    public func remove(_ jobID: UUID) {
        if jobID == runningJobID {
            currentJobTask?.cancel()
        }
        jobs.removeAll { $0.id == jobID }
        publish()
    }

    public func removeFinished() {
        jobs.removeAll { $0.status.isFinished }
        publish()
    }

    /// Cancels one job; the queue moves on to the next.
    public func cancel(_ jobID: UUID) {
        if jobID == runningJobID {
            currentJobTask?.cancel()
        } else {
            update(jobID) { $0.status = .cancelled }
        }
    }

    /// Stops after interrupting the running job, which goes back to waiting;
    /// queued jobs stay queued for the next `start`.
    public func stop() {
        guard let runningTask else {
            return
        }
        isStopping = true
        currentJobTask?.cancel()
        runningTask.cancel()
    }

    /// Cancels the running job, waits for it to stop and frees the model.
    public func shutDown() async {
        currentJobTask?.cancel()
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
        while !Task.isCancelled, let job = jobs.first(where: { $0.status == .queued }) {
            runningJobID = job.id
            let jobTask = Task { await process(job, configuration: configuration) }
            currentJobTask = jobTask
            await jobTask.value
            currentJobTask = nil
            runningJobID = nil
        }
        // Gigabytes of weights and buffers: free them while idle. The next
        // start loads the model again (memory-mapped, about half a second).
        if await engine.isLoaded {
            await engine.unload()
            log(.detail, nil, "Model unloaded")
        }
        runningTask = nil
        isStopping = false
    }

    private func process(_ job: Job, configuration: Configuration) async {
        let fileName = job.sourceURL.lastPathComponent
        let jobStart = ContinuousClock.now
        log(.info, job.id, "\(fileName): started")
        do {
            let segments: [TimedText]
            var nameSuffix = ""
            switch job.kind {
            case .transcription(let model):
                segments = try await transcribe(job, with: model, configuration: configuration)
            case .subtitleEditing:
                return  // ready since it was opened; never queued
            case .subtitleTranslation:
                guard let llm = configuration.llm, llm.isUsable else {
                    throw JobQueueError.languageModelRequired
                }
                segments = try await translateSubtitles(of: job, with: llm)
                // Never overwrite the file being translated: "movie.简体中文.srt".
                nameSuffix = "." + SubtitleFileWriter.safeNamePart(llm.settings.targetLanguage)
            }

            update(job.id) { $0.status = .exporting }
            let outputURLs = try SubtitleFileWriter.write(segments, for: job.sourceURL, settings: configuration.output, nameSuffix: nameSuffix)
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
            let requeues = isStopping
            update(job.id) {
                $0.status = requeues ? .queued : .cancelled
                $0.segments = []
            }
            log(.warning, job.id, requeues ? "\(fileName): stopped, waiting to start again" : "\(fileName): cancelled")
        } catch {
            update(job.id) {
                $0.status = .failed(message: error.localizedDescription)
                $0.segments = []
            }
            log(.error, job.id, "\(fileName): \(error.localizedDescription)")
        }
    }

    /// Speech recognition, then (optionally) the language model.
    private func transcribe(_ job: Job, with model: RecognitionModel, configuration: Configuration) async throws -> [TimedText] {
        update(job.id) { $0.status = .loadingModel }
        let pipeline = try await loadPipeline(model, for: job.id, settings: configuration.engine)
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
            let refinerJob: SubtitleRefiner.Job = model.llmMode == .polish
                ? .polishChinese
                : .translate(targetLanguage: llm.settings.targetLanguage)
            do {
                segments = try await refine(segments, jobID: job.id, as: refinerJob, with: llm)
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                // The machine subtitles are still worth keeping.
                update(job.id) { $0.warning = "LLM step skipped: \(error.localizedDescription)" }
            }
        }
        return segments
    }

    /// An existing subtitle file through the language model; here the
    /// translation is the whole job, so its errors fail the job.
    private func translateSubtitles(of job: Job, with llm: LLMConfiguration) async throws -> [TimedText] {
        update(job.id) { $0.status = .readingSubtitles }
        let original = job.segments.isEmpty ? try SubtitleParser.parse(fileAt: job.sourceURL) : job.segments
        log(.info, job.id, "Read \(original.count) subtitles")
        update(job.id) { $0.segments = original }  // shown while translating
        return try await refine(original, jobID: job.id, as: .translateSubtitles(targetLanguage: llm.settings.targetLanguage), with: llm)
    }

    private func loadPipeline(_ model: RecognitionModel, for jobID: UUID, settings: EngineSettings) async throws -> TranscriptionPipeline {
        let engineName = settings.backend.displayName
        if await engine.isLoaded(model, settings: settings) {
            log(.detail, jobID, "\(model.displayName) is already loaded (\(engineName))")
            return try await engine.pipeline(for: model, settings: settings)
        }
        let weights = settings.backend.weights(of: model)
        let size = weights.flatMap(ActivityFormatting.fileSize(of:)).map { ", \($0)" } ?? ""
        log(.info, jobID, "Loading \(model.displayName) with \(engineName)…")
        log(.detail, jobID, "Weights: \(weights?.path ?? "none")\(size)")
        log(.detail, jobID, "Decoding: task \(model.decoding.task.rawValue), language \(model.decoding.languageCode), "
            + "temperatures \(model.decoding.temperatures.map { String(format: "%.1f", $0) }.joined(separator: "/")), "
            + "\(settings.concurrentChunkCount) chunk(s) at once")
        let start = ContinuousClock.now
        let pipeline = try await engine.pipeline(for: model, settings: settings)
        log(.info, jobID, "\(model.displayName) loaded in \(ActivityFormatting.seconds(ContinuousClock.now - start))")
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

    /// Runs the language model over `segments`; translations keep the
    /// original line underneath when the settings ask for bilingual subtitles.
    private func refine(_ segments: [TimedText], jobID: UUID, as refinerJob: SubtitleRefiner.Job, with llm: LLMConfiguration) async throws -> [TimedText] {
        let refiner = SubtitleRefiner(
            client: makeChatClient(llm.settings.baseURL, llm.apiKey),
            configuration: SubtitleRefiner.Configuration(model: llm.settings.model)
        )
        update(jobID) {
            $0.status = .refining(completedBatches: 0, totalBatches: 1)
            $0.segments = segments  // finished batches replace their lines as they arrive
        }
        let action = if case .polishChinese = refinerJob { "Polishing" } else { "Translating" }
        log(.info, jobID, "\(action) \(segments.count) subtitles with \(llm.settings.model)…")
        let start = ContinuousClock.now
        let result = try await withOrderedProgress { (queue, batch: SubtitleRefiner.BatchProgress) in
            queue.update(jobID) { job in
                job.status = .refining(completedBatches: batch.completed, totalBatches: batch.total)
                for (index, text) in batch.lines where job.segments.indices.contains(index) {
                    job.segments[index].text = text
                }
            }
            queue.log(.detail, jobID, "LLM batch \(batch.completed)/\(batch.total) done")
        } work: { report in
            try await refiner.refine(segments, job: refinerJob, glossary: llm.settings.glossaryEntries, progress: report)
        }
        log(.info, jobID, "LLM step finished in \(ActivityFormatting.seconds(ContinuousClock.now - start))")
        if result.failedBatchCount > 0 {
            let warning = "\(result.failedBatchCount) of \(result.batchCount) LLM batches failed; those lines kept their original text (\(result.firstFailure ?? "unknown error"))"
            update(jobID) { $0.warning = warning }
            log(.warning, jobID, warning)
        }
        let refined = result.segments
        switch refinerJob {
        case .translate, .translateSubtitles:
            return llm.settings.keepsOriginalLine ? refined.withOriginalLines(from: segments) : refined
        case .polishChinese:
            return refined
        }
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

public enum JobQueueError: LocalizedError, Equatable {
    case languageModelRequired
    case nothingToSave

    public var errorDescription: String? {
        switch self {
        case .nothingToSave: "Only finished files with written subtitles can be saved."
        case .languageModelRequired: "Translating subtitles needs the language model: turn it on and choose a model in Settings › LLM."
        }
    }
}
