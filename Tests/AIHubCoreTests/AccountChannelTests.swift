import Foundation
import Testing
@testable import AIHubCore

struct AccountChannelTests {
    func provider(_ channel: ChannelType) -> Provider {
        var result = Provider(name: "", baseURL: "")
        result.selectChannel(channel)
        return result
    }
    func credential(_ channel: ChannelType, expired: Bool = false) -> AccountOAuthCredential {
        .init(channel: channel, accessToken: "fake-access", refreshToken: "fake-refresh",
              expiresAt: expired ? .distantPast : Date().addingTimeInterval(3600), accountID: channel == .codex ? "test-account" : nil)
    }
    func key(_ channel: ChannelType, expired: Bool = false) throws -> String {
        try CredentialEnvelope(baseURL: channel.defaultURL, authentication: .accountOAuth, account: credential(channel, expired: expired)).encoded()
    }
    func jwt(_ claims: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: claims)
        let encoded = data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        return "header.\(encoded).signature"
    }

    @Test(arguments: [ChannelType.codex, .antigravity, .grok])
    func selectionConfiguresLoginWithoutAPISpeech(_ channel: ChannelType) throws {
        var result = provider(channel)
        #expect(result.baseURL == channel.defaultURL)
        #expect(result.authentication == .accountOAuth)
        try result.validateChannel()
        result.models = [AIModel(id: "whisper-1")]
        #expect(result.speechModels.isEmpty)
        result.baseURL = "https://relay.example/v1"
        #expect(throws: HubError.self) { try result.validateChannel() }
    }
    @Test(arguments: [ChannelType.codex, .antigravity, .grok])
    func authorizationUsesPKCEStateAndOnlyFixedEndpoints(_ channel: ChannelType) throws {
        let definition = try AccountOAuthDefinition(channel: channel)
        let url = definition.authorizationURL(state: "test-state", verifier: "test-verifier", nonce: "test-nonce")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        #expect(query.first { $0.name == "state" }?.value == "test-state")
        #expect(query.first { $0.name == "code_challenge" }?.value == OAuthPKCE.challenge("test-verifier"))
        #expect(query.first { $0.name == "nonce" }?.value == "test-nonce")
        #expect(query.first { $0.name == "redirect_uri" }?.value == definition.redirectURI)
        #expect(query.first { $0.name == "client_secret" } == nil)
        #expect(url.scheme == "https")
    }
    @Test func localhostCallbackRequiresExactlyRegisteredHostAndPath() throws {
        let definition = try AccountOAuthDefinition(channel: .codex)
        let request = Data("GET /auth/callback?state=state&code=code HTTP/1.1\r\nHost: localhost:1455\r\n\r\n".utf8)
        #expect(try OAuthCallback.code(httpRequest: request, redirectURI: definition.redirectURI, expectedState: "state") == "code")
        #expect(throws: OAuthCallbackError.self) {
            try OAuthCallback.code(httpRequest: request, redirectURI: "http://127.0.0.1:1455/auth/callback", expectedState: "state")
        }
    }
    @Test func codexImportsCompleteSubscriptionFileAndRejectsWrongChannel() throws {
        let access = try jwt(["https://api.openai.com/auth": ["chatgpt_account_id": "account"], "exp": 2_000_000_000])
        let data = try JSONSerialization.data(withJSONObject: ["OPENAI_API_KEY": NSNull(), "tokens": ["access_token": access, "refresh_token": "refresh", "account_id": "account"]])
        let imported = try CredentialImport.parse(data, channel: .codex)
        #expect(imported.channelType == .codex)
        #expect(imported.authentication == .accountOAuth)
        #expect(try CredentialEnvelope.decode(imported.value)?.account?.accountID == "account")
        #expect(throws: HubError.self) { try CredentialImport.parse(data, channel: .grok) }
        #expect(throws: HubError.self) { try CredentialEnvelope.validateStored(imported.value, for: provider(.grok)) }
    }
    @Test func grokImportsOAuthButDoesNotTrustFileTokenEndpoint() throws {
        let imported = try CredentialImport.parse(Data(#"{"xai":{"type":"oauth","access":"fake","refresh":"fake","expires":2000000000000,"tokenEndpoint":"https://evil.example/token"}}"#.utf8), channel: .grok)
        #expect(imported.channelType == .grok)
        let envelope = try #require(try CredentialEnvelope.decode(imported.value))
        #expect(envelope.account?.expiresAt == Date(timeIntervalSince1970: 2_000_000_000))
        #expect(try AccountOAuthDefinition(channel: envelope.account!.channel).tokenURL.host == "auth.x.ai")
    }
    @Test func antigravityADCRequiresMatchingClient() throws {
        let definition = try AccountOAuthDefinition(channel: .antigravity)
        let data = try JSONSerialization.data(withJSONObject: ["type": "authorized_user", "client_id": definition.clientID, "client_secret": "public", "refresh_token": "fake"])
        let imported = try CredentialImport.parse(data, channel: .antigravity)
        #expect(imported.channelType == .antigravity)
        #expect(try CredentialEnvelope.decode(imported.value)?.account?.expiresAt == Date(timeIntervalSince1970: 0))
        #expect(throws: HubError.self) {
            try CredentialImport.parse(Data(#"{"type":"authorized_user","client_id":"other.apps.googleusercontent.com","refresh_token":"fake"}"#.utf8), channel: .antigravity)
        }
    }
    @Test func loginCredentialsCannotGoToRelayOrDifferentAuth() async throws {
        let transport = StubTransport(body: #"{"data":[]}"#)
        let client = AIClient(transport: transport)
        var altered = provider(.grok); altered.baseURL = "https://relay.example/v1"
        await #expect(throws: HubError.self) { try await client.discover(provider: altered, key: key(.grok)) }
        altered = provider(.grok); altered.authentication = .apiKey
        await #expect(throws: HubError.self) { try await client.discover(provider: altered, key: "fake") }
        #expect(await transport.requests.isEmpty)
    }
    @Test func codexDiscoveryUsesItsAccountBackendAndNoFalseVerification() async throws {
        let transport = StubTransport(body: #"{"models":[{"slug":"gpt-test-codex","display_name":"Codex Test","visibility":"list"},{"slug":"hidden","visibility":"hidden"},{"slug":"gpt-test-codex"}]}"#)
        let models = try await AIClient(transport: transport).discover(provider: provider(.codex), key: key(.codex))
        #expect(models.count == 2)
        #expect(models.first { $0.id == "gpt-test-codex" }?.capability == .chat)
        #expect(models.contains { $0.id == "hidden" })
        #expect(models.allSatisfy { $0.verifiedAt == nil })
        let request = try #require(await transport.requests.first)
        #expect(request.url?.host == "chatgpt.com")
        #expect(request.url?.path == "/backend-api/codex/models")
        #expect(request.value(forHTTPHeaderField: "ChatGPT-Account-Id") == "test-account")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer fake-access")
        #expect(request.url?.query?.contains("client_version=") == true)
    }
    @Test func grokDiscoveryAndStreamingGenerationUseSubscriptionProxy() async throws {
        let discovery = StubTransport(body: #"{"data":[{"id":"grok-build","name":"Grok Build"}]}"#)
        #expect(try await AIClient(transport: discovery).discover(provider: provider(.grok), key: key(.grok)).first?.capability == .chat)
        let stream = "data: {\"choices\":[{\"delta\":{\"content\":\"整理成功\"}}]}\n\ndata: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
        let transport = StubTransport(body: stream)
        let result = try await AIClient(transport: transport).transform(provider: provider(.grok), key: key(.grok), model: "grok-build", text: "输入", instruction: "整理")
        #expect(result == "整理成功")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.absoluteString == "https://cli-chat-proxy.grok.com/v1/chat/completions")
        #expect(request.value(forHTTPHeaderField: "X-XAI-Token-Auth") == "xai-grok-cli")
        #expect(request.value(forHTTPHeaderField: "x-grok-model-override") == "grok-build")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["stream"] as? Bool == true)
    }
    @Test func antigravityDiscoversOwnProjectAndCachesOnlyBoundMetadata() async throws {
        let transport = AccountSequenceTransport([
            #"{"models":{"gemini-test":{"displayName":"Gemini Test"},"claude-test":{"displayName":"Claude Test"}}}"#,
            #"{"cloudaicompanionProject":{"id":"owned-project"}}"#,
            "data: {\"response\":{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"private-thought\",\"thought\":true},{\"text\":\"结果\"}]},\"finishReason\":\"STOP\"}]}}\n\n"
        ])
        let client = AIClient(transport: transport)
        let value = try key(.antigravity)
        let models = try await client.discover(provider: provider(.antigravity), key: value)
        #expect(models.count == 2 && models.allSatisfy { $0.capability == .chat })
        #expect(try await client.transform(provider: provider(.antigravity), key: value, model: "gemini-test", text: "输入", instruction: "整理") == "结果")
        let requests = await transport.requests
        #expect(requests.count == 3)
        #expect(requests[0].url?.path == "/v1internal:fetchAvailableModels")
        #expect(requests[0].url?.host == "daily-cloudcode-pa.googleapis.com")
        #expect(requests[0].httpBody == Data("{}".utf8))
        #expect(requests[0].value(forHTTPHeaderField: "Client-Metadata") == nil)
        #expect(requests[1].url?.path == "/v1internal:loadCodeAssist")
        let setup = try #require(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        #expect(setup["metadata"] as? [String: String] == ["ideType": "ANTIGRAVITY"])
        #expect(requests[2].url?.path == "/v1internal:streamGenerateContent")
        let body = try #require(try JSONSerialization.jsonObject(with: requests[2].httpBody!) as? [String: Any])
        #expect(body["project"] as? String == "owned-project")
        let updated = try #require(try await client.refreshedCredential(value, for: provider(.antigravity)))
        #expect(try CredentialEnvelope.decode(updated)?.account?.projectID == "owned-project")
    }
    @Test func antigravityNeverBorrowsAnUnownedFallbackProject() {
        #expect(throws: HubError.self) { try AccountProtocol.project(Data(#"{"allowedTiers":[{"id":"free"}]}"#.utf8)) }
    }
    @Test func codexStreamsOnlyCompleteAssistantText() async throws {
        let stream = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"结果\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\"}}\n\n"
        let transport = StubTransport(body: stream)
        #expect(try await AIClient(transport: transport).transform(provider: provider(.codex), key: key(.codex), model: "gpt-codex", text: "输入", instruction: "整理") == "结果")
        let request = try #require(await transport.requests.first)
        #expect(request.url?.path == "/backend-api/codex/responses")
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["store"] as? Bool == false && body["stream"] as? Bool == true)
        #expect(body["instructions"] as? String == "整理")
    }
    @Test(arguments: [ChannelType.codex, .antigravity, .grok])
    func partialStreamsAreRejected(_ channel: ChannelType) {
        #expect(throws: HubError.self) { try AccountProtocol.generationText(Data("data: {}\n\n".utf8), channel: channel) }
    }
    @Test func streamErrorsNeverEchoSensitivePayloads() {
        do {
            _ = try AccountProtocol.generationText(Data("data: {\"type\":\"error\",\"message\":\"PRIVATE_TOKEN\"}\n\n".utf8), channel: .codex)
            Issue.record("Expected failure")
        } catch { #expect(!error.localizedDescription.contains("PRIVATE_TOKEN")) }
    }
    @Test func refreshPersistsOnlyMatchingCredentialsAndUsesFixedIssuer() async throws {
        let transport = StubTransport(body: #"{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600,"token_type":"Bearer"}"#)
        let vault = MemoryVault(), result = provider(.grok), value = try key(.grok, expired: true)
        try vault.set(value, for: result.id)
        let resolver = CredentialResolver(transport: transport, vault: vault)
        #expect(try await resolver.resolve(value, for: result).secret == "new-access")
        let updated = try #require(try vault.read(result.id))
        #expect(try CredentialEnvelope.decode(updated)?.account?.refreshToken == "new-refresh")
        _ = try await resolver.resolve(value, for: result)
        #expect(await transport.requests.count == 1)
        #expect(await transport.requests.first?.url?.absoluteString == "https://auth.x.ai/oauth2/token")
        try vault.set("replacement", for: result.id)
        _ = try await resolver.resolve(value, for: result)
        #expect(try vault.read(result.id) == "replacement")
    }
    @Test func oauthExchangeChecksNonceAndNeverIncludesSecretInBrowserURL() async throws {
        let token = try jwt(["nonce": "expected", "email": "test@example.com"])
        let body = try JSONSerialization.data(withJSONObject: ["access_token": "fake", "refresh_token": "fake", "expires_in": 3600, "id_token": token, "token_type": "Bearer"])
        let transport = StubTransport(body: String(decoding: body, as: UTF8.self))
        let client = AccountOAuthClient(transport: transport), definition = try AccountOAuthDefinition(channel: .grok)
        #expect(try await client.exchange(code: "code", definition: definition, verifier: "verifier", nonce: "expected").email == "test@example.com")
        await #expect(throws: HubError.self) { try await client.exchange(code: "code", definition: definition, verifier: "verifier", nonce: "wrong") }
    }
    @Test func loginSaveStoresNoTokensOrIdentityInSettings() throws {
        let repository = SettingsRepository(fileURL: FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-accounts-\(UUID())/settings.json"))
        defer { try? FileManager.default.removeItem(at: repository.fileURL.deletingLastPathComponent()) }
        let vault = MemoryVault(), result = provider(.codex), value = try key(.codex)
        let service = ConfigurationService(persistence: repository, vault: vault)
        let settings = try service.upsert(result, newKey: value, settings: AppSettings())
        #expect(try repository.load().providers.first?.channelType == .codex)
        let raw = try String(contentsOf: repository.fileURL, encoding: .utf8)
        #expect(!raw.contains("fake-access") && !raw.contains("fake-refresh") && !raw.contains("test-account"))
        #expect(try vault.read(result.id) == value)
        var changed = result; changed.selectChannel(.grok)
        #expect(throws: HubError.self) { try service.upsert(changed, newKey: "", settings: settings) }
    }
}

actor AccountSequenceTransport: HTTPTransport {
    private var bodies: [String]
    var requests: [URLRequest] = []
    init(_ bodies: [String]) { self.bodies = bodies }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        guard !bodies.isEmpty else { throw HubError("Unexpected mock request") }
        return (Data(bodies.removeFirst().utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
