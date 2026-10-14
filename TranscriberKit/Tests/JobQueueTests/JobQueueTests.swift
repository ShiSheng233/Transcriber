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
            throw OpenRouterError.insufficientCredits
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
        let queue = JobQueue(makeChatClient: { _ in StubChat(fails: failingModel) })
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
