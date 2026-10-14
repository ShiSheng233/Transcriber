/// Which Whisper task token the prompt carries.
public enum TranscriptionTask: String, Hashable, Sendable, Codable {
    /// `<|translate|>`. ChickenRice was fine-tuned so that this outputs Chinese.
    case translate
    /// `<|transcribe|>`: text in the spoken language.
    case transcribe
}
