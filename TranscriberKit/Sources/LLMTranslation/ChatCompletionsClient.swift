import Foundation
import Synchronization

public enum LLMServiceError: LocalizedError, Equatable {
    case invalidAPIKey
    case insufficientCredits
    case rateLimited
    case requestFailed(status: Int, message: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: "The API key was rejected."
        case .insufficientCredits: "The account has no credits left."
        case .rateLimited: "The service is rate limiting requests; try again later."
        case .requestFailed(let status, let message): "The request failed (\(status)): \(message)"
        case .emptyResponse: "The model returned no content."
        }
    }
}

/// Something that answers a chat with JSON matching a schema. `ChatCompletionsClient`
/// in the app, a stub in tests.
public protocol StructuredChatCompleting: Sendable {
    func completeJSON(model: String, messages: [ChatMessage], schemaName: String, schema: [String: any Sendable], temperature: Double) async throws -> Data
}

public struct ChatMessage: Sendable, Equatable {
    public enum Role: String, Sendable {
        case system, user, assistant
    }

    public let role: Role
    public let content: String

    public init(role: Role, content: String) {
        self.role = role
        self.content = content
    }
}

/// Any OpenAI-compatible chat API (OpenRouter, OpenAI, DeepSeek, Ollama,
/// LM Studio, …) asked for JSON that matches a schema.
///
/// Not every server supports strict JSON schemas, so the request steps down
/// when a server rejects one: `json_schema`, then `json_object` with the
/// schema in the prompt, then the prompt alone. The step that worked is
/// remembered. On OpenRouter, requests set `provider.require_parameters` so
/// they only reach providers that honor the schema. Rate limits and server
/// errors are retried with backoff.
public final class ChatCompletionsClient: StructuredChatCompleting {
    public static let defaultRetryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]

    enum OutputMode: Int, CaseIterable {
        case jsonSchema
        case jsonObject
        case promptOnly
    }

    private let baseURL: URL
    private let apiKey: String
    private let session: URLSession
    private let retryDelays: [Duration]
    private let workingMode = Mutex(OutputMode.jsonSchema)

    public init(baseURL: URL, apiKey: String, session: URLSession = .shared, retryDelays: [Duration] = defaultRetryDelays) {
        self.baseURL = baseURL
        self.apiKey = apiKey
        self.session = session
        self.retryDelays = retryDelays
    }

    var isOpenRouter: Bool {
        baseURL.host()?.hasSuffix("openrouter.ai") == true
    }

    public func completeJSON(
        model: String,
        messages: [ChatMessage],
        schemaName: String,
        schema: [String: any Sendable],
        temperature: Double
    ) async throws -> Data {
        var mode = workingMode.withLock { $0 }
        while true {
            do {
                let request = try makeRequest(model: model, messages: messages, schemaName: schemaName, schema: schema, temperature: temperature, mode: mode)
                let content = try Self.messageContent(from: try await send(request))
                workingMode.withLock { $0 = mode }
                return mode == .jsonSchema ? content : Self.strippingCodeFence(content)
            } catch LLMServiceError.requestFailed(let status, _) where [400, 422].contains(status) {
                // Most likely the output format: step down and try again.
                guard let next = OutputMode(rawValue: mode.rawValue + 1) else {
                    throw LLMServiceError.requestFailed(status: status, message: "the server rejected every JSON output mode")
                }
                mode = next
            }
        }
    }

    /// The models the server lists. On OpenRouter, only interactive models
    /// whose providers support structured output (no ":batch" variants).
    public func models() async throws -> [LLMModel] {
        var request = URLRequest(url: baseURL.appendingPathComponent("models"))
        authorize(&request)
        let data = try await send(request)
        let list = try JSONDecoder().decode(ModelList.self, from: data)
        return list.data
            .filter { !isOpenRouter || ($0.supportedParameters?.contains("structured_outputs") ?? false) }
            .filter { !$0.id.hasSuffix(":batch") }
            .map { LLMModel(id: $0.id, name: $0.name ?? $0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func makeRequest(
        model: String,
        messages: [ChatMessage],
        schemaName: String,
        schema: [String: any Sendable],
        temperature: Double,
        mode: OutputMode
    ) throws -> URLRequest {
        var messages = messages
        if mode != .jsonSchema {
            let schemaText = String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
            messages.insert(ChatMessage(role: .system, content: "Reply with only a JSON object (no prose, no code fence) matching this JSON schema:\n\(schemaText)"), at: messages.firstIndex { $0.role != .system } ?? messages.endIndex)
        }
        var body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "temperature": temperature,
        ]
        switch mode {
        case .jsonSchema:
            body["response_format"] = ["type": "json_schema", "json_schema": ["name": schemaName, "strict": true, "schema": schema]]
            if isOpenRouter {
                body["provider"] = ["require_parameters": true]
            }
        case .jsonObject:
            body["response_format"] = ["type": "json_object"]
        case .promptOnly:
            break
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        authorize(&request)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if isOpenRouter {
            request.setValue("Transcriber", forHTTPHeaderField: "X-Title")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return request
    }

    private func authorize(_ request: inout URLRequest) {
        if !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }
    }

    /// Models without a JSON mode sometimes wrap the object in ```json … ```.
    static func strippingCodeFence(_ content: Data) -> Data {
        let text = String(decoding: content, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```"), let start = text.firstIndex(of: "\n"), let end = text.range(of: "```", options: .backwards), end.lowerBound > start else {
            return Data(text.utf8)
        }
        return Data(text[text.index(after: start)..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines).utf8)
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                try Self.check(response, data: data)
                return data
            } catch let error as LLMServiceError where Self.isRetryable(error) && attempt < retryDelays.count {
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    private static func isRetryable(_ error: LLMServiceError) -> Bool {
        switch error {
        case .rateLimited: true
        case .requestFailed(let status, _): status >= 500
        default: false
        }
    }

    private static func check(_ response: URLResponse, data: Data) throws {
        guard let status = (response as? HTTPURLResponse)?.statusCode, !(200..<300).contains(status) else {
            return
        }
        switch status {
        case 401: throw LLMServiceError.invalidAPIKey
        case 402: throw LLMServiceError.insufficientCredits
        case 429: throw LLMServiceError.rateLimited
        default:
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw LLMServiceError.requestFailed(status: status, message: message)
        }
    }

    private static func messageContent(from data: Data) throws -> Data {
        let completion = try JSONDecoder().decode(ChatCompletion.self, from: data)
        if let error = completion.error {
            throw LLMServiceError.requestFailed(status: error.code ?? 0, message: error.message)
        }
        guard let content = completion.choices?.first?.message.content, !content.isEmpty else {
            throw LLMServiceError.emptyResponse
        }
        return Data(content.utf8)
    }

    private struct ChatCompletion: Decodable {
        struct Choice: Decodable {
            struct Message: Decodable {
                let content: String?
            }

            let message: Message
        }

        let choices: [Choice]?
        let error: ErrorBody?
    }

    private struct ErrorEnvelope: Decodable {
        let error: ErrorBody
    }

    private struct ErrorBody: Decodable {
        let message: String
        let code: Int?
    }

    private struct ModelList: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String?
            let supportedParameters: [String]?

            enum CodingKeys: String, CodingKey {
                case id, name
                case supportedParameters = "supported_parameters"
            }
        }

        let data: [Entry]
    }
}

public struct LLMModel: Hashable, Sendable {
    public let id: String
    /// The server's display name, or the id.
    public let name: String
}
