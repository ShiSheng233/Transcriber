import Foundation
import Synchronization
import Testing
@testable import LLMTranslation

/// Serves canned HTTP responses in order and records requests.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: String
        var contentType = "application/json"
    }

    static let state = Mutex<(responses: [Response], requests: [URLRequest])>(([], []))

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var recorded = request
        if let stream = request.httpBodyStream {
            stream.open()
            var body = Data()
            var buffer = [UInt8](repeating: 0, count: 4_096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(buffer, count: count)
            }
            stream.close()
            recorded.httpBody = body
        }
        let response = Self.state.withLock { state -> Response in
            state.requests.append(recorded)
            return state.responses.isEmpty ? Response(status: 500, body: "{}") : state.responses.removeFirst()
        }
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: ["Content-Type": response.contentType])!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct ChatCompletionsClientTests {
    private func client(
        _ responses: [MockURLProtocol.Response],
        baseURL: URL = LLMProvider.openRouter.baseURL!,
        apiKey: String = "sk-test"
    ) -> ChatCompletionsClient {
        MockURLProtocol.state.withLock { $0 = (responses, []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return ChatCompletionsClient(baseURL: baseURL, apiKey: apiKey, session: URLSession(configuration: configuration), retryDelays: [.zero, .zero])
    }

    private func requestBodies() throws -> [[String: Any]] {
        try MockURLProtocol.state.withLock { $0.requests }.map {
            try #require(try JSONSerialization.jsonObject(with: $0.httpBody ?? Data()) as? [String: Any])
        }
    }

    private func complete(_ client: ChatCompletionsClient) async throws -> Data {
        try await client.completeJSON(
            model: "test/model",
            messages: [ChatMessage(role: .user, content: "hi")],
            schemaName: SubtitlePrompt.schemaName,
            schema: SubtitlePrompt.schema(),
            temperature: 0.3
        )
    }

    @Test func sendsStructuredOutputRequestAndReturnsContent() async throws {
        let content = #"{\"lines\":[{\"id\":0,\"text\":\"你好\"}]}"#
        let client = client([.init(status: 200, body: #"{"choices":[{"message":{"content":"\#(content)"}}]}"#)])

        let data = try await complete(client)

        #expect(String(decoding: data, as: UTF8.self) == #"{"lines":[{"id":0,"text":"你好"}]}"#)
        let request = try #require(MockURLProtocol.state.withLock { $0.requests.first })
        #expect(request.url?.absoluteString == "https://openrouter.ai/api/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer sk-test")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: Any])
        let format = try #require(body["response_format"] as? [String: Any])
        let schema = try #require(format["json_schema"] as? [String: Any])
        #expect(format["type"] as? String == "json_schema")
        #expect(schema["strict"] as? Bool == true)
        #expect((body["provider"] as? [String: Any])?["require_parameters"] as? Bool == true)
    }

    @Test func assemblesAStreamedReply() async throws {
        let stream = [
            #"data: {"choices":[{"delta":{"role":"assistant"}}]}"#,
            ": keep-alive",
            #"data: {"choices":[{"delta":{"content":"{\"lines\":"}}]}"#,
            #"data: {"choices":[{"delta":{"content":"[]}"}}]}"#,
            "data: [DONE]",
        ].joined(separator: "\n\n")
        let client = client([.init(status: 200, body: stream, contentType: "text/event-stream")])

        #expect(String(decoding: try await complete(client), as: UTF8.self) == #"{"lines":[]}"#)
        let body = try #require(try requestBodies().first)
        #expect(body["stream"] as? Bool == true)
    }

    @Test func reportsAnErrorSentInsideTheStream() async throws {
        let stream = #"data: {"error":{"message":"upstream overloaded","code":503}}"# + "\n\n"
        await #expect(throws: LLMServiceError.self) {
            try await complete(client([.init(status: 200, body: stream, contentType: "text/event-stream")]))
        }
    }

    @Test func retriesRateLimitsThenSucceeds() async throws {
        let client = client([
            .init(status: 429, body: #"{"error":{"message":"slow down"}}"#),
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{\"lines\":[]}"}}]}"#),
        ])
        _ = try await complete(client)
        #expect(MockURLProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test func mapsAuthenticationAndCreditErrors() async throws {
        await #expect(throws: LLMServiceError.invalidAPIKey) {
            try await complete(client([.init(status: 401, body: #"{"error":{"message":"bad key"}}"#)]))
        }
        await #expect(throws: LLMServiceError.insufficientCredits) {
            try await complete(client([.init(status: 402, body: #"{"error":{"message":"no credits"}}"#)]))
        }
    }

    @Test func reportsServerErrorMessages() async throws {
        await #expect(throws: LLMServiceError.requestFailed(status: 404, message: "no such model")) {
            try await complete(client([.init(status: 404, body: #"{"error":{"message":"no such model","code":404}}"#)]))
        }
    }

    @Test func stepsDownWhenTheServerRejectsJSONSchemas() async throws {
        let ok = #"{"choices":[{"message":{"content":"```json\n{\"lines\":[]}\n```"}}]}"#
        let client = client([
            .init(status: 400, body: #"{"error":{"message":"response_format json_schema not supported"}}"#),
            .init(status: 400, body: #"{"error":{"message":"json_object not supported"}}"#),
            .init(status: 200, body: ok),
            .init(status: 200, body: ok),
        ], baseURL: LLMProvider.ollama.baseURL!, apiKey: "")

        #expect(String(decoding: try await complete(client), as: UTF8.self) == #"{"lines":[]}"#)
        _ = try await complete(client)  // remembers the mode that worked

        let bodies = try requestBodies()
        #expect(bodies.count == 4)
        #expect((bodies[0]["response_format"] as? [String: Any])?["type"] as? String == "json_schema")
        #expect((bodies[1]["response_format"] as? [String: Any])?["type"] as? String == "json_object")
        #expect(bodies[2]["response_format"] == nil && bodies[3]["response_format"] == nil)
        // The schema moves into the prompt; no OpenRouter-only fields elsewhere.
        #expect((bodies[2]["messages"] as? [[String: Any]])?.contains { ($0["content"] as? String)?.contains("JSON schema") == true } == true)
        #expect(bodies.allSatisfy { $0["provider"] == nil })
        let request = try #require(MockURLProtocol.state.withLock { $0.requests.first })
        #expect(request.url?.absoluteString == "http://localhost:11434/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "Authorization") == nil)
    }

    @Test func listsModelsAndFiltersOpenRouterToStructuredOutput() async throws {
        let openRouter = client([.init(status: 200, body: #"{"data":[{"id":"a/x","name":"X","supported_parameters":["structured_outputs"]},{"id":"b/y","name":"Y","supported_parameters":[]}]}"#)])
        #expect(try await openRouter.models().map(\.id) == ["a/x"])

        let local = client([.init(status: 200, body: #"{"object":"list","data":[{"id":"qwen3:8b","object":"model"}]}"#)], baseURL: LLMProvider.ollama.baseURL!, apiKey: "")
        #expect(try await local.models() == [LLMModel(id: "qwen3:8b", name: "qwen3:8b")])
    }
}
