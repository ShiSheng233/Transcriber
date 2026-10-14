import ArgumentParser
import Foundation
import LLMTranslation

/// Where the LLM step sends requests. The key comes from the environment
/// (LLM_API_KEY, else OPENROUTER_API_KEY or OPENAI_API_KEY) so it never
/// ends up in shell history.
struct LLMEndpointOptions: ParsableArguments {
    @Option(help: "OpenAI-compatible API base URL (OpenRouter, OpenAI, DeepSeek, Ollama, LM Studio, …).")
    var llmBaseURL: String = LLMProvider.openRouter.baseURL!.absoluteString

    func makeClient() throws -> ChatCompletionsClient {
        guard let url = URL(string: llmBaseURL), url.scheme != nil else {
            throw ValidationError("--llm-base-url must be a URL such as http://localhost:11434/v1")
        }
        let environment = ProcessInfo.processInfo.environment
        let apiKey = ["LLM_API_KEY", "OPENROUTER_API_KEY", "OPENAI_API_KEY"].lazy.compactMap { environment[$0] }.first { !$0.isEmpty } ?? ""
        return ChatCompletionsClient(baseURL: url, apiKey: apiKey)
    }
}
