import Foundation
import Testing
import AIHubCore
import AIHubSDK

private actor ReasoningTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let api: APIProtocol
    let status: Int
    init(_ api: APIProtocol, status: Int = 200) { self.api = api; self.status = status }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let fixture: String
        switch api {
        case .openAIChat: fixture = SDKTextTests.chat
        case .openAIResponses: fixture = SDKTextTests.responses
        case .anthropic: fixture = SDKTextTests.anthropic
        default: fixture = SDKTextTests.gemini
        }
        return (Data(fixture.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
struct PublicReasoningTests {
    private func provider(_ api: APIProtocol) -> Provider {
        let channel: ChannelType = api == .anthropic ? .anthropic : api == .gemini ? .gemini : api == .openAIResponses ? .openAIResponses : .openAIChat
        var provider = Provider(name: "", baseURL: ""); provider.selectChannel(channel)
        var model = ModelCatalog.model(id: api == .anthropic ? "claude-test" : api == .gemini ? "gemini-test" : "gpt-test", entry: [
            "thinking": true, "minThinkingBudget": 0, "maxThinkingBudget": 8192,
            "reasoning": ["supported_efforts": ["low", "high"]],
            "capabilities": ["thinking": ["supported": true, "types": ["enabled": ["supported": true], "disabled": ["supported": true], "adaptive": ["supported": true]]]]
        ])
        model.outputTokenLimit = 4096; provider.models = [model]
        return provider
    }
    @Test(arguments: [APIProtocol.openAIChat, .openAIResponses, .anthropic, .gemini])
    func bothBackendsSerializeRealParameterPathsAndKeepAuth(_ api: APIProtocol) async throws {
        for backend in [TextBackend.builtIn, .swiftAI] {
            var provider = provider(api); provider.textBackend = backend
            provider.models[0].reasoningSelection = api == .anthropic ? .init(mode: .adaptive, effort: "high") : .init(effort: "high")
            let transport = ReasoningTransport(api)
            let client = AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport))
            let result = try await client.transformDetailed(provider: provider, key: "only-fake-key", model: provider.models[0].id, text: "原文", instruction: "整理")
            #expect(result.text == "完成" && result.usage.input == 4)
            let request = try #require(await transport.requests.first)
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            switch api {
            case .openAIChat: #expect(body["reasoning_effort"] as? String == "high" && body["max_completion_tokens"] as? Int == 4096)
            case .openAIResponses: #expect((body["reasoning"] as? [String: Any])?["effort"] as? String == "high" && body["store"] as? Bool == false)
            case .anthropic:
                #expect((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
                #expect((body["output_config"] as? [String: Any])?["effort"] as? String == "high")
            default:
                let thinking = (body["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any]
                #expect(thinking?["thinkingLevel"] as? String == "high" && thinking?["includeThoughts"] as? Bool == false)
            }
            #expect(await transport.requests.count == 1)
            let header = api == .anthropic ? "x-api-key" : api == .gemini ? "x-goog-api-key" : "Authorization"
            #expect(request.value(forHTTPHeaderField: header) == (api == .anthropic || api == .gemini ? "only-fake-key" : "Bearer only-fake-key"))
        }
    }
    @Test func budgetsAreDistinctAndAnthropicMustFitBelowOutputLimit() async throws {
        for api in [APIProtocol.anthropic, .gemini] {
            var provider = provider(api)
            provider.models[0].reasoningSelection = api == .anthropic ? .init(mode: .enabled, budget: 1024) : .init(budget: 1024)
            let transport = ReasoningTransport(api)
            _ = try await AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport)).transform(provider: provider, key: "fake", model: provider.models[0].id, text: "原文", instruction: "整理")
            let request = try #require(await transport.requests.first)
            let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
            if api == .anthropic { #expect((body["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 1024) }
            else { #expect(((body["generationConfig"] as? [String: Any])?["thinkingConfig"] as? [String: Any])?["thinkingBudget"] as? Int == 1024) }
        }
        var invalid = provider(.anthropic); invalid.models[0].reasoningSelection = .init(mode: .enabled, budget: 4096)
        let transport = ReasoningTransport(.anthropic)
        await #expect(throws: HubError.self) { try await AIClient(transport: transport).transform(provider: invalid, key: "fake", model: "claude-test", text: "原文", instruction: "整理") }
        #expect(await transport.requests.isEmpty)
    }
    @Test func unsupportedLevelsMutuallyExclusiveControlsAndUnknownGatewaysFailBeforeNetwork() async {
        var google = provider(.gemini)
        google.models[0].reasoningSelection = .init(effort: "high", budget: 1024)
        var openai = provider(.openAIChat); openai.models[0].reasoningSelection = .init(effort: "medium")
        var gateway = provider(.openAIChat); gateway.baseURL = "https://unknown.example/v1"; gateway.models[0].reasoningSelection = .init(effort: "high")
        for provider in [google, openai, gateway] {
            let transport = ReasoningTransport(provider.effectiveProtocol)
            await #expect(throws: HubError.self) { try await AIClient(transport: transport).transform(provider: provider, key: "fake", model: provider.models[0].id, text: "原文", instruction: "整理") }
            #expect(await transport.requests.isEmpty)
        }
    }
    @Test func metadataWithdrawalPreservesPreferenceButNeverSilentlyDowngrades() async {
        var provider = provider(.openAIChat); provider.models[0].reasoningSelection = .init(effort: "high")
        provider.mergeDiscovered([ModelCatalog.model(id: "gpt-test", entry: ["thinking": false])])
        #expect(provider.models[0].reasoningSelection?.effort == "high")
        let transport = ReasoningTransport(.openAIChat)
        await #expect(throws: HubError.self) { try await AIClient(transport: transport).transform(provider: provider, key: "fake", model: "gpt-test", text: "原文", instruction: "整理") }
        #expect(await transport.requests.isEmpty)
    }
    @Test func parameterRequestFailureDoesNotFallbackAndDefaultDoesNotMeanOff() async throws {
        var provider = provider(.openAIResponses)
        provider.models[0].reasoningSelection = .init(effort: "high")
        let limited = ReasoningTransport(.openAIResponses, status: 429)
        await #expect(throws: HubError.self) { try await AIClient(transport: limited, textBackend: SwiftAITextBackend(transport: limited)).transform(provider: provider, key: "fake", model: "gpt-test", text: "原文", instruction: "整理") }
        #expect(await limited.requests.count == 1)
        provider.models[0].reasoningSelection = nil
        let transport = ReasoningTransport(.openAIResponses)
        _ = try await AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport)).transform(provider: provider, key: "fake", model: "gpt-test", text: "原文", instruction: "整理")
        let body = try #require(try JSONSerialization.jsonObject(with: await transport.requests[0].httpBody!) as? [String: Any])
        #expect(body["thinking"] == nil && body["reasoning"] == nil)
    }
    @Test func subscriptionAndLocalProxyNeverAcquirePublicAPIParameters() {
        for channel in [ChannelType.codex, .grok, .antigravity, .cliProxyAPI] {
            var provider = Provider(name: "", baseURL: ""); provider.selectChannel(channel)
            #expect(PublicReasoningPolicy.style(provider: provider, api: channel.apiProtocol) == nil)
        }
    }
}
