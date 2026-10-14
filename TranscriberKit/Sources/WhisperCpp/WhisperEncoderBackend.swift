/// Where the Whisper audio encoder runs. The decoder always runs on Metal.
public enum WhisperEncoderBackend: Sendable, Equatable {
    /// Default: the encoder runs on the Metal GPU.
    case metal
    /// The encoder runs through Core ML (Neural Engine where possible), using
    /// the `<model>-encoder.mlmodelc` bundle next to the ggml file.
    case coreML
}
