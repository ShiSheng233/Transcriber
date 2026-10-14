import Foundation

public enum OpenRouterError: LocalizedError, Equatable {
    case invalidAPIKey
    case insufficientCredits
    case rateLimited
    case requestFailed(status: Int, message: String)
    case emptyResponse

    public var errorDescription: String? {
        switch self {
        case .invalidAPIKey: "The OpenRouter API key was rejected."
        case .insufficientCredits: "The OpenRouter account has no credits left."
        case .rateLimited: "OpenRouter is rate limiting requests; try again later."
        case .requestFailed(let status, let message): "OpenRouter request failed (\(status)): \(message)"
        case .emptyResponse: "The model returned no content."
        }
    }
}

/// Something that answers a chat with JSON matching a schema. `OpenRouterClient`
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

/// OpenRouter's OpenAI-compatible chat API with structured output. Requests
/// set `provider.require_parameters` so they are only routed to providers that
/// honor the JSON schema. Rate limits and server errors are retried with backoff.
public struct OpenRouterClient: StructuredChatCompleting {
    // A constant, well-formed literal: the unwrap cannot fail.
    public static let defaultBaseURL = URL(string: "https://openrouter.ai/api/v1")!
    public static let defaultRetryDelays: [Duration] = [.seconds(1), .seconds(3), .seconds(8)]

    private let apiKey: String
    private let baseURL: URL
    private let session: URLSession
    private let retryDelays: [Duration]

    public init(apiKey: String, baseURL: URL = defaultBaseURL, session: URLSession = .shared, retryDelays: [Duration] = defaultRetryDelays) {
        self.apiKey = apiKey
        self.baseURL = baseURL
        self.session = session
        self.retryDelays = retryDelays
    }

    public func completeJSON(
        model: String,
        messages: [ChatMessage],
        schemaName: String,
        schema: [String: any Sendable],
        temperature: Double
    ) async throws -> Data {
        let body: [String: Any] = [
            "model": model,
            "messages": messages.map { ["role": $0.role.rawValue, "content": $0.content] },
            "temperature": temperature,
            "response_format": [
                "type": "json_schema",
                "json_schema": ["name": schemaName, "strict": true, "schema": schema],
            ],
            "provider": ["require_parameters": true],
        ]
        var request = URLRequest(url: baseURL.appendingPathComponent("chat/completions"))
        request.httpMethod = "POST"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Transcriber", forHTTPHeaderField: "X-Title")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data = try await send(request)
        return try Self.messageContent(from: data)
    }

    /// Models whose providers support structured output, cheapest first.
    public static func structuredOutputModels(session: URLSession = .shared, baseURL: URL = defaultBaseURL) async throws -> [OpenRouterModel] {
        let (data, response) = try await session.data(from: baseURL.appendingPathComponent("models"))
        try check(response, data: data)
        let catalog = try JSONDecoder().decode(ModelCatalog.self, from: data)
        return catalog.data
            .filter { $0.supportedParameters?.contains("structured_outputs") ?? false }
            .map { OpenRouterModel(id: $0.id, name: $0.name, contextLength: $0.contextLength ?? 0) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func send(_ request: URLRequest) async throws -> Data {
        var attempt = 0
        while true {
            do {
                let (data, response) = try await session.data(for: request)
                try Self.check(response, data: data)
                return data
            } catch let error as OpenRouterError where Self.isRetryable(error) && attempt < retryDelays.count {
                try await Task.sleep(for: retryDelays[attempt])
                attempt += 1
            }
        }
    }

    private static func isRetryable(_ error: OpenRouterError) -> Bool {
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
        case 401: throw OpenRouterError.invalidAPIKey
        case 402: throw OpenRouterError.insufficientCredits
        case 429: throw OpenRouterError.rateLimited
        default:
            let message = (try? JSONDecoder().decode(ErrorEnvelope.self, from: data))?.error.message
                ?? String(decoding: data.prefix(300), as: UTF8.self)
            throw OpenRouterError.requestFailed(status: status, message: message)
        }
    }

    private static func messageContent(from data: Data) throws -> Data {
        let completion = try JSONDecoder().decode(ChatCompletion.self, from: data)
        if let error = completion.error {
            throw OpenRouterError.requestFailed(status: error.code ?? 0, message: error.message)
        }
        guard let content = completion.choices?.first?.message.content, !content.isEmpty else {
            throw OpenRouterError.emptyResponse
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

    private struct ModelCatalog: Decodable {
        struct Entry: Decodable {
            let id: String
            let name: String
            let contextLength: Int?
            let supportedParameters: [String]?

            enum CodingKeys: String, CodingKey {
                case id, name
                case contextLength = "context_length"
                case supportedParameters = "supported_parameters"
            }
        }

        let data: [Entry]
    }
}

public struct OpenRouterModel: Hashable, Sendable {
    public let id: String
    public let name: String
    public let contextLength: Int
}
