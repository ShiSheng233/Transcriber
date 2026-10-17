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
    /// whisper.cpp only: the Neural Engine encoder for models converted for it.
    var usesNeuralEngineEncoder: Bool
    /// Optional removal of likely-wrong subtitles; all off by default.
    var filter: SubtitleFilterSettings
    var formats: [SubtitleFormat]
    /// `nil`: next to each source file, like the original.
    var outputDirectory: URL?
    var llm: LLMSettings

    static let defaults = AppSettings(
        modelsDirectory: URL.applicationSupportDirectory.appendingPathComponent("Transcriber/Models", isDirectory: true),
        modelID: "whisper-ja-1.5b",
        backend: .whisperCpp,
        concurrentChunkCount: 4,
        usesNeuralEngineEncoder: true,
        filter: .none,
        formats: [.srt, .vtt, .lrc],
        outputDirectory: nil,
        llm: .defaults
    )

    /// Uses the key stored for the chosen LLM service.
    func queueConfiguration(apiKeys: any APIKeyStoring) -> JobQueue.Configuration {
        let apiKey = apiKeys.read(for: llm.baseURL)
        return JobQueue.Configuration(
            engine: EngineSettings(
                modelsDirectory: modelsDirectory,
                backend: backend,
                concurrentChunkCount: concurrentChunkCount,
                usesNeuralEngineEncoder: usesNeuralEngineEncoder
            ),
            filter: filter,
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
        usesNeuralEngineEncoder = try container.decodeIfPresent(Bool.self, forKey: .usesNeuralEngineEncoder) ?? defaults.usesNeuralEngineEncoder
        filter = try container.decodeIfPresent(SubtitleFilterSettings.self, forKey: .filter) ?? defaults.filter
        formats = try container.decodeIfPresent([SubtitleFormat].self, forKey: .formats) ?? defaults.formats
        outputDirectory = try container.decodeIfPresent(URL.self, forKey: .outputDirectory)
        llm = try container.decodeIfPresent(LLMSettings.self, forKey: .llm) ?? defaults.llm
    }
}
