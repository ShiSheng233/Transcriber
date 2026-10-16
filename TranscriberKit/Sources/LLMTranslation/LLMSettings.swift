import Foundation

/// How subtitles are improved with a language model after transcription.
///
/// What the model does follows the speech model's `llm_mode`: Chinese output
/// is polished; Japanese output is translated into `targetLanguage`.
public struct LLMSettings: Hashable, Sendable, Codable {
    public var isEnabled: Bool
    /// Any OpenAI-compatible API, e.g. `https://openrouter.ai/api/v1`.
    public var baseURL: URL
    /// A model id as the server names it, e.g. "anthropic/claude-sonnet-5.5".
    public var model: String
    /// Language for translations, written as the model should read it ("简体中文", "English").
    public var targetLanguage: String
    /// One "source = target" pair per line; the model must use these renderings.
    public var glossary: String
    /// Translation only: keep the original line under the translation.
    public var keepsOriginalLine: Bool
    /// While translating Japanese, also fix what the speech model misheard;
    /// the corrected Japanese replaces the recognized lines (same request).
    public var proofreadsTranscript: Bool
    /// The LLM may remove lines that cannot be speech (video
    /// outros, subtitle credits, loops, text unrelated to the scene).
    public var removesHallucinations: Bool

    public init(
        isEnabled: Bool,
        baseURL: URL,
        model: String,
        targetLanguage: String,
        glossary: String,
        keepsOriginalLine: Bool,
        proofreadsTranscript: Bool = false,
        removesHallucinations: Bool = false
    ) {
        self.isEnabled = isEnabled
        self.baseURL = baseURL
        self.model = model
        self.targetLanguage = targetLanguage
        self.glossary = glossary
        self.keepsOriginalLine = keepsOriginalLine
        self.proofreadsTranscript = proofreadsTranscript
        self.removesHallucinations = removesHallucinations
    }

    public static let defaults = LLMSettings(
        isEnabled: false, baseURL: LLMProvider.openRouter.baseURL!, model: "", targetLanguage: "简体中文", glossary: "", keepsOriginalLine: false
    )

    public var provider: LLMProvider {
        LLMProvider.matching(baseURL)
    }

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

extension LLMSettings {
    /// Settings saved before a field existed decode with that field's default.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let defaults = LLMSettings.defaults
        isEnabled = try container.decodeIfPresent(Bool.self, forKey: .isEnabled) ?? defaults.isEnabled
        baseURL = try container.decodeIfPresent(URL.self, forKey: .baseURL) ?? defaults.baseURL
        model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
        targetLanguage = try container.decodeIfPresent(String.self, forKey: .targetLanguage) ?? defaults.targetLanguage
        glossary = try container.decodeIfPresent(String.self, forKey: .glossary) ?? defaults.glossary
        keepsOriginalLine = try container.decodeIfPresent(Bool.self, forKey: .keepsOriginalLine) ?? defaults.keepsOriginalLine
        proofreadsTranscript = try container.decodeIfPresent(Bool.self, forKey: .proofreadsTranscript) ?? defaults.proofreadsTranscript
        removesHallucinations = try container.decodeIfPresent(Bool.self, forKey: .removesHallucinations) ?? defaults.removesHallucinations
    }
}
