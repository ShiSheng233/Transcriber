import Foundation

/// A speech model the app can run, as described by its `model.json`.
///
/// The configuration selects the recognizer, decoding and segmentation settings,
/// and the language-model step for the transcript.
public struct RecognitionModel: Hashable, Sendable, Identifiable {
    public enum LLMMode: String, Hashable, Sendable, Codable {
        /// Improve the model's own output language (e.g. ChickenRice's Chinese).
        case polish
        /// Translate the output into the user's target language.
        case translate
    }

    /// Where whisper.cpp runs the audio encoder for this model.
    public enum WhisperCppEncoder: String, Hashable, Sendable, Decodable {
        /// The Metal GPU, like the decoder.
        case metal
        /// Core ML (the Neural Engine where it can), from
        /// `ggml-encoder.mlmodelc` next to the weights (`make coreml-encoders`);
        /// Metal when that file is missing.
        case coreML = "coreml"
    }

    public struct Files: Hashable, Sendable {
        public let tokenizer: URL
        /// ggml weights for whisper.cpp, if converted.
        public let whisperCpp: URL?
        /// mlx-whisper model directory, if converted.
        public let mlx: URL?
    }

    public enum Decoding: Hashable, Sendable {
        case whisper(DecodingSettings)
        case qwen3ASR(Qwen3ASR)
    }

    public struct Qwen3ASR: Hashable, Sendable {
        public let directory: URL
        /// Language of the transcript requested in the Qwen prompt.
        public let languageCode: String
        public let maximumGeneratedTokenCount: Int

        public var firstMissingFile: URL? {
            for name in ["model.safetensors", "config.json", "tokenizer.json", "tokenizer_config.json"] {
                let file = directory.appendingPathComponent(name)
                if !FileManager.default.fileExists(atPath: file.path) { return file }
            }
            return nil
        }
    }

    public let id: String
    public let displayName: String
    /// One line for menus and settings.
    public let summary: String
    public let source: String?
    public let license: String?
    public let llmMode: LLMMode
    public let directory: URL
    public let files: Files
    public let whisperCppEncoder: WhisperCppEncoder
    public let decoding: Decoding

    public var qwen3ASR: Qwen3ASR? {
        guard case .qwen3ASR(let settings) = decoding else { return nil }
        return settings
    }

    /// The VAD model's name: `vad/<name>.mlmodelc` in the models folder.
    public let vadModelName: String
    public let vad: VADSettings
    public let chunking: ChunkingSettings
    public let segmentation: SegmentationSettings
    public let merge: MergeSettings
    public let cleanup: TextCleanupSettings
}
