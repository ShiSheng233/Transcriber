import Foundation
import TranscriberCore

/// What the engine needs to run, chosen in the app's settings.
public struct EngineSettings: Hashable, Sendable, Codable {
    public enum Backend: String, CaseIterable, Hashable, Sendable, Codable {
        case whisperCpp
        case mlx
    }

    /// One folder per model (each with a model.json) plus vad/, as
    /// `make whisper-models mlx-models vad-model` lays them out.
    public var modelsDirectory: URL
    public var backend: Backend
    public var concurrentChunkCount: Int

    public init(modelsDirectory: URL, backend: Backend, concurrentChunkCount: Int) {
        self.modelsDirectory = modelsDirectory
        self.backend = backend
        self.concurrentChunkCount = concurrentChunkCount
    }
}

extension EngineSettings.Backend {
    public var displayName: String {
        switch self {
        case .whisperCpp: "whisper.cpp"
        case .mlx: "MLX"
        }
    }

    /// The weights this engine loads for `model`.
    public func weights(of model: RecognitionModel) -> URL? {
        switch self {
        case .whisperCpp: model.files.whisperCpp
        case .mlx: model.files.mlx
        }
    }
}
