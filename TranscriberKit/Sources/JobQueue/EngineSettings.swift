import Foundation
import TranscriberCore

/// What the engine needs to run, chosen in the app's settings.
public struct EngineSettings: Hashable, Sendable, Codable {
    public enum Backend: String, CaseIterable, Hashable, Sendable, Codable {
        case whisperCpp
        case mlx
    }

    /// Holds whisper/, mlx/ and vad/ as `make whisper-models mlx-models vad-model` lays them out.
    public var modelsDirectory: URL
    public var backend: Backend
    public var concurrentChunkCount: Int

    public init(modelsDirectory: URL, backend: Backend, concurrentChunkCount: Int) {
        self.modelsDirectory = modelsDirectory
        self.backend = backend
        self.concurrentChunkCount = concurrentChunkCount
    }

    /// Model files for a task, relative to `modelsDirectory`.
    static func modelName(for task: TranscriptionTask) -> String {
        switch task {
        case .translate: "chickenrice-v0.2"
        case .transcribe: "whisper-ja-1.5b"
        }
    }
}
