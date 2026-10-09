import Foundation
import Testing
import AIHubCore
import AIHubSDK

private actor RoutingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = request.url?.path.hasSuffix("responses") == true ? SDKTextTests.responses : SDKTextTests.chat
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
struct PerModelRoutingTests {
    @Test func oneConnectionCanUseChatAndResponsesWithoutMutatingCredentialBinding() async throws {
        let transport = RoutingTransport()
        let chat = AIModel(id: "gpt-chat")
        let responses = ModelCatalog.model(id: "gpt-responses", entry: ["supported_endpoints": ["responses"]])
        let provider = Provider(name: "SDK", baseURL: "http://127.0.0.1:8000/v1", models: [chat, responses], textBackend: .swiftAI)
        let client = AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
        #expect(try await client.transform(provider: provider, key: "local-test-key", model: chat.id, text: "原文", instruction: "整理") == "完成")
        #expect(try await client.transform(provider: provider, key: "local-test-key", model: responses.id, text: "原文", instruction: "整理") == "完成")
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/v1/chat/completions", "/v1/responses"])
        #expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == "Bearer local-test-key" })
        #expect(provider.apiProtocol == .automatic && provider.models[0].metadata.bindings.isEmpty)
    }
    @Test func perModelRestrictionsDoNotFallbackToAnotherProtocol() async throws {
        let transport = RoutingTransport(status: 429)
        let model = ModelCatalog.model(id: "gpt-responses", entry: ["supported_endpoints": ["responses"]])
        let provider = Provider(name: "SDK", baseURL: "http://127.0.0.1:8000/v1", models: [model], textBackend: .swiftAI)
        let client = AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
        await #expect(throws: HubError.self) { try await client.transform(provider: provider, key: "fake", model: model.id, text: "原文", instruction: "整理") }
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.first?.url?.path == "/v1/responses")
    }
    @Test func metadataCannotSwitchKeyToAnotherProviderAuthenticationScheme() async {
        let transport = RoutingTransport()
        var model = AIModel(id: "gpt-test")
        model.metadata.bindings = [.init(task: .textGeneration, apiProtocol: .anthropic, evidence: .init(.service, source: "服务"))]
        let provider = Provider(name: "SDK", baseURL: "http://127.0.0.1:8000/v1", models: [model], textBackend: .swiftAI)
        let client = AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
        await #expect(throws: HubError.self) { try await client.transform(provider: provider, key: "fake", model: model.id, text: "原文", instruction: "整理") }
        #expect(await transport.requests.isEmpty)
    }
}
