import Foundation
import Testing
import AIHubCore
import AIHubSDK

private actor SDKTransport: HTTPTransport {
    let body: Data
    let status: Int
    let delay: Duration?
    var requests: [URLRequest] = []
    init(_ body: String, status: Int = 200, delay: Duration? = nil) {
        self.body = Data(body.utf8); self.status = status; self.delay = delay
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if let delay { try await Task.sleep(for: delay) }
        return (body, HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct SDKTextTests {
    static let chat = #"{"id":"chat_mock","object":"chat.completion","created":1,"model":"custom-model","choices":[{"index":0,"message":{"role":"assistant","content":"完成"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#
    static let responses = #"{"id":"resp_mock","created_at":1,"status":"completed","model":"custom-model","output":[{"type":"message","id":"msg_mock","status":"completed","role":"assistant","content":[{"type":"output_text","text":"完成","annotations":[]}]}],"usage":{"input_tokens":4,"output_tokens":2,"total_tokens":6}}"#
    static let anthropic = #"{"id":"msg_mock","type":"message","role":"assistant","model":"claude-sonnet-4-6","content":[{"type":"text","text":"完成"}],"stop_reason":"end_turn","stop_sequence":null,"usage":{"input_tokens":4,"output_tokens":2}}"#
    static let gemini = #"{"candidates":[{"index":0,"content":{"role":"model","parts":[{"text":"不应输出的思考","thought":true},{"text":"完成"}]},"finishReason":"STOP"}],"usageMetadata":{"promptTokenCount":4,"candidatesTokenCount":2,"totalTokenCount":6}}"#

    func provider(_ api: APIProtocol, channel: ChannelType? = nil, model: String = "custom-model") -> Provider {
        Provider(name: "SDK test", baseURL: "http://127.0.0.1:8899/\(api == .gemini ? "v1beta" : "v1")",
                 models: [AIModel(id: model, capability: .chat)], apiProtocol: api,
                 channelType: channel, textBackend: .swiftAI)
    }
    private func client(_ transport: SDKTransport) -> AIClient {
        AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
    }
    @Test(arguments: [APIProtocol.openAIChat, .openAIResponses, .anthropic, .gemini])
    func actualSDKSerializesFourProtocolsThroughBoundTransport(_ api: APIProtocol) async throws {
        let fixture: String
        switch api {
        case .openAIChat: fixture = Self.chat
        case .openAIResponses: fixture = Self.responses
        case .anthropic: fixture = Self.anthropic
        default: fixture = Self.gemini
        }
        let transport = SDKTransport(fixture)
        let model = api == .anthropic ? "claude-sonnet-4-6" : "custom-model"
        let provider = provider(api, model: model)
        #expect(try await client(transport).transform(provider: provider, key: "only-selected-key", model: model, text: "原文", instruction: "整理") == "完成")
        let requests = await transport.requests
        #expect(requests.count == 1)
        let request = try #require(requests.first)
        let expectedURL = try Endpoint(provider.baseURL, defaultVersion: api.defaultVersion).url(for: ProtocolAdapter.generationRoute(protocol: api, model: model))
        #expect(request.url == expectedURL)
        let keyHeader = api == .anthropic ? "x-api-key" : api == .gemini ? "x-goog-api-key" : "Authorization"
        #expect(request.value(forHTTPHeaderField: keyHeader) == (api == .anthropic || api == .gemini ? "only-selected-key" : "Bearer only-selected-key"))
        #expect(request.timeoutInterval <= 120)
        let body = try #require(request.httpBody)
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(String(decoding: body, as: UTF8.self).contains("原文"))
        #expect(!String(decoding: body, as: UTF8.self).contains("aihub-transport-injected"))
        #expect(json["tools"] == nil)
        if api == .openAIResponses { #expect(json["store"] as? Bool == false) }
    }
    @Test(arguments: [APIProtocol.anthropic, .gemini])
    func bearerCredentialsDoNotBecomeProviderAPIKeys(_ api: APIProtocol) async throws {
        var provider = provider(api, model: api == .anthropic ? "claude-sonnet-4-6" : "custom-model")
        provider.authentication = .bearer
        let key = try CredentialEnvelope(baseURL: provider.baseURL, authentication: .bearer, secret: "selected-bearer").encoded()
        let transport = SDKTransport(api == .anthropic ? Self.anthropic : Self.gemini)
        _ = try await client(transport).transform(provider: provider, key: key, model: provider.models[0].id, text: "原文", instruction: "整理")
        let request = try #require(await transport.requests.first)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer selected-bearer")
        #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == nil)
        #expect(request.value(forHTTPHeaderField: "x-api-key") == nil)
    }
    @Test func keylessCustomServiceDoesNotReadSDKEnvironment() async throws {
        var provider = provider(.openAIChat); provider.requiresAPIKey = false
        let transport = SDKTransport(Self.chat)
        _ = try await client(transport).transform(provider: provider, key: nil, model: "custom-model", text: "原文", instruction: "整理")
        #expect(await transport.requests.first?.value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test(arguments: [301, 400, 401, 403, 429, 500])
    func failuresAreSanitizedAndNeverRetried(_ status: Int) async {
        let transport = SDKTransport(#"{"error":{"message":"private-input selected-bearer https://private.example/validation"}}"#, status: status)
        do {
            _ = try await client(transport).transform(provider: provider(.openAIChat), key: "selected-bearer", model: "custom-model", text: "private-input", instruction: "整理")
            Issue.record("Expected error")
        } catch {
            #expect((error as? HubError)?.statusCode == status)
            #expect(!error.localizedDescription.contains("private-input"))
            #expect(!error.localizedDescription.contains("selected-bearer"))
            #expect(!error.localizedDescription.contains("private.example"))
        }
        #expect(await transport.requests.count == 1)
    }
    @Test func SDKResponseErrorsNeverExposeRawResponse() async {
        let transport = SDKTransport("private-input selected-bearer")
        do {
            _ = try await client(transport).transform(provider: provider(.openAIChat), key: "selected-bearer", model: "custom-model", text: "private-input", instruction: "整理")
            Issue.record("Expected error")
        } catch { #expect(!error.localizedDescription.contains("private-input") && !error.localizedDescription.contains("selected-bearer")) }
    }
    @Test func truncatedResponsesAreNotAccepted() async {
        let transport = SDKTransport(Self.chat.replacingOccurrences(of: "\"stop\"", with: "\"length\""))
        await #expect(throws: HubError.self) {
            try await client(transport).transform(provider: provider(.openAIChat), key: "fake", model: "custom-model", text: "原文", instruction: "整理")
        }
    }
    @Test func cancellationDoesNotFallbackOrRepeatRequest() async throws {
        let transport = SDKTransport(Self.chat, delay: .seconds(5))
        let task = Task { try await client(transport).transform(provider: provider(.openAIChat), key: "fake", model: "custom-model", text: "原文", instruction: "整理") }
        for _ in 0..<100 { if await transport.requests.count > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await transport.requests.count == 1)
    }
    @Test func malformedAuthorizationBoundaryFailsWithoutNetwork() async {
        let transport = SDKTransport(Self.chat)
        var request = URLRequest(url: URL(string: "https://other.example/wrong-route")!)
        request.httpMethod = "POST"
        await #expect(throws: HubError.self) {
            try await SwiftAITextBackend(transport: transport).generate(api: .openAIChat, model: "custom-model", text: "原文", instruction: "整理", authorizedRequest: request)
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func oversizedSDKResponseIsRejectedEvenByAnInjectedTransport() async {
        let transport = SDKTransport(String(repeating: "x", count: 4 * 1024 * 1024 + 1))
        await #expect(throws: HubError.self) {
            try await client(transport).transform(provider: provider(.openAIChat), key: "fake", model: "custom-model", text: "原文", instruction: "整理")
        }
        #expect(await transport.requests.count == 1)
    }

    @Test func CLIProxyUsesOnlyLocalAccessKeyAndRealModelID() async throws {
        let transport = SDKTransport(Self.chat)
        let provider = provider(.openAIChat, channel: .cliProxyAPI)
        _ = try await client(transport).transform(provider: provider, key: "local-proxy-key", model: "custom-model", text: "原文", instruction: "整理")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host == "127.0.0.1")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer local-proxy-key")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "custom-model")
    }
}
