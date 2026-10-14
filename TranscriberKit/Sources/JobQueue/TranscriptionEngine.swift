import Foundation
import SpeechDetection
import TranscriberCore
import TranscriptionPipeline
import WhisperCpp
import WhisperDecoding
import WhisperMLX

public enum TranscriptionEngineError: LocalizedError, Equatable {
    case missingModel(URL)
    /// The model's configuration names no files for the chosen engine.
    case unsupportedBackend(model: String, backend: EngineSettings.Backend)

    public var errorDescription: String? {
        switch self {
        case .missingModel(let url): "Model not found: \(url.path)"
        case .unsupportedBackend(let model, let backend): "\(model) has no \(backend.displayName) weights."
        }
    }
}

/// Builds pipelines on demand and keeps the most recent one loaded, since a
/// model takes seconds and gigabytes to load.
public actor TranscriptionEngine {
    private struct PipelineKey: Hashable {
        let settings: EngineSettings
        let model: RecognitionModel
    }

    private var loaded: (key: PipelineKey, pipeline: TranscriptionPipeline)?

    public init() {}

    /// Frees the loaded model. ggml's Metal device checks at process exit
    /// that every buffer was freed, so call this before quitting.
    public func unload() {
        loaded = nil
    }

    /// Whether `pipeline(for:settings:)` would return without loading.
    public func isLoaded(_ model: RecognitionModel, settings: EngineSettings) -> Bool {
        loaded?.key == PipelineKey(settings: settings, model: model)
    }

    public func pipeline(for model: RecognitionModel, settings: EngineSettings) throws -> TranscriptionPipeline {
        let key = PipelineKey(settings: settings, model: model)
        if let loaded, loaded.key == key {
            return loaded.pipeline
        }
        loaded = nil  // release the previous model before loading the next
        let pipeline = try Self.makePipeline(for: model, settings: settings)
        loaded = (key, pipeline)
        return pipeline
    }

    private static func makePipeline(for model: RecognitionModel, settings: EngineSettings) throws -> TranscriptionPipeline {
        let vadURL = try existing(settings.modelsDirectory.appendingPathComponent("vad/\(model.vadModelName).mlmodelc"))

        let backend: any WhisperBackend
        switch settings.backend {
        case .whisperCpp:
            guard let weights = model.files.whisperCpp else {
                throw TranscriptionEngineError.unsupportedBackend(model: model.displayName, backend: settings.backend)
            }
            backend = WhisperCppBackend(model: try WhisperModel(contentsOf: try existing(weights)))
        case .mlx:
            guard let weights = model.files.mlx else {
                throw TranscriptionEngineError.unsupportedBackend(model: model.displayName, backend: settings.backend)
            }
            backend = try WhisperMLXBackend(modelDirectory: try existing(weights))
        }

        let tokenizer = try WhisperTokenizer(contentsOf: try existing(model.files.tokenizer))
        let decoder = FallbackDecoder(windowDecoder: WindowDecoder(
            tokenizer: tokenizer, settings: model.decoding
        ))
        let pipelineSettings = TranscriptionPipeline.Settings(model: model, concurrentChunkCount: settings.concurrentChunkCount)
        return TranscriptionPipeline(
            vadModel: try WhisperVADModel(compiledModelAt: vadURL),
            segmentGenerator: SegmentGenerator(backend: backend, decoder: decoder),
            settings: pipelineSettings
        )
    }

    private static func existing(_ url: URL) throws -> URL {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw TranscriptionEngineError.missingModel(url)
        }
        return url
    }
}
