import AudioFeatures
import CoreML
import Foundation

public enum WhisperVADModelError: Error, Equatable {
    case missingOutput
}

/// TransWithAI's Whisper-VAD-EncDec-ASMR model running on Core ML.
///
/// Mirrors `WhisperVADOnnxWrapper.audio_forward` in the original: the audio is
/// cut into back-to-back 30 s windows without overlap, the last one zero-padded,
/// and each window yields 1500 sigmoid probabilities (one per 20 ms). Frames in
/// the padded tail are kept, as in the original.
public final class WhisperVADModel: @unchecked Sendable {
    // @unchecked: MLModel predictions are thread-safe and nothing else is mutated.
    private static let inputName = "input_features"
    private static let outputName = "logits"
    private static let melBandCount = 80

    private let model: MLModel
    private let spectrogram = LogMelSpectrogram(melBandCount: melBandCount)

    public init(compiledModelAt modelURL: URL, computeUnits: MLComputeUnits = .all) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = computeUnits
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
    }

    public func frameProbabilities(for samples: [Float]) throws -> [Float] {
        let windowLength = LogMelSpectrogram.windowSampleCount
        var probabilities: [Float] = []
        for windowStart in stride(from: 0, to: samples.count, by: windowLength) {
            let window = samples[windowStart..<min(windowStart + windowLength, samples.count)]
            probabilities += try windowProbabilities(for: window)
        }
        return probabilities
    }

    private func windowProbabilities(for window: ArraySlice<Float>) throws -> [Float] {
        let features = spectrogram.features(for: window)
        let input = MLShapedArray<Float>(scalars: features.values, shape: [1, features.melBandCount, features.frameCount])
        let output = try model.prediction(
            from: MLDictionaryFeatureProvider(dictionary: [Self.inputName: MLMultiArray(input)])
        )
        guard let logits = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw WhisperVADModelError.missingOutput
        }
        return MLShapedArray<Float>(logits).scalars.map { 1 / (1 + exp(-$0)) }
    }
}
