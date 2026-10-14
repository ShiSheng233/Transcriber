import TranscriberCore

/// Finds speech in audio: VAD model probabilities, then segmentation.
public struct VoiceActivityDetector: Sendable {
    private let model: WhisperVADModel
    public let settings: VADSettings

    public init(model: WhisperVADModel, settings: VADSettings = ChickenRiceDefaults.vad) {
        self.model = model
        self.settings = settings
    }

    /// Spans in sample positions of `samples`, which must be 16 kHz mono.
    public func speechSpans(in samples: [Float]) throws -> [SpeechSpan] {
        let probabilities = try model.frameProbabilities(for: samples)
        return SpeechSegmenter.speechSpans(in: probabilities, settings: settings)
    }
}
