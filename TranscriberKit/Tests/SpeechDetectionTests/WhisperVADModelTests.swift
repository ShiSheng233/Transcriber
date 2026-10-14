import CoreML
import Foundation
import Testing
@testable import SpeechDetection

/// Compares our log-mel + Core ML VAD with the original log-mel + ONNX Runtime
/// (fixture from Tools/parity/make_vad_fixture.py). Needs the converted model
/// from `make vad-model`, so it is skipped when Models/ is empty.
struct WhisperVADModelTests {
    private static let packageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // SpeechDetectionTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // TranscriberKit
        .deletingLastPathComponent()  // repository root
        .appendingPathComponent("Models/vad/whisper-vad-asmr.mlpackage")

    /// Same bound the conversion script enforces for Core ML vs ONNX.
    private static let maximumProbabilityError: Float = 0.01

    @Test(.enabled(if: FileManager.default.fileExists(atPath: packageURL.path)))
    func matchesOnnxRuntimeProbabilities() async throws {
        let compiledURL = try await MLModel.compileModel(at: Self.packageURL)
        defer { try? FileManager.default.removeItem(at: compiledURL) }
        let model = try WhisperVADModel(compiledModelAt: compiledURL)

        let samples = try Self.loadFloats("speech-samples")
        let expected = try Self.loadFloats("speech-probabilities")
        let probabilities = try model.frameProbabilities(for: samples)

        #expect(probabilities.count == expected.count)
        let largestError = zip(probabilities, expected).map { abs($0 - $1) }.max() ?? .infinity
        #expect(largestError < Self.maximumProbabilityError, "largest error \(largestError)")
    }

    private static func loadFloats(_ name: String) throws -> [Float] {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "f32", subdirectory: "Fixtures"))
        return try Data(contentsOf: url).withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
