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
    private static let isAvailable = FileManager.default.fileExists(atPath: models.appendingPathComponent("whisper/whisper-ja-1.5b.bin").path)
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

        await queue.add([Self.sample], task: .transcribe)
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

        let job = try #require(finishedJob)
        #expect(job.status == .completed)
        #expect(sawTranscribing)
        #expect(job.segments.count == 6)  // the CLI and the original both give 6 on this sample
        #expect(job.outputURLs.map(\.lastPathComponent) == ["tts-long.srt", "tts-long.lrc"])
        for url in job.outputURLs {
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    @Test func reportsMissingModelsAsAFailedJob() async throws {
        let queue = JobQueue()
        let configuration = JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: URL(fileURLWithPath: "/nonexistent"), backend: .whisperCpp, concurrentChunkCount: 1),
            output: OutputSettings(formats: [.srt], directory: nil)
        )
        await queue.add([URL(fileURLWithPath: "/tmp/sample.wav")], task: .translate)
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
        await queue.add([Self.sample], task: .transcribe)
        await queue.start(configuration: configuration)
        for await jobs in await queue.snapshots() {
            if let job = jobs.first, job.status.isFinished {
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
