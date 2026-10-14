import Foundation
import SpeechDetection
import TranscriberCore
import TranscriptionPipeline
import WhisperCpp
import WhisperDecoding
import WhisperMLX

public enum TranscriptionEngineError: LocalizedError, Equatable {
    case missingModel(URL)

    public var errorDescription: String? {
        switch self {
        case .missingModel(let url): "Model not found: \(url.path)"
        }
    }
}

/// Builds pipelines on demand and keeps the most recent one loaded, since a
/// model takes seconds and gigabytes to load.
public actor TranscriptionEngine {
    private struct PipelineKey: Hashable {
        let settings: EngineSettings
        let task: TranscriptionTask
    }

    private var loaded: (key: PipelineKey, pipeline: TranscriptionPipeline)?

    public init() {}

    public func pipeline(for task: TranscriptionTask, settings: EngineSettings) throws -> TranscriptionPipeline {
        let key = PipelineKey(settings: settings, task: task)
        if let loaded, loaded.key == key {
            return loaded.pipeline
        }
        loaded = nil  // release the previous model before loading the next
        let pipeline = try Self.makePipeline(for: task, settings: settings)
        loaded = (key, pipeline)
        return pipeline
    }

    private static func makePipeline(for task: TranscriptionTask, settings: EngineSettings) throws -> TranscriptionPipeline {
        let models = settings.modelsDirectory
        let modelName = EngineSettings.modelName(for: task)
        let vadURL = try existing(models.appendingPathComponent("vad/whisper-vad-asmr.mlmodelc"))

        let backend: any WhisperBackend
        let tokenizerURL: URL
        switch settings.backend {
        case .whisperCpp:
            let modelURL = try existing(models.appendingPathComponent("whisper/\(modelName).bin"))
            tokenizerURL = try existing(models.appendingPathComponent("whisper/\(modelName).tokenizer.json"))
            backend = WhisperCppBackend(model: try WhisperModel(contentsOf: modelURL))
        case .mlx:
            let modelDirectory = try existing(models.appendingPathComponent("mlx/\(modelName)"))
            tokenizerURL = try existing(modelDirectory.appendingPathComponent("tokenizer.json"))
            backend = try WhisperMLXBackend(modelDirectory: modelDirectory)
        }

        let tokenizer = try WhisperTokenizer(contentsOf: tokenizerURL)
        let decoder = FallbackDecoder(windowDecoder: WindowDecoder(
            tokenizer: tokenizer, settings: ChickenRiceDefaults.decoding(task: task)
        ))
        var pipelineSettings = TranscriptionPipeline.Settings.chickenRice
        pipelineSettings.concurrentChunkCount = settings.concurrentChunkCount
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
