/// A Whisper log-mel spectrogram, stored mel band major: `values[band * frameCount + frame]`.
///
/// This is the layout of the `[1, melBandCount, frameCount]` model input.
public struct LogMelFeatures: Sendable, Equatable {
    public let melBandCount: Int
    public let frameCount: Int
    public let values: [Float]

    public init(melBandCount: Int, frameCount: Int, values: [Float]) {
        precondition(values.count == melBandCount * frameCount, "values do not match the feature shape")
        self.melBandCount = melBandCount
        self.frameCount = frameCount
        self.values = values
    }

    public subscript(band: Int, frame: Int) -> Float {
        values[band * frameCount + frame]
    }
}
