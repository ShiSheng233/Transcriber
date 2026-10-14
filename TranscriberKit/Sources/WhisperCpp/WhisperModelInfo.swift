/// Architecture facts read from a loaded ggml model.
public struct WhisperModelInfo: Sendable, Equatable {
    /// whisper.cpp's size label, e.g. "large".
    public var typeName: String
    /// 80 for large-v2 (ChickenRice), 128 for large-v3 (whisper-ja-1.5B).
    public var melBandCount: Int
    public var vocabularySize: Int
    public var encoderLayerCount: Int
    public var decoderLayerCount: Int
    public var isMultilingual: Bool
}
