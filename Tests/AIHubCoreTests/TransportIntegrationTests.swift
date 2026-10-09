import Foundation
import Testing
@testable import AIHubCore

@Suite(.enabled(if: ProcessInfo.processInfo.environment["AIHUB_TEST_SERVER_URL"] != nil))
struct TransportIntegrationTests {
    private var base: String { ProcessInfo.processInfo.environment["AIHUB_TEST_SERVER_URL"]! }
    private func provider(path: String = "/v1") -> Provider {
        Provider(name: "Local test server", kind: .compatible, baseURL: base + path, requiresAPIKey: false)
    }

    @Test func realNetworkDiscoveryAndMultipartAndChat() async throws {
        let client = AIClient()
        let models = try await client.discover(provider: provider(), key: nil)
        #expect(models.map(\.id) == ["gpt-4o-mini", "whisper-1"])
        let transcript = try await client.transcribe(
            provider: provider(), key: nil, model: "whisper-1",
            audio: Data([0, 1, 255, 13, 10, 42]), filename: "source.wav", language: "zh", vocabulary: "AIHub"
        )
        #expect(transcript == "模拟识别成功")
        let result = try await client.transform(
            provider: provider(), key: nil, model: "gpt-4o-mini", text: transcript, instruction: "整理"
        )
        #expect(result == "模拟转换成功")
    }

    @Test(arguments: [APIProtocol.openAIChat, .openAIResponses, .anthropic, .gemini, .xiaomi])
    func realProtocolDiscoveryAndGeneration(_ api: APIProtocol) async throws {
        let name: String
        switch api {
        case .openAIResponses: name = "responses"
        case .anthropic: name = "anthropic"
        case .gemini: name = "gemini"
        case .xiaomi: name = "xiaomi"
        default: name = "openai"
        }
        let provider = Provider(name: name, baseURL: base + "/\(name)/\(api.defaultVersion)", apiProtocol: api)
        let client = AIClient()
        let models = try await client.discover(provider: provider, key: "fake")
        #expect(!models.isEmpty)
        if api == .anthropic || api == .gemini { #expect(models.count == 2) }
        let result = try await client.transform(
            provider: provider, key: "fake", model: api == .gemini ? "gemini-test" : "test",
            text: "模拟输入", instruction: "整理"
        )
        #expect(result == "模拟转换成功")
        if api == .xiaomi {
            let text = try await client.transcribe(
                provider: provider, key: "fake", model: "mimo-v2.5-asr",
                audio: Data([0, 1, 255, 13, 10, 42]), filename: "audio.wav"
            )
            #expect(text == "模拟小米识别成功")
        }
    }

    @Test(arguments: [ChannelType.codex, .antigravity, .grok])
    func accountBackendsUseRealHTTPAndFragmentedSSE(_ channel: ChannelType) async throws {
        var provider = Provider(name: "", baseURL: "")
        provider.selectChannel(channel)
        let credential = AccountOAuthCredential(channel: channel, accessToken: "fake-access", refreshToken: "fake-refresh",
                                               expiresAt: Date().addingTimeInterval(3600), accountID: channel == .codex ? "mock-account" : nil)
        let key = try CredentialEnvelope(baseURL: channel.defaultURL, authentication: .accountOAuth, account: credential).encoded()
        let client = AIClient(transport: AccountLoopbackTransport(base: base))
        let models = try await client.discover(provider: provider, key: key)
        if channel == .antigravity {
            #expect(models.count == 6)
            #expect(Set(models.map(\.capability)) == Set([.chat, .image, .video, .transcription, .speechSynthesis, .unknown]))
            #expect(models.first { $0.id == "gemini-test" }?.isMultimodal == true)
        } else { #expect(models.count == 1 && models[0].capability == .chat) }
        let textModel = try #require(models.first { $0.supportsTextOutput })
        let result = try await client.transform(provider: provider, key: key, model: textModel.id, text: "模拟输入", instruction: "整理")
        #expect(result == "模拟转换成功")
    }

    @Test func redirectIsNotFollowed() async throws {
        await #expect(throws: HubError.self) {
            try await AIClient().discover(provider: provider(path: "/redirect"), key: "fake-key")
        }
        let request = URLRequest(url: URL(string: base + "/stats")!)
        let (data, _) = try await SecureHTTPTransport().send(request, maximumResponseBytes: 1024)
        let stats = try JSONSerialization.jsonObject(with: data) as? [String: Int]
        #expect(stats?["redirectTargetHits"] == 0)
    }

    @Test func oversizedDeclaredResponseIsRejected() async {
        let request = URLRequest(url: URL(string: base + "/oversized")!)
        await #expect(throws: HubError.self) {
            try await SecureHTTPTransport().send(request, maximumResponseBytes: 128)
        }
    }

    @Test func oversizedUnknownLengthResponseIsRejected() async {
        let request = URLRequest(url: URL(string: base + "/unknown-length")!)
        await #expect(throws: HubError.self) {
            try await SecureHTTPTransport().send(request, maximumResponseBytes: 128)
        }
    }

    @Test func actualNetworkCancellation() async throws {
        let client = AIClient()
        let slow = provider(path: "/slow")
        let task = Task { try await client.discover(provider: slow, key: nil) }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
    }
}

/// Test-only transport mapping: production still constructs and validates fixed
/// subscription URLs; only this injected fixture transport rewrites to loopback.
private struct AccountLoopbackTransport: HTTPTransport {
    let base: String
    private let transport = SecureHTTPTransport()
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let channel: String
        switch request.url?.host {
        case "chatgpt.com": channel = "codex"
        case "cli-chat-proxy.grok.com": channel = "grok"
        case "cloudcode-pa.googleapis.com", "daily-cloudcode-pa.googleapis.com": channel = "antigravity"
        default: throw HubError("Unexpected fixture host")
        }
        var mapped = request
        var target = URLComponents(string: base)!
        guard target.host == "127.0.0.1", target.scheme == "http" else { throw HubError("Fixture must be loopback") }
        target.path = "/accounts/\(channel)\(request.url!.path)"
        target.percentEncodedQuery = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.percentEncodedQuery
        mapped.url = target.url!
        return try await transport.send(mapped, maximumResponseBytes: maximumResponseBytes)
    }
}
