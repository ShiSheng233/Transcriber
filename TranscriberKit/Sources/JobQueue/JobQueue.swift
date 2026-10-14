import Foundation
import TranscriberCore
import TranscriptionPipeline

/// Runs jobs one at a time (each one already uses the GPU fully) and
/// publishes a snapshot of all jobs after every change.
public actor JobQueue {
    public struct Configuration: Sendable {
        public var engine: EngineSettings
        public var output: OutputSettings

        public init(engine: EngineSettings, output: OutputSettings) {
            self.engine = engine
            self.output = output
        }
    }

    private let engine: TranscriptionEngine
    private var jobs: [Job] = []
    private var runningTask: Task<Void, Never>?
    private var runningJobID: UUID?
    private var observers: [UUID: AsyncStream<[Job]>.Continuation] = [:]

    public init(engine: TranscriptionEngine = TranscriptionEngine()) {
        self.engine = engine
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
            let segments = try await pipeline.transcribe(fileAt: job.sourceURL) { [weak self] progress in
                Task { await self?.record(progress, for: jobID) }
            }
            try Task.checkCancellation()

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
