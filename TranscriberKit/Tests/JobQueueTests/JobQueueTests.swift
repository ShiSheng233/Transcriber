import Foundation
import Testing
import SubtitleExport
import LLMTranslation
import TranscriberCore
@testable import JobQueue

/// Answers every batch by prefixing each line, or fails.
struct StubChat: StructuredChatCompleting {
    let fails: Bool

    func completeJSON(model: String, messages: [ChatMessage], schemaName: String, schema: [String: any Sendable], temperature: Double) async throws -> Data {
        if fails {
            throw LLMServiceError.insufficientCredits
        }
        let payload = try JSONSerialization.jsonObject(with: Data(messages[1].content.utf8)) as? [String: Any]
        let lines = (payload?["lines"] as? [[String: Any]] ?? []).map { ["id": $0["id"] ?? 0, "text": "EN: \($0["text"] ?? "")"] }
        return try JSONSerialization.data(withJSONObject: ["lines": lines])
    }
}

/// Runs a real job through the queue (engine, pipeline, file writer).
/// Needs the repository's Models/ and ParityMedia/tts-long.wav, so it is
/// skipped where they are missing.
struct JobQueueTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let models = repository.appendingPathComponent("Models")
    private static let sample = repository.appendingPathComponent("ParityMedia/tts-long.wav")
    private static let whisperJa = ModelCatalog.scan(models).model(withID: "whisper-ja-1.5b")
    private static let isAvailable = whisperJa.map { FileManager.default.fileExists(atPath: $0.files.whisperCpp?.path ?? "") } == true
        && FileManager.default.fileExists(atPath: sample.path)

    @Test(.enabled(if: isAvailable), .timeLimit(.minutes(5)))
    func transcribesAQueuedFileAndWritesSubtitles() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let queue = JobQueue()
        let configuration = JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: Self.models, backend: .whisperCpp, concurrentChunkCount: 4),
            output: OutputSettings(formats: [.srt, .lrc], directory: outputDirectory)
        )

        await queue.add([Self.sample], model: try #require(Self.whisperJa))
        await queue.start(configuration: configuration)

        var sawTranscribing = false
        var finishedJob: Job?
        for await jobs in await queue.snapshots() {
            guard let job = jobs.first else { continue }
            if case .transcribing = job.status { sawTranscribing = true }
            if job.status.isFinished {
                finishedJob = job
                break
            }
        }

        await queue.shutDown()  // free the model: ggml checks at process exit
        let job = try #require(finishedJob)
        #expect(job.status == .completed)
        #expect(sawTranscribing)
        #expect(job.segments.count == 6)  // the CLI and the original both give 6 on this sample
        #expect(job.outputURLs.map(\.lastPathComponent) == ["tts-long.srt", "tts-long.lrc"])
        for url in job.outputURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }

        // The log replays its history; every step comes before "done".
        var messages: [String] = []
        for await entry in await queue.logs() {
            messages.append(entry.message)
            if entry.message.contains(": done in") {
                break
            }
        }
        let loaded = messages.firstIndex { $0.contains("loaded in") || $0.contains("already loaded") }
        let lastChunk = messages.firstIndex { $0.hasPrefix("Chunk 3/3") }
        let merged = messages.firstIndex { $0 == "Merged into 6 subtitle(s)" }
        #expect(loaded != nil && lastChunk != nil && merged != nil)
        #expect(messages.contains { $0.hasPrefix("Speech: ") })
        #expect(messages.last?.hasSuffix("6 subtitles") == true)
        if let loaded, let lastChunk, let merged {
            #expect(loaded < lastChunk && lastChunk < merged && merged < messages.count - 1)
        }
    }

    @Test func reportsMissingModelsAsAFailedJob() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let modelFolder = folder.appendingPathComponent("test-model")
        try FileManager.default.createDirectory(at: modelFolder, withIntermediateDirectories: true)
        try Data(#"{"id": "test-model", "name": "Test", "language": "ja", "task": "translate", "llm_mode": "polish"}"#.utf8)
            .write(to: modelFolder.appendingPathComponent("model.json"))
        let model = try #require(ModelCatalog.scan(folder).model(withID: "test-model"))

        let queue = JobQueue()
        let configuration = JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: URL(fileURLWithPath: "/nonexistent"), backend: .whisperCpp, concurrentChunkCount: 1),
            output: OutputSettings(formats: [.srt], directory: nil)
        )
        await queue.add([URL(fileURLWithPath: "/tmp/sample.wav")], model: model)
        await queue.start(configuration: configuration)
        for await jobs in await queue.snapshots() {
            if let job = jobs.first, job.status.isFinished {
                guard case .failed(let message) = job.status else {
                    Issue.record("expected a failure, got \(job.status)")
                    return
                }
                #expect(message.contains("Model not found"))
                return
            }
        }
    }

    private func runTranscribeJob(llm: JobQueue.LLMConfiguration, failingModel: Bool) async throws -> Job {
        let outputDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }
        let queue = JobQueue(makeChatClient: { _, _ in StubChat(fails: failingModel) })
        let configuration = JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: Self.models, backend: .whisperCpp, concurrentChunkCount: 4),
            output: OutputSettings(formats: [.srt], directory: outputDirectory),
            llm: llm
        )
        await queue.add([Self.sample], model: try #require(Self.whisperJa))
        await queue.start(configuration: configuration)
        for await jobs in await queue.snapshots() {
            if let job = jobs.first, job.status.isFinished {
                await queue.shutDown()
                return job
            }
        }
        throw CancellationError()
    }

    @Test(.enabled(if: isAvailable), .timeLimit(.minutes(5)))
    func translatesWithTheLanguageModelAndKeepsOriginals() async throws {
        var settings = LLMSettings.defaults
        settings.isEnabled = true
        settings.model = "test/model"
        settings.keepsOriginalLine = true
        let job = try await runTranscribeJob(llm: .init(settings: settings, apiKey: "sk-test"), failingModel: false)

        #expect(job.status == .completed)
        #expect(job.warning == nil)
        #expect(job.segments.count == 6)
        #expect(job.segments.allSatisfy { $0.text.hasPrefix("EN: ") && $0.text.contains("\n") })
    }

    @Test(.enabled(if: isAvailable), .timeLimit(.minutes(5)))
    func keepsMachineSubtitlesWhenTheLanguageModelFails() async throws {
        var settings = LLMSettings.defaults
        settings.isEnabled = true
        settings.model = "test/model"
        let job = try await runTranscribeJob(llm: .init(settings: settings, apiKey: "sk-test"), failingModel: true)

        #expect(job.status == .completed)
        #expect(job.warning?.contains("credits") == true)
        #expect(job.segments.count == 6)
        #expect(!job.segments.contains { $0.text.hasPrefix("EN: ") })
    }
}

/// Stop and Cancel, with a real model (skipped where Models/ is missing).
struct JobQueueStopTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let models = repository.appendingPathComponent("Models")
    private static let sample = repository.appendingPathComponent("ParityMedia/tts-long.wav")
    private static let whisperJa = ModelCatalog.scan(models).model(withID: "whisper-ja-1.5b")
    private static let isAvailable = whisperJa != nil && FileManager.default.fileExists(atPath: sample.path)

    private func startTwoJobs() async throws -> (JobQueue, [Job]) {
        let queue = JobQueue()
        let configuration = JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: Self.models, backend: .whisperCpp, concurrentChunkCount: 1),
            output: OutputSettings(formats: [], directory: FileManager.default.temporaryDirectory)
        )
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).wav")
        try FileManager.default.copyItem(at: Self.sample, to: copy)
        await queue.add([Self.sample, copy], model: try #require(Self.whisperJa))
        await queue.start(configuration: configuration)
        // Wait until the first job is transcribing.
        for await jobs in await queue.snapshots() {
            if case .transcribing = jobs[0].status {
                return (queue, jobs)
            }
        }
        throw CancellationError()
    }

    private func waitUntilIdle(_ queue: JobQueue) async -> [Job] {
        while await queue.isRunning {
            try? await Task.sleep(for: .milliseconds(50))
        }
        var latest: [Job] = []
        for await jobs in await queue.snapshots() {
            latest = jobs
            break
        }
        return latest
    }

    @Test(.enabled(if: isAvailable), .timeLimit(.minutes(5)))
    func stopPutsTheRunningJobBackAndKeepsTheRest() async throws {
        let (queue, _) = try await startTwoJobs()
        await queue.stop()
        let jobs = await waitUntilIdle(queue)
        await queue.shutDown()
        #expect(jobs.map(\.status) == [.queued, .queued])
    }

    @Test(.enabled(if: isAvailable), .timeLimit(.minutes(5)))
    func cancellingTheRunningJobMovesOnToTheNext() async throws {
        let (queue, jobs) = try await startTwoJobs()
        await queue.cancel(jobs[0].id)
        let finished = await waitUntilIdle(queue)
        await queue.shutDown()
        #expect(finished.map(\.status) == [.cancelled, .completed])
    }
}

/// The process's memory footprint, as Activity Monitor's "Memory" column.
private func physicalFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

struct JobQueueMemoryTests {
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let models = repository.appendingPathComponent("Models")
    private static let sample = repository.appendingPathComponent("ParityMedia/tts-long.wav")
    private static let whisperJa = ModelCatalog.scan(models).model(withID: "whisper-ja-1.5b")
    private static let isAvailable = whisperJa != nil && FileManager.default.fileExists(atPath: sample.path)

    /// whisper.cpp only: `swift test` has no Metal library for MLX.
    @Test(.enabled(if: isAvailable), .timeLimit(.minutes(5)))
    func freesTheModelWhenTheQueueIsDone() async throws {
        let backend = EngineSettings.Backend.whisperCpp
        let engine = TranscriptionEngine()
        let queue = JobQueue(engine: engine)
        await queue.add([Self.sample], model: try #require(Self.whisperJa))
        await queue.start(configuration: JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: Self.models, backend: backend, concurrentChunkCount: 4),
            output: OutputSettings(formats: [], directory: FileManager.default.temporaryDirectory)
        ))
        var peak: UInt64 = 0
        while await queue.isRunning {
            peak = max(peak, physicalFootprint())
            try await Task.sleep(for: .milliseconds(20))
        }
        let idle = physicalFootprint()

        #expect(await engine.isLoaded == false)
        // The 1.5B model alone is about 3 GB; most of the peak must be gone.
        #expect(peak > idle + 2_000_000_000, "peak \(peak / 1_000_000) MB, idle \(idle / 1_000_000) MB")
    }
}
