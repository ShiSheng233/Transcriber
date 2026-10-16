import AudioOverview
import Foundation
import LLMTranslation
import MediaDecoding
import SubtitleExport
import TranscriberCore
import TranscriptionPipeline

/// Runs jobs one at a time (each one already uses the GPU fully) and
/// publishes a snapshot of all jobs after every change.
public actor JobQueue {
    public struct Configuration: Sendable {
        public var engine: EngineSettings
        /// Optional removal of likely-wrong subtitles; off reproduces the original.
        public var filter: SubtitleFilterSettings
        public var output: OutputSettings
        /// `nil` skips the LLM step.
        public var llm: LLMConfiguration?

        public init(engine: EngineSettings, filter: SubtitleFilterSettings = .none, output: OutputSettings, llm: LLMConfiguration? = nil) {
            self.engine = engine
            self.filter = filter
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
    /// Keeps finished LLM batches, so a run started again reuses them.
    private let llmReplyCache: LLMReplyCache?
    /// Gets each transcribed file's waveform, made from the audio the
    /// transcription decodes anyway, so the editor need not decode it again.
    private let waveformCache: WaveformCache?
    private var jobs: [Job] = []
    private var runningTask: Task<Void, Never>?
    /// The stage each started job is in (recognition, or waiting for or in
    /// the language model step), so one job can be cancelled alone.
    private var jobTasks: [UUID: Task<Void, Never>] = [:]
    /// The last language model step handed over; each step waits for the
    /// one before, so they run one at a time and in order.
    private var languageModelLane: Task<Void, Never>?
    /// Steps handed to the lane that have not ended.
    private var pendingLanguageModelStepCount = 0
    /// When each running job started, for the "done in" figure.
    private var jobStarts: [UUID: ContinuousClock.Instant] = [:]
    /// The idle queue waiting for a language model step to end or a job to arrive.
    private var driverWakeUp: CheckedContinuation<Void, Never>?
    /// Set by `stop()`: interrupted jobs go back to the queue.
    private var isStopping = false
    /// One recognition at a time, the queue's or a re-transcription's: each
    /// already uses the GPU fully.
    private var isRecognizing = false
    private var recognitionWaiters: [CheckedContinuation<Void, Never>] = []
    private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]
    private static let logCapacity = 5_000
    private var logEntries: [LogEntry] = []
    private var logObservers: [UUID: AsyncStream<LogEntry>.Continuation] = [:]
    /// When the running job's transcription started, for the speed figure.
    private var transcriptionStart: ContinuousClock.Instant?
    private var audioDuration: AudioTime?

    public init(
        engine: TranscriptionEngine = TranscriptionEngine(),
        makeChatClient: @escaping @Sendable (_ baseURL: URL, _ apiKey: String) -> any StructuredChatCompleting = { ChatCompletionsClient(baseURL: $0, apiKey: $1) },
        llmReplyCache: LLMReplyCache? = nil,
        waveformCache: WaveformCache? = nil
    ) {
        self.engine = engine
        self.makeChatClient = makeChatClient
        self.llmReplyCache = llmReplyCache
        self.waveformCache = waveformCache
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
        wakeDriver()
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
        wakeDriver()
        for job in newJobs {
            log(.detail, job.id, "\(job.sourceURL.lastPathComponent): queued for translation")
        }
        return newJobs.map(\.id)
    }

    /// The editor's version of a finished job's subtitles; `save` writes them.
    public func replaceSegments(of jobID: UUID, with segments: [TimedText]) {
        update(jobID) { $0.segments = segments }
    }

    /// Whether `changeModel` can act on the job: a transcription that is
    /// waiting or finished.
    public func canChangeModel(of jobID: UUID) -> Bool {
        guard let job = jobs.first(where: { $0.id == jobID }), job.model != nil, jobTasks[jobID] == nil else {
            return false
        }
        return job.status == .queued || job.status.isFinished
    }

    /// Transcribes the file with `model` instead: a waiting job switches, a
    /// finished one goes back to the queue (its files are written again).
    public func changeModel(of jobID: UUID, to model: RecognitionModel) {
        guard canChangeModel(of: jobID), let index = jobs.firstIndex(where: { $0.id == jobID }) else {
            return
        }
        let job = jobs[index]
        jobs[index] = Job(id: job.id, sourceURL: job.sourceURL, model: model)
        publish()
        log(.detail, jobID, "\(job.sourceURL.lastPathComponent): queued with \(model.displayName)")
        wakeDriver()
    }

    public struct Retranscription: Sendable {
        /// The lines given, with the chosen ones replaced by the new ones.
        public let lines: [TimedText]
        /// Where the new lines are in `lines`.
        public let newLineIndices: [Int]
        /// New lines the language model did not answer; nil if it did not run.
        public let untranslatedCount: Int?
    }

    /// Recognizes the time the chosen lines cover again and puts the new
    /// lines in their place; when the job went through the language model
    /// and it is on, the new lines go through it too. Waits for a
    /// recognition the queue is running.
    /// - Parameters:
    ///   - lines: the job's lines as the editor has them; the chosen ones
    ///     and any between them are replaced.
    ///   - model: used when the job has none (a subtitle file with media).
    public func retranscribe(
        _ lineIndices: [Int],
        of lines: [TimedText],
        in jobID: UUID,
        model: RecognitionModel?,
        configuration: Configuration
    ) async throws -> Retranscription {
        let chosen = lineIndices.filter(lines.indices.contains).sorted()
        guard let job = jobs.first(where: { $0.id == jobID }), let first = chosen.first, let last = chosen.last else {
            throw JobQueueError.nothingToRetranscribe
        }
        guard let mediaURL = job.mediaURL else {
            throw JobQueueError.noMediaToTranscribe
        }
        guard let model = job.model ?? model else {
            throw JobQueueError.noSpeechModel
        }
        let replaced = first...last
        let start = lines[replaced].map(\.start).min() ?? lines[first].start
        let end = lines[replaced].map(\.end).max() ?? lines[last].end
        log(.info, jobID, "Transcribing \(ActivityFormatting.clock(start.seconds))–\(ActivityFormatting.clock(end.seconds)) again with \(model.displayName)…")

        let segments = try await recognizeRange(from: start, to: end, of: mediaURL, with: model, for: jobID, configuration: configuration)
        log(.info, jobID, "\(lines[replaced].count) line(s) replaced by \(segments.count)")

        var updated = Array(lines[..<first]) + segments + Array(lines[(last + 1)...])
        let newLineIndices = Array(first..<(first + segments.count))
        let hadLanguageModel = !job.linesBeforeLanguageModel.isEmpty
        // The new machine lines become the source for any later retranslation.
        update(jobID) { job in
            guard hadLanguageModel else { return }
            job.linesBeforeLanguageModel = (job.linesBeforeLanguageModel.filter { $0.end <= start || $0.start >= end } + segments)
                .sorted { $0.start < $1.start }
        }
        guard hadLanguageModel, let llm = configuration.llm, llm.isUsable, !segments.isEmpty else {
            return Retranscription(lines: updated, newLineIndices: newLineIndices, untranslatedCount: nil)
        }
        let translated = try await retranslate(newLineIndices, of: updated, in: jobID, with: llm)
        updated = translated.lines
        return Retranscription(lines: updated, newLineIndices: newLineIndices, untranslatedCount: translated.unansweredCount)
    }

    public struct Retranslation: Sendable {
        /// The lines given, with the answered ones replaced.
        public let lines: [TimedText]
        /// Chosen lines the model did not answer; they keep their text.
        public let unansweredCount: Int
    }

    /// Sends chosen lines of a job through the language model again, e.g.
    /// after a batch failed or a translation came out wrong. Each line is
    /// sent as it was before the language model ran (matched by its times),
    /// or as it is now if it is new or its times changed; its neighbors go
    /// along as context. Cached replies are not reused.
    /// - Parameter lines: the job's lines as the editor has them.
    public func retranslate(_ lineIndices: [Int], of lines: [TimedText], in jobID: UUID, with llm: LLMConfiguration) async throws -> Retranslation {
        guard let job = jobs.first(where: { $0.id == jobID }), llm.isUsable else {
            throw JobQueueError.languageModelRequired
        }
        let refinerJob: SubtitleRefiner.Job = switch job.model?.llmMode {
        case .polish: .polishChinese
        case .translate: .translate(targetLanguage: llm.settings.targetLanguage)
        case nil: .translateSubtitles(targetLanguage: llm.settings.targetLanguage)
        }
        var originalByTimes: [TimeRange: String] = [:]
        for line in job.linesBeforeLanguageModel where originalByTimes[TimeRange(line)] == nil {
            originalByTimes[TimeRange(line)] = line.text
        }
        let sources = lines.map { line in
            TimedText(start: line.start, end: line.end, text: originalByTimes[TimeRange(line)] ?? line.text, confidence: line.confidence)
        }
        let chosen = lineIndices.filter(lines.indices.contains)
        log(.info, jobID, "Sending \(chosen.count) line(s) to \(llm.settings.model) again…")
        let result = try await makeRefiner(for: llm).refine(
            sources, job: refinerJob, glossary: llm.settings.glossaryEntries, lineIndices: chosen, reusesCachedReplies: false
        )
        let keepsOriginal = llm.settings.keepsOriginalLine && !(job.model?.llmMode == .polish)
        var updated = lines
        for (index, text) in result.answeredLines where chosen.contains(index) {
            // Bilingual only when the source is known; otherwise it may be a translation already.
            let hasSource = originalByTimes[TimeRange(lines[index])] != nil
            updated[index].text = keepsOriginal && hasSource ? "\(text)\n\(sources[index].text)" : text
        }
        let unanswered = chosen.count - result.answeredLines.count
        log(unanswered > 0 ? .warning : .info, jobID, unanswered > 0
            ? "\(unanswered) of \(chosen.count) line(s) got no answer and kept their text (\(result.firstFailure ?? "incomplete reply"))"
            : "\(chosen.count) line(s) updated")
        return Retranslation(lines: updated, unansweredCount: unanswered)
    }

    /// A line's times, to find it again after editing.
    private struct TimeRange: Hashable {
        let start: AudioTime
        let end: AudioTime

        init(_ line: TimedText) {
            start = line.start
            end = line.end
        }
    }

    private func makeRefiner(for llm: LLMConfiguration, marksHallucinations: Bool = false) -> SubtitleRefiner {
        var configuration = SubtitleRefiner.Configuration(model: llm.settings.model)
        configuration.marksHallucinations = marksHallucinations
        return SubtitleRefiner(client: makeChatClient(llm.settings.baseURL, llm.apiKey), configuration: configuration, cache: llmReplyCache)
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
        jobTasks[jobID]?.cancel()
        jobs.removeAll { $0.id == jobID }
        publish()
    }

    public func removeFinished() {
        jobs.removeAll { $0.status.isFinished }
        publish()
    }

    /// Cancels one job, in whichever stage it is; the queue goes on.
    public func cancel(_ jobID: UUID) {
        if let task = jobTasks[jobID] {
            task.cancel()
        } else {
            update(jobID) { $0.status = .cancelled }
        }
    }

    /// Stops after interrupting the running jobs, which go back to waiting;
    /// queued jobs stay queued for the next `start`.
    public func stop() {
        guard let runningTask else {
            return
        }
        isStopping = true
        for task in jobTasks.values {
            task.cancel()
        }
        runningTask.cancel()
        wakeDriver()
    }

    /// Cancels the running jobs, waits for them to stop and frees the model.
    public func shutDown() async {
        for task in jobTasks.values {
            task.cancel()
        }
        runningTask?.cancel()
        wakeDriver()
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

    /// Speech recognition runs one file at a time (it already uses the GPU
    /// fully). A file's language model step is handed to its own lane, so the
    /// next file is recognized meanwhile; those steps run one at a time, in
    /// order. The model stays loaded while files wait and is freed once none do.
    private func processQueuedJobs(configuration: Configuration) async {
        while !Task.isCancelled {
            if let job = jobs.first(where: { $0.status == .queued && jobTasks[$0.id] == nil }) {
                switch job.kind {
                case .transcription(let model):
                    let task = Task { await recognize(job, with: model, configuration: configuration) }
                    jobTasks[job.id] = task
                    await task.value
                    if jobTasks[job.id] == task {
                        jobTasks[job.id] = nil  // done, not handed to the language model lane
                    }
                case .subtitleTranslation:
                    handToLanguageModel(job, step: .translateSubtitles, configuration: configuration)
                case .subtitleEditing:
                    update(job.id) { $0.status = .completed }  // ready since it was opened; never queued
                }
                continue
            }
            // Gigabytes of weights and buffers: free them while no file waits.
            // The next file loads the model again (memory-mapped, about half a second).
            await unloadModel()
            guard !jobTasks.isEmpty else {
                break
            }
            await waitForWork()
        }
        // Stopped: every job records how it ended before the queue is idle.
        while let task = jobTasks.values.first {
            await task.value
            jobTasks = jobTasks.filter { $0.value != task }
        }
        await unloadModel()
        runningTask = nil
        isStopping = false
    }

    private func unloadModel() async {
        if !isRecognizing, await engine.isLoaded {
            await engine.unload()
            log(.detail, nil, "Model unloaded")
        }
    }

    private func waitForWork() async {
        await withCheckedContinuation { driverWakeUp = $0 }
    }

    private func wakeDriver() {
        driverWakeUp?.resume()
        driverWakeUp = nil
    }

    /// Waits until no other recognition runs; the caller then owns it.
    private func beginRecognition() async {
        guard isRecognizing else {
            isRecognizing = true
            return
        }
        await withCheckedContinuation { recognitionWaiters.append($0) }
    }

    /// `retranscribe`'s recognition, in turn with the queue's.
    private func recognizeRange(
        from start: AudioTime,
        to end: AudioTime,
        of mediaURL: URL,
        with model: RecognitionModel,
        for jobID: UUID,
        configuration: Configuration
    ) async throws -> [TimedText] {
        await beginRecognition()
        defer {
            endRecognition()
            if runningTask == nil {
                // The queue is idle, so nothing else needs the weights.
                Task { await unloadModel() }
            }
        }
        let pipeline = try await loadPipeline(model, for: jobID, settings: configuration.engine)
        return try await pipeline.transcribe(fileAt: mediaURL, from: start, to: end, options: .init(filter: configuration.filter))
    }

    /// Hands recognition to the next waiter, or frees it.
    private func endRecognition() {
        if recognitionWaiters.isEmpty {
            isRecognizing = false
        } else {
            recognitionWaiters.removeFirst().resume()
        }
    }

    /// Subtitles ready to be written, and what goes before the extension.
    private struct FinishedSubtitles {
        let segments: [TimedText]
        var nameSuffix = ""
    }

    /// Runs one stage of a job and records how it ended: written and
    /// completed when `body` returns subtitles, untouched when it returns
    /// nil (a later stage takes over), cancelled, put back, or failed.
    private func runStage(of job: Job, configuration: Configuration, _ body: () async throws -> FinishedSubtitles?) async {
        let fileName = job.sourceURL.lastPathComponent
        do {
            guard let finished = try await body() else {
                return
            }
            update(job.id) { $0.status = .exporting }
            let outputURLs = try SubtitleFileWriter.write(
                finished.segments, for: job.sourceURL, settings: configuration.output, nameSuffix: finished.nameSuffix
            )
            update(job.id) {
                $0.segments = finished.segments
                $0.outputURLs = outputURLs
                $0.status = .completed
            }
            if let folder = outputURLs.first?.deletingLastPathComponent().path {
                log(.detail, job.id, "Wrote \(outputURLs.map(\.lastPathComponent).joined(separator: ", ")) to \(folder)")
            }
            let elapsed = jobStarts[job.id].map { " in \(ActivityFormatting.seconds(ContinuousClock.now - $0))" } ?? ""
            log(.info, job.id, "\(fileName): done\(elapsed), \(finished.segments.count) subtitles")
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
        jobStarts[job.id] = nil
    }

    private func markStarted(_ job: Job) {
        jobStarts[job.id] = ContinuousClock.now
        log(.info, job.id, "\(job.sourceURL.lastPathComponent): started")
    }

    /// Speech recognition; with the language model on, its step is handed
    /// to the lane and this returns without writing.
    private func recognize(_ job: Job, with model: RecognitionModel, configuration: Configuration) async {
        markStarted(job)
        await runStage(of: job, configuration: configuration) {
            await beginRecognition()
            defer { endRecognition() }
            let segments = try await recognizeSpeech(in: job, with: model, settings: configuration.engine, filter: configuration.filter)
            guard let llm = configuration.llm, llm.isUsable, !segments.isEmpty else {
                return FinishedSubtitles(segments: segments)
            }
            update(job.id) {
                $0.segments = segments
                $0.status = .refining(completedBatches: 0, totalBatches: 1)
            }
            handToLanguageModel(job, step: .refineRecognized(segments, model: model), configuration: configuration)
            return nil
        }
    }

    private enum LanguageModelStep: Sendable {
        /// A transcription's subtitles; a failure keeps them as they are.
        case refineRecognized([TimedText], model: RecognitionModel)
        /// A subtitle file; the translation is the whole job.
        case translateSubtitles
    }

    /// Queues the step behind the language model steps already handed over.
    private func handToLanguageModel(_ job: Job, step: LanguageModelStep, configuration: Configuration) {
        if pendingLanguageModelStepCount > 0 {
            log(.detail, job.id, "Waiting for the language model to finish the previous file")
        }
        pendingLanguageModelStepCount += 1
        let previous = languageModelLane
        let task = Task {
            await previous?.value
            await runLanguageModelStep(step, of: job, configuration: configuration)
        }
        languageModelLane = task
        jobTasks[job.id] = task
    }

    private func runLanguageModelStep(_ step: LanguageModelStep, of job: Job, configuration: Configuration) async {
        if case .translateSubtitles = step {
            markStarted(job)
        }
        await runStage(of: job, configuration: configuration) {
            try Task.checkCancellation()
            switch step {
            case .refineRecognized(let segments, let model):
                return FinishedSubtitles(segments: try await refineRecognized(segments, of: job, model: model, with: configuration.llm))
            case .translateSubtitles:
                guard let llm = configuration.llm, llm.isUsable else {
                    throw JobQueueError.languageModelRequired
                }
                // Never overwrite the file being translated: "movie.简体中文.srt".
                return FinishedSubtitles(
                    segments: try await translateSubtitles(of: job, with: llm),
                    nameSuffix: "." + SubtitleFileWriter.safeNamePart(llm.settings.targetLanguage)
                )
            }
        }
        jobTasks[job.id] = nil
        pendingLanguageModelStepCount -= 1
        wakeDriver()
    }

    /// A transcription through the language model; if that fails, the
    /// machine subtitles are still worth keeping.
    private func refineRecognized(
        _ segments: [TimedText],
        of job: Job,
        model: RecognitionModel,
        with llm: LLMConfiguration?
    ) async throws -> [TimedText] {
        guard let llm else {
            return segments
        }
        let refinerJob: SubtitleRefiner.Job = model.llmMode == .polish
            ? .polishChinese
            : .translate(targetLanguage: llm.settings.targetLanguage)
        do {
            var lines = segments
            var removesHallucinations = llm.settings.removesHallucinations
            // Japanese is proofread in Japanese first, so the translation starts
            // from what was said; polishing already corrects Chinese output.
            if llm.settings.proofreadsTranscript, model.llmMode == .translate {
                lines = try await refine(lines, jobID: job.id, as: .proofread, removesHallucinations: removesHallucinations, with: llm)
                removesHallucinations = false
            }
            return try await refine(lines, jobID: job.id, as: refinerJob, removesHallucinations: removesHallucinations, with: llm)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            update(job.id) { $0.warning = "LLM step skipped: \(error.localizedDescription)" }
            return segments
        }
    }

    /// Speech recognition alone. The pipeline lives only in this scope, so
    /// unloading the engine afterwards frees the model.
    private func recognizeSpeech(
        in job: Job,
        with model: RecognitionModel,
        settings: EngineSettings,
        filter: SubtitleFilterSettings
    ) async throws -> [TimedText] {
        update(job.id) { $0.status = .loadingModel }
        let pipeline = try await loadPipeline(model, for: job.id, settings: settings)
        update(job.id) { $0.status = .decodingAudio }
        log(.info, job.id, "Reading audio…")

        let jobID = job.id
        transcriptionStart = ContinuousClock.now
        audioDuration = nil
        let segments = try await withOrderedProgress { queue, progress in
            queue.record(progress, for: jobID)
        } work: { report in
            let options = TranscriptionPipeline.Options(filter: filter, audioDecoded: waveformKeeper(for: job.sourceURL))
            return try await pipeline.transcribe(fileAt: job.sourceURL, options: options, progress: report)
        }
        try Task.checkCancellation()
        logTranscriptionSpeed(for: job.id, segmentCount: segments.count)
        return segments
    }

    /// Stores the waveform of audio the transcription decoded; `nil` without a cache.
    private nonisolated func waveformKeeper(for mediaURL: URL) -> (@Sendable ([Float]) -> Void)? {
        guard let cache = waveformCache else { return nil }
        return { @Sendable samples in
            cache.store(Waveform(samples: samples), for: mediaURL)
        }
    }

    /// An existing subtitle file through the language model; here the
    /// translation is the whole job, so its errors fail the job.
    private func translateSubtitles(of job: Job, with llm: LLMConfiguration) async throws -> [TimedText] {
        update(job.id) { $0.status = .readingSubtitles }
        let original = job.segments.isEmpty ? try SubtitleParser.parse(fileAt: job.sourceURL) : job.segments
        log(.info, job.id, "Read \(original.count) subtitles")
        update(job.id) { $0.segments = original }  // shown while translating
        return try await refine(
            original, jobID: job.id, as: .translateSubtitles(targetLanguage: llm.settings.targetLanguage), removesHallucinations: false, with: llm
        )
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

    /// Holes would otherwise shift every later subtitle; say they were fixed.
    private func logTimestampJumps(_ jumps: [AudioTimestampJump], for jobID: UUID) {
        let holes = jumps.filter { $0.offset > .zero }
        let overlaps = jumps.count - holes.count
        let filledSeconds = holes.reduce(0) { $0 + $1.offset.seconds }
        var parts: [String] = []
        if !holes.isEmpty {
            parts.append("\(holes.count) hole(s) in the audio timeline (\(String(format: "%.1f", filledSeconds)) s) filled with silence")
        }
        if overlaps > 0 {
            parts.append("\(overlaps) overlap(s) trimmed")
        }
        log(.warning, jobID, parts.joined(separator: ", ") + ", so subtitles stay in sync")
        for jump in jumps {
            log(.detail, jobID, "Timestamp jump of \(String(format: "%+.2f", jump.offset.seconds)) s at \(ActivityFormatting.clock(jump.position.seconds))")
        }
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
    /// With `removesHallucinations`, lines the model marks as not speech are
    /// left out of the result.
    private func refine(
        _ segments: [TimedText],
        jobID: UUID,
        as refinerJob: SubtitleRefiner.Job,
        removesHallucinations: Bool,
        with llm: LLMConfiguration
    ) async throws -> [TimedText] {
        let refiner = makeRefiner(for: llm, marksHallucinations: removesHallucinations)
        update(jobID) {
            $0.status = .refining(completedBatches: 0, totalBatches: 1)
            $0.segments = segments  // finished batches replace their lines as they arrive
            $0.linesBeforeLanguageModel = segments
        }
        let action = switch refinerJob {
        case .proofread: "Proofreading"
        case .polishChinese: "Polishing"
        case .translate, .translateSubtitles: "Translating"
        }
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
        if result.reusedBatchCount > 0 {
            log(.detail, jobID, "\(result.reusedBatchCount) of \(result.batchCount) LLM batches reused from an earlier run")
        }
        if result.failedBatchCount > 0 {
            let warning = "\(result.failedBatchCount) of \(result.batchCount) LLM batches failed; those lines kept their original text (\(result.firstFailure ?? "unknown error"))"
            update(jobID) { $0.warning = warning }
            log(.warning, jobID, warning)
        }
        if case .proofread = refinerJob {
            let changed = result.answeredLines.filter { segments[$0.key].text != $0.value }.count
            log(.info, jobID, "\(changed) line(s) corrected")
        }
        var refined = result.segments
        if case .translate = refinerJob, llm.settings.keepsOriginalLine {
            refined = refined.withOriginalLines(from: segments)
        } else if case .translateSubtitles = refinerJob, llm.settings.keepsOriginalLine {
            refined = refined.withOriginalLines(from: segments)
        }
        guard !result.droppedLines.isEmpty else {
            return refined
        }
        for index in result.droppedLines.sorted() where segments.indices.contains(index) {
            log(.detail, jobID, "Removed as not speech: \(ActivityFormatting.clock(segments[index].start.seconds)) “\(segments[index].text)”")
        }
        log(.info, jobID, "\(result.droppedLines.count) line(s) removed as not speech")
        return refined.enumerated().filter { !result.droppedLines.contains($0.offset) }.map(\.element)
    }

    private func record(_ progress: TranscriptionPipeline.Progress, for jobID: UUID) {
        switch progress {
        case .decodedAudio(let duration, let timestampJumps):
            audioDuration = duration
            log(.detail, jobID, "Audio: \(ActivityFormatting.clock(duration.seconds)) at 16 kHz mono")
            if !timestampJumps.isEmpty {
                logTimestampJumps(timestampJumps, for: jobID)
            }
            update(jobID) { $0.status = .detectingSpeech }
            log(.info, jobID, "Detecting speech…")
        case .detectedSpeech(let spans, let padding):
            let speechSamples = spans.reduce(0) { $0 + max($1.duration.samples, 0) }
            log(.detail, jobID, "Speech: \(spans.count) span(s), \(ActivityFormatting.clock(AudioTime(samples: speechSamples).seconds)) in total")
            update(jobID) { $0.speechSpans = spans.compactMap { $0.trimmed(by: padding) } }
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
    case nothingToRetranscribe
    case noMediaToTranscribe
    case noSpeechModel

    public var errorDescription: String? {
        switch self {
        case .nothingToSave: "Only finished files with written subtitles can be saved."
        case .languageModelRequired: "Translating subtitles needs the language model: turn it on and choose a model in Settings › LLM."
        case .nothingToRetranscribe: "Select the lines to transcribe again."
        case .noMediaToTranscribe: "There is no media file to transcribe for these subtitles."
        case .noSpeechModel: "Choose a speech model in the toolbar first."
        }
    }
}
