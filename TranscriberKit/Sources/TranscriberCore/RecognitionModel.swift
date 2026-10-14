import Foundation

/// A speech model the app can run, as described by its `model.json`.
///
/// Users pick a model, not a Whisper task: the configuration says which
/// language and task tokens it needs, how to decode, segment and post-process,
/// and what the language-model step should do with its output.
public struct RecognitionModel: Hashable, Sendable, Identifiable {
    public enum LLMMode: String, Hashable, Sendable, Codable {
        /// Improve the model's own output language (e.g. ChickenRice's Chinese).
        case polish
        /// Translate the output into the user's target language.
        case translate
    }

    public struct Files: Hashable, Sendable {
        public let tokenizer: URL
        /// ggml weights for whisper.cpp, if converted.
        public let whisperCpp: URL?
        /// mlx-whisper model directory, if converted.
        public let mlx: URL?
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
    public let decoding: DecodingSettings
    /// The VAD model's name: `vad/<name>.mlmodelc` in the models folder.
    public let vadModelName: String
    public let vad: VADSettings
    public let chunking: ChunkingSettings
    public let merge: MergeSettings
}
