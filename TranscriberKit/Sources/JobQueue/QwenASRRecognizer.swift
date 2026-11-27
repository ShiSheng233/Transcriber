import Foundation
import MLX
import MLXAudioSTT
import TranscriberCore

/// Serializes access to the MLX model. The pipeline gives it one short VAD group at a time.
actor QwenASRRecognizer {
    private let model: Qwen3ASRModel
    private let language: String
    private let maximumTokenCount: Int

    private init(model: sending Qwen3ASRModel, settings: RecognitionModel.Qwen3ASR) {
        self.model = model
        language = settings.languageCode
        maximumTokenCount = settings.maximumGeneratedTokenCount
    }

    static func load(settings: RecognitionModel.Qwen3ASR) async throws -> QwenASRRecognizer {
        try Task.checkCancellation()
        let model = try await Qwen3ASRModel.fromModelDirectory(settings.directory)
        return QwenASRRecognizer(model: model, settings: settings)
    }

    func transcribe(_ samples: [Float]) throws -> String {
        try Task.checkCancellation()
        let output = model.generate(audio: MLXArray(samples), maxTokens: maximumTokenCount, language: language)
        try Task.checkCancellation()
        return output.text
    }
}
