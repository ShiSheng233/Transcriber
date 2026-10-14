import Foundation
import JobQueue
import LLMTranslation
import SubtitleExport
import TranscriberCore

/// Everything the user can change in Settings, saved in UserDefaults.
struct AppSettings: Codable, Equatable {
    var modelsDirectory: URL
    /// The `id` of a model.json in the models folder.
    var modelID: String
    var backend: EngineSettings.Backend
    var concurrentChunkCount: Int
    var formats: [SubtitleFormat]
    /// `nil`: next to each source file, like the original.
    var outputDirectory: URL?
    var llm: LLMSettings

    static let defaults = AppSettings(
        modelsDirectory: URL.applicationSupportDirectory.appendingPathComponent("Transcriber/Models", isDirectory: true),
        modelID: "chickenrice-v0.2",
        backend: .whisperCpp,
        concurrentChunkCount: 4,
        formats: [.srt, .vtt, .lrc],
        outputDirectory: nil,
        llm: .defaults
    )

    func queueConfiguration(apiKey: String) -> JobQueue.Configuration {
        JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: modelsDirectory, backend: backend, concurrentChunkCount: concurrentChunkCount),
            output: OutputSettings(formats: formats, directory: outputDirectory),
            llm: JobQueue.LLMConfiguration(settings: llm, apiKey: apiKey)
        )
    }
}

extension AppSettings {
    /// Settings saved before a field existed decode with that field's default.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = AppSettings.defaults
        modelsDirectory = try container.decodeIfPresent(URL.self, forKey: .modelsDirectory) ?? defaults.modelsDirectory
        modelID = try container.decodeIfPresent(String.self, forKey: .modelID) ?? defaults.modelID
        backend = try container.decodeIfPresent(EngineSettings.Backend.self, forKey: .backend) ?? defaults.backend
        concurrentChunkCount = try container.decodeIfPresent(Int.self, forKey: .concurrentChunkCount) ?? defaults.concurrentChunkCount
        formats = try container.decodeIfPresent([SubtitleFormat].self, forKey: .formats) ?? defaults.formats
        outputDirectory = try container.decodeIfPresent(URL.self, forKey: .outputDirectory)
        llm = try container.decodeIfPresent(LLMSettings.self, forKey: .llm) ?? defaults.llm
    }
}
