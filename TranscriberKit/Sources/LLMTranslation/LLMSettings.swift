import Foundation

/// How subtitles are improved with a language model after transcription.
///
/// What the model does follows the transcription task: ChickenRice's Chinese
/// output is polished; whisper-ja's Japanese output is translated into
/// `targetLanguage`.
public struct LLMSettings: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    /// An OpenRouter model id, e.g. "anthropic/claude-sonnet-5.5".
    public var model: String
    /// Language for translations, written as the model should read it ("简体中文", "English").
    public var targetLanguage: String
    /// One "source = target" pair per line; the model must use these renderings.
    public var glossary: String
    /// Translation only: keep the original line under the translation.
    public var keepsOriginalLine: Bool

    public init(isEnabled: Bool, model: String, targetLanguage: String, glossary: String, keepsOriginalLine: Bool) {
        self.isEnabled = isEnabled
        self.model = model
        self.targetLanguage = targetLanguage
        self.glossary = glossary
        self.keepsOriginalLine = keepsOriginalLine
    }

    public static let defaults = LLMSettings(
        isEnabled: false, model: "", targetLanguage: "简体中文", glossary: "", keepsOriginalLine: false
    )

    /// Glossary lines parsed into pairs; malformed lines are ignored.
    public var glossaryEntries: [(source: String, target: String)] {
        glossary.split(whereSeparator: \.isNewline).compactMap { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                return nil
            }
            return (parts[0], parts[1])
        }
    }
}
