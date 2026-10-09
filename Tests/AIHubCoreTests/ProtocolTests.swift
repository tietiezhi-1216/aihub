import Foundation
import Testing
@testable import AIHubCore

actor SequenceTransport: HTTPTransport {
    let bodies: [String]
    var requests: [URLRequest] = []
    init(_ bodies: [String]) { self.bodies = bodies }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let index = min(requests.count, bodies.count - 1)
        requests.append(request)
        return (Data(bodies[index].utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}

struct ProtocolTests {
    @Test(arguments: [
        ("https://api.anthropic.com", APIProtocol.anthropic),
        ("https://generativelanguage.googleapis.com", APIProtocol.gemini),
        ("https://api.xiaomimimo.com/v1", APIProtocol.xiaomi),
        ("https://token-plan-cn.xiaomimimo.com/v1", APIProtocol.xiaomi),
        ("https://api.x.ai/v1", APIProtocol.openAIChat),
        ("https://api.groq.com/openai/v1", APIProtocol.openAIChat),
        ("https://notgenerativelanguage.googleapis.com", APIProtocol.openAIChat),
        ("https://api.anthropic.com.evil.example", APIProtocol.openAIChat)
    ])
    func detectsOnlyKnownHosts(_ base: String, _ expected: APIProtocol) {
        #expect(APIProtocol.detect(baseURL: base) == expected)
    }

    @Test func geminiFetchesEveryPageAndClassifiesMetadata() async throws {
        let transport = SequenceTransport([
            #"{"models":[{"name":"models/gemini-2.5-flash","displayName":"Gemini Flash","supportedGenerationMethods":["generateContent"]}],"nextPageToken":"next/with+symbols"}"#,
            #"{"models":[{"name":"models/embedding-001","supportedGenerationMethods":["embedContent"]},{"name":"models/unusual-llm","supportedGenerationMethods":["generateContent"]}]}"#
        ])
        let provider = Provider(name: "Google", baseURL: "https://generativelanguage.googleapis.com")
        let models = try await AIClient(transport: transport).discover(provider: provider, key: "fake")
        #expect(models.count == 3)
        #expect(models.first { $0.id == "gemini-2.5-flash" }?.name == "Gemini Flash")
        #expect(models.first { $0.id == "embedding-001" }?.capability == .embedding)
        #expect(models.first { $0.id == "unusual-llm" }?.capability == .chat)
        let requests = await transport.requests
        #expect(requests.count == 2)
        #expect(requests[0].url?.path == "/v1beta/models")
        #expect(requests[0].value(forHTTPHeaderField: "x-goog-api-key") == "fake")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        let query = URLComponents(url: requests[1].url!, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "pageToken" }?.value == "next/with+symbols")
    }

    @Test func anthropicPaginationAndHeaders() async throws {
        let transport = SequenceTransport([
            #"{"data":[{"id":"claude-sonnet-4","display_name":"Claude Sonnet"}],"has_more":true,"last_id":"claude-sonnet-4"}"#,
            #"{"data":[{"id":"claude-opus-4"}],"has_more":false}"#
        ])
        let models = try await AIClient(transport: transport).discover(
            provider: Provider(name: "Anthropic", baseURL: "https://api.anthropic.com"), key: "fake"
        )
        #expect(models.allSatisfy { $0.capability == .chat && $0.verifiedAt == nil })
        let requests = await transport.requests
        #expect(requests[0].value(forHTTPHeaderField: "x-api-key") == "fake")
        #expect(requests[0].value(forHTTPHeaderField: "anthropic-version") == "2023-06-01")
        #expect(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        #expect(requests[1].url?.query?.contains("after_id=claude-sonnet-4") == true)
    }

    @Test func repeatedPageCursorFailsInsteadOfSavingPartialCatalog() async {
        let transport = SequenceTransport([#"{"models":[],"nextPageToken":"same"}"#])
        await #expect(throws: HubError.self) {
            try await AIClient(transport: transport).discover(
                provider: Provider(name: "Google", baseURL: "https://generativelanguage.googleapis.com/v1beta"), key: "fake"
            )
        }
        #expect(await transport.requests.count == 2)
    }

    @Test(arguments: [APIProtocol.openAIChat, .openAIResponses, .anthropic, .gemini, .xiaomi])
    func generationRoutesBodiesAndHeaders(_ api: APIProtocol) async throws {
        let body: String
        let route: String
        switch api {
        case .openAIResponses:
            body = #"{"status":"completed","output":[{"type":"message","role":"assistant","content":[{"type":"output_text","text":"结果"}]}]}"#
            route = "/v1/responses"
        case .anthropic:
            body = #"{"content":[{"type":"text","text":"结果"},{"type":"thinking","thinking":"hidden"}]}"#
            route = "/v1/messages"
        case .gemini:
            body = #"{"candidates":[{"content":{"parts":[{"text":"hidden","thought":true},{"text":"结果"}]},"finishReason":"STOP"}]}"#
            route = "/v1beta/models/gemini-test:generateContent"
        default:
            body = #"{"choices":[{"message":{"content":"结果"}}]}"#
            route = "/v1/chat/completions"
        }
        let transport = StubTransport(body: body)
        let model = api == .gemini ? "gemini-test" : "test-model"
        let provider = Provider(name: "Test", baseURL: "https://example.com", apiProtocol: api)
        let output = try await AIClient(transport: transport).transform(
            provider: provider, key: "fake", model: model, text: "输入", instruction: "指令"
        )
        #expect(output == "结果")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == route)
        #expect(request.httpMethod == "POST")
        let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        switch api {
        case .openAIResponses:
            #expect(payload?["instructions"] as? String == "指令")
            #expect(payload?["input"] as? String == "输入")
            #expect(payload?["store"] as? Bool == false)
        case .anthropic:
            #expect(payload?["system"] as? String == "指令")
            #expect(payload?["max_tokens"] as? Int == 4096)
            #expect(request.value(forHTTPHeaderField: "x-api-key") == "fake")
        case .gemini:
            #expect(payload?["contents"] != nil)
            #expect(payload?["systemInstruction"] != nil)
            #expect(request.value(forHTTPHeaderField: "x-goog-api-key") == "fake")
        case .xiaomi:
            #expect(request.value(forHTTPHeaderField: "api-key") == "fake")
            #expect(payload?["messages"] != nil)
        default: #expect(payload?["messages"] != nil)
        }
    }

    @Test func xiaomiUsesAudioChatNotMultipart() async throws {
        let transport = StubTransport(body: #"{"choices":[{"message":{"content":"识别结果"}}]}"#)
        let audio = Data([0, 1, 2, 3])
        let result = try await AIClient(transport: transport).transcribe(
            provider: Provider(name: "MiMo", baseURL: "https://api.xiaomimimo.com/v1"), key: "fake",
            model: "mimo-v2.5-asr", audio: audio, filename: "audio.wav", language: "zh"
        )
        #expect(result == "识别结果")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/v1/chat/completions")
        let payload = try JSONSerialization.jsonObject(with: #require(request.httpBody)) as? [String: Any]
        let messages = payload?["messages"] as? [[String: Any]]
        let part = (messages?.first?["content"] as? [[String: Any]])?.first
        #expect((part?["input_audio"] as? [String: String])?["data"] == "data:audio/wav;base64,\(audio.base64EncodedString())")
        #expect((payload?["asr_options"] as? [String: String])?["language"] == "zh")
    }

    @Test(arguments: [APIProtocol.anthropic, .gemini])
    func unsupportedSpeechDoesNotMakeNetworkRequest(_ api: APIProtocol) async {
        let transport = StubTransport(body: "{}")
        await #expect(throws: HubError.self) {
            try await AIClient(transport: transport).transcribe(
                provider: Provider(name: "No ASR", baseURL: "https://example.com/v1", apiProtocol: api),
                key: "fake", model: "whisper-1", audio: Data([1]), filename: "audio.wav"
            )
        }
        #expect(await transport.requests.isEmpty)
    }

    @Test(arguments: ["../secret", "model?key=x", "models/a/b", "model\nheader", "https://other.example"])
    func geminiModelCannotInjectPathsOrQueries(_ id: String) { #expect(throws: HubError.self) { try ProtocolAdapter.geminiModel(id) } }

    @Test(arguments: [
        (APIProtocol.openAIChat, #"{"choices":[{"finish_reason":"length","message":{"content":"partial"}}]}"#),
        (.openAIResponses, #"{"status":"incomplete","output":[]}"#),
        (.anthropic, #"{"stop_reason":"max_tokens","content":[]}"#),
        (.gemini, #"{"candidates":[{"finishReason":"MAX_TOKENS"}]}"#)
    ])
    func incompleteOutputIsNotSuccessful(_ api: APIProtocol, _ response: String) {
        #expect(throws: HubError.self) { try ProtocolAdapter.generationText(data: Data(response.utf8), protocol: api) }
    }

    @Test func responsesCatalogRecognizesCodex() throws {
        let page = try ProtocolAdapter.modelPage(data: Data(#"{"data":[{"id":"gpt-5-codex"}]}"#.utf8), protocol: .openAIResponses)
        #expect(page.models.first?.capability == .chat)
    }

    @Test func oldConfigurationsDecodeWithoutNewFields() throws {
        let provider = Provider(name: "Old", kind: .siliconFlow, baseURL: "https://api.siliconflow.cn/v1", models: [AIModel(id: "whisper-1")])
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any])
        json["apiProtocol"] = nil
        json["authentication"] = nil
        let restored = try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.apiProtocol == .automatic)
        #expect(restored.authentication == .apiKey)
        #expect(restored.usesSiliconFlowSpeech)
        #expect(restored.models.count == 1)
    }

    @Test func completeCatalogFilteringDoesNotTruncateRows() {
        let models = (0..<27).map { AIModel(id: String(format: "model-%02d", $0), capability: .chat) }
        let visible = models.filter { ModelCatalog.matches($0, category: nil, search: "") }
        #expect(visible == models)
        #expect(visible.first?.id == "model-00" && visible.last?.id == "model-26")
        #expect(models.filter { ModelCatalog.matches($0, category: .chat, search: "model-2") }.count == 7)
    }
}
