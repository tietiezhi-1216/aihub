import Foundation
import Testing
import AIHubCore
import AIHubSDK

private struct MetadataLoopbackTransport: HTTPTransport {
    let base: String
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard request.url?.absoluteString == "https://models.dev/api.json", request.httpBody == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil else { throw HubError("Metadata request boundary") }
        var local = request; local.url = URL(string: base + "/registry/api.json")!
        return try await SecureHTTPTransport().send(local, maximumResponseBytes: maximumResponseBytes)
    }
}

private struct ReasoningLoopbackTransport: HTTPTransport {
    let base: String
    let family: String
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        guard ["api.openai.com", "api.anthropic.com", "generativelanguage.googleapis.com"].contains(request.url?.host ?? "") else { throw HubError("Test reasoning boundary") }
        var local = request
        local.url = URL(string: base + "/sdk/" + family + request.url!.path + "?reasoning_test=1")!
        return try await SecureHTTPTransport().send(local, maximumResponseBytes: maximumResponseBytes)
    }
}

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AIHUB_TEST_SERVER_URL"] != nil))
struct SDKLoopbackTests {
    @Test(arguments: [APIProtocol.openAIChat, .openAIResponses, .anthropic, .gemini])
    func realHTTPChecksThinkingParameterPathsAndUsage(_ api: APIProtocol) async throws {
        let base = ProcessInfo.processInfo.environment["AIHUB_TEST_SERVER_URL"]!
        let family = api == .openAIChat ? "openai" : api == .openAIResponses ? "responses" : api == .anthropic ? "anthropic" : "gemini"
        var provider = Provider(name: "", baseURL: "")
        provider.selectChannel(api == .openAIChat ? .openAIChat : api == .openAIResponses ? .openAIResponses : api == .anthropic ? .anthropic : .gemini)
        var model = ModelCatalog.model(id: api == .anthropic ? "claude-sonnet-4-6" : api == .gemini ? "gemini-test" : "gpt-test", entry: ["thinking": true, "reasoning": ["supported_efforts": ["low", "high"]], "capabilities": ["thinking": ["supported": true, "types": ["adaptive": ["supported": true]]]]])
        model.reasoningSelection = api == .anthropic ? .init(mode: .adaptive, effort: "high") : .init(effort: "high")
        provider.models = [model]
        for backend in TextBackend.allCases {
            provider.textBackend = backend
            let transport = ReasoningLoopbackTransport(base: base, family: family)
            let result = try await AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport)).transformDetailed(provider: provider, key: "fake", model: model.id, text: "模拟输入", instruction: "整理")
            #expect(result.text == "模拟SDK转换成功" && result.usage.input == 4 && result.usage.output == 2)
        }
    }
    @Test func publicMetadataUsesActualHTTPWithoutUserData() async throws {
        let base = ProcessInfo.processInfo.environment["AIHUB_TEST_SERVER_URL"]!
        let registry = try await PublicRegistryClient(transport: MetadataLoopbackTransport(base: base)).fetch()
        #expect(registry.records.count == 1 && registry.records[0].metadata.reasoning.efforts == ["low", "high"])
    }
    @Test func mixedProtocolsShareOneRealConnection() async throws {
        let base = ProcessInfo.processInfo.environment["AIHUB_TEST_SERVER_URL"]!
        let models = [AIModel(id: "gpt-chat"), ModelCatalog.model(id: "gpt-responses", entry: ["supported_endpoints": ["responses"]])]
        let provider = Provider(name: "Mixed", baseURL: base + "/sdk/mixed/v1", models: models, textBackend: .swiftAI)
        let transport = SecureHTTPTransport()
        let client = AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
        for model in models {
            #expect(try await client.transform(provider: provider, key: "fake", model: model.id, text: "模拟输入", instruction: "整理") == "模拟SDK转换成功")
        }
    }
    @Test(arguments: [APIProtocol.openAIChat, .openAIResponses, .anthropic, .gemini])
    func fourSDKProvidersUseActualHTTP(_ api: APIProtocol) async throws {
        let base = ProcessInfo.processInfo.environment["AIHUB_TEST_SERVER_URL"]!
        let family: String
        switch api {
        case .openAIChat: family = "openai"
        case .openAIResponses: family = "responses"
        case .anthropic: family = "anthropic"
        default: family = "gemini"
        }
        let model = api == .anthropic ? "claude-sonnet-4-6" : api == .gemini ? "gemini-test" : "gpt-test"
        let provider = Provider(name: "SDK HTTP", baseURL: base + "/sdk/\(family)/\(api.defaultVersion)", apiProtocol: api, textBackend: .swiftAI)
        let transport = SecureHTTPTransport()
        let client = AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
        #expect(try await client.transform(provider: provider, key: "fake", model: model, text: "模拟输入", instruction: "整理") == "模拟SDK转换成功")
    }
}
