import Foundation
import JobQueue
import SubtitleExport
import TranscriberCore

/// Everything the user can change in Settings, saved in UserDefaults.
struct AppSettings: Codable, Equatable {
    var modelsDirectory: URL
    var task: TranscriptionTask
    var backend: EngineSettings.Backend
    var concurrentChunkCount: Int
    var formats: [SubtitleFormat]
    /// `nil`: next to each source file, like the original.
    var outputDirectory: URL?

    static let defaults = AppSettings(
        modelsDirectory: URL.applicationSupportDirectory.appendingPathComponent("Transcriber/Models", isDirectory: true),
        task: .translate,
        backend: .whisperCpp,
        concurrentChunkCount: 4,
        formats: [.srt, .vtt, .lrc],
        outputDirectory: nil
    )

    var queueConfiguration: JobQueue.Configuration {
        JobQueue.Configuration(
            engine: EngineSettings(modelsDirectory: modelsDirectory, backend: backend, concurrentChunkCount: concurrentChunkCount),
            output: OutputSettings(formats: formats, directory: outputDirectory)
        )
    }
}
