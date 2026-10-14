import Foundation
import Synchronization
import Testing
@testable import LLMTranslation

/// Serves canned HTTP responses in order and records requests.
final class MockURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let body: String
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
        let http = HTTPURLResponse(url: request.url!, statusCode: response.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: http, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(response.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite(.serialized)
struct OpenRouterClientTests {
    private func client(_ responses: [MockURLProtocol.Response]) -> OpenRouterClient {
        MockURLProtocol.state.withLock { $0 = (responses, []) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return OpenRouterClient(apiKey: "sk-test", session: URLSession(configuration: configuration), retryDelays: [.zero, .zero])
    }

    private func complete(_ client: OpenRouterClient) async throws -> Data {
        try await client.completeJSON(
            model: "test/model",
            messages: [ChatMessage(role: .user, content: "hi")],
            schemaName: SubtitlePrompt.schemaName,
            schema: SubtitlePrompt.schema,
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

    @Test func retriesRateLimitsThenSucceeds() async throws {
        let client = client([
            .init(status: 429, body: #"{"error":{"message":"slow down"}}"#),
            .init(status: 200, body: #"{"choices":[{"message":{"content":"{\"lines\":[]}"}}]}"#),
        ])
        _ = try await complete(client)
        #expect(MockURLProtocol.state.withLock { $0.requests.count } == 2)
    }

    @Test func mapsAuthenticationAndCreditErrors() async throws {
        await #expect(throws: OpenRouterError.invalidAPIKey) {
            try await complete(client([.init(status: 401, body: #"{"error":{"message":"bad key"}}"#)]))
        }
        await #expect(throws: OpenRouterError.insufficientCredits) {
            try await complete(client([.init(status: 402, body: #"{"error":{"message":"no credits"}}"#)]))
        }
    }

    @Test func reportsProviderErrorMessages() async throws {
        await #expect(throws: OpenRouterError.requestFailed(status: 400, message: "schema not supported")) {
            try await complete(client([.init(status: 400, body: #"{"error":{"message":"schema not supported","code":400}}"#)]))
        }
    }
}
