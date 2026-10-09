import Foundation
import Testing
@testable import AIHubCore

struct BackendBoundaryTests {
    func local() -> Provider {
        var provider = Provider(name: "Local", baseURL: "")
        provider.selectChannel(.cliProxyAPI)
        return provider
    }
    @Test func oldConfigurationKeepsBuiltInBackend() throws {
        let provider = Provider(name: "Existing", baseURL: "https://api.openai.com/v1")
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any])
        json.removeValue(forKey: "textBackend")
        let restored = try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.textBackend == .builtIn)
        var sdk = restored; sdk.textBackend = .swiftAI
        #expect(try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(sdk)) == sdk)
    }
    @Test func newAPIChannelsDefaultToSDKButAccountsStayDirect() {
        for channel in [ChannelType.openAIChat, .openAIResponses, .anthropic, .gemini, .cliProxyAPI] {
            var provider = local(); provider.selectChannel(channel)
            #expect(provider.textBackend == .swiftAI && provider.supportsSDKText)
        }
        for channel in ChannelType.loginChannels + [.xiaomi] {
            var provider = local(); provider.selectChannel(channel)
            #expect(provider.textBackend == .builtIn)
        }
    }
    @Test(arguments: ["http://127.0.0.1:8317/v1", "http://[::1]:8317/v1", "https://127.0.0.1:8317/v1/"])
    func literalLoopbackProxyEndpointsAreAccepted(_ url: String) throws {
        var provider = local(); provider.baseURL = url
        try provider.validateChannel()
    }
    @Test(arguments: ["https://proxy.example/v1", "http://localhost:8317/v1", "https://192.168.1.10/v1", "http://127.0.0.1.evil.example/v1", "http://127.0.0.1:8317/v0/management", "http://127.0.0.1:8317/v1?key=secret", "http://user:secret@127.0.0.1:8317/v1"])
    func unsafeProxyAddressesFailBeforeNetwork(_ url: String) async {
        var provider = local(); provider.baseURL = url
        let transport = StubTransport(body: #"{"data":[]}"#)
        await #expect(throws: HubError.self) { try await AIClient(transport: transport).discover(provider: provider, key: "local-key") }
        #expect(await transport.requests.isEmpty)
    }
    @Test func proxyRejectsSubscriptionCredentialsAndOtherOAuthModes() async throws {
        let local = local()
        var account = local; account.selectChannel(.antigravity)
        let credential = AccountOAuthCredential(channel: .antigravity, accessToken: "fake-access", refreshToken: "fake-refresh", expiresAt: Date().addingTimeInterval(3600))
        let key = try CredentialEnvelope(baseURL: account.baseURL, authentication: .accountOAuth, account: credential).encoded()
        let transport = StubTransport(body: #"{"data":[]}"#)
        await #expect(throws: HubError.self) { try await AIClient(transport: transport).discover(provider: local, key: key) }
        #expect(await transport.requests.isEmpty)
        for auth in [AuthenticationMethod.accountOAuth, .googleOAuth, .bearer] {
            var bad = local; bad.authentication = auth
            #expect(throws: HubError.self) { try bad.validateChannel() }
        }
    }
    @Test func proxyCredentialImportCannotAccidentallyReuseVendorKeys() throws {
        let imported = try CredentialImport.parse(Data(#"{"api_key":"local-service-key"}"#.utf8), channel: .cliProxyAPI)
        #expect(imported.value == "local-service-key" && imported.channelType == .cliProxyAPI)
        for file in [#"{"OPENAI_API_KEY":"vendor-secret"}"#, #"{"access_token":"subscription-secret"}"#, #"{"api_key":"local","tokens":{}}"#, #"{"api_key":""}"#] {
            #expect(throws: HubError.self) { try CredentialImport.parse(Data(file.utf8), channel: .cliProxyAPI) }
        }
    }

    @Test func proxyDoesNotClaimASRJustBecauseCatalogContainsSpeechModels() async {
        var provider = local(); provider.models = [AIModel(id: "whisper-1")]
        #expect(provider.speechModels.isEmpty)
        let transport = StubTransport(body: #"{"text":"not called"}"#)
        await #expect(throws: HubError.self) {
            try await AIClient(transport: transport).transcribe(provider: provider, key: "local", model: "whisper-1", audio: Data([1]), filename: "a.wav")
        }
        #expect(await transport.requests.isEmpty)
    }
    @Test func missingSDKDoesNotSilentlyFallbackToBuiltIn() async {
        var provider = local(); provider.models = [AIModel(id: "model", capability: .chat)]
        let transport = StubTransport(body: #"{"choices":[{"message":{"content":"fallback"}}]}"#)
        await #expect(throws: HubError.self) {
            try await AIClient(transport: transport).transform(provider: provider, key: "local", model: "model", text: "原文", instruction: "整理")
        }
        #expect(await transport.requests.isEmpty)
    }
}
