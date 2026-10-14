import Foundation

/// Well-known OpenAI-compatible services, to fill in the base URL. Any other
/// server that speaks `/chat/completions` works as `.custom`.
public enum LLMProvider: String, CaseIterable, Hashable, Sendable, Codable {
    case openRouter
    case openAI
    case deepSeek
    case ollama
    case lmStudio
    case custom

    public var displayName: String {
        switch self {
        case .openRouter: "OpenRouter"
        case .openAI: "OpenAI"
        case .deepSeek: "DeepSeek"
        case .ollama: "Ollama"
        case .lmStudio: "LM Studio"
        case .custom: "Custom"
        }
    }

    /// `nil` for `.custom`. Constant, well-formed literals: the unwraps cannot fail.
    public var baseURL: URL? {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/api/v1")!
        case .openAI: URL(string: "https://api.openai.com/v1")!
        case .deepSeek: URL(string: "https://api.deepseek.com/v1")!
        case .ollama: URL(string: "http://localhost:11434/v1")!
        case .lmStudio: URL(string: "http://localhost:1234/v1")!
        case .custom: nil
        }
    }

    /// Local servers run without a key.
    public var needsAPIKey: Bool {
        switch self {
        case .ollama, .lmStudio: false
        case .openRouter, .openAI, .deepSeek, .custom: true
        }
    }

    /// Where to get a key, if the service has a page for it.
    public var keysPage: URL? {
        switch self {
        case .openRouter: URL(string: "https://openrouter.ai/settings/keys")!
        case .openAI: URL(string: "https://platform.openai.com/api-keys")!
        case .deepSeek: URL(string: "https://platform.deepseek.com/api_keys")!
        case .ollama, .lmStudio, .custom: nil
        }
    }

    /// The preset whose base URL this is, or `.custom`.
    public static func matching(_ url: URL) -> LLMProvider {
        allCases.first { $0.baseURL == url } ?? .custom
    }
}
