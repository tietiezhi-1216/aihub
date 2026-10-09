import Foundation
import Testing
@testable import AIHubCore

struct CredentialTests {
    private func google() -> Provider {
        Provider(name: "Google", baseURL: "https://generativelanguage.googleapis.com/v1beta", authentication: .googleOAuth)
    }
    private func credential() -> GoogleOAuthCredential {
        .init(clientID: "test.apps.googleusercontent.com", clientSecret: "test-secret", refreshToken: "test-refresh")
    }

    @Test func codexAPIKeyFileIsNotConfusedWithSubscriptionTokens() throws {
        let key = try CredentialImport.parse(Data(#"{"OPENAI_API_KEY":"test-api-key","tokens":null}"#.utf8))
        #expect(key.value == "test-api-key")
        #expect(key.apiProtocol == .openAIResponses)
        #expect(key.authentication == .apiKey)
        #expect(throws: HubError.self) {
            try CredentialImport.parse(Data(#"{"OPENAI_API_KEY":null,"tokens":{"access_token":"subscription-secret","refresh_token":"private"}}"#.utf8))
        }
    }

    @Test func googleAuthorizedUserFileIsBoundToOfficialEndpoint() throws {
        let imported = try CredentialImport.parse(Data(#"{"type":"authorized_user","client_id":"test.apps.googleusercontent.com","client_secret":"fake","refresh_token":"fake","token_uri":"https://evil.example/token","quota_project_id":"test-project"}"#.utf8))
        #expect(imported.authentication == .googleOAuth)
        #expect(imported.baseURL == "https://generativelanguage.googleapis.com/v1beta")
        let envelope = try #require(try CredentialEnvelope.decode(imported.value))
        try envelope.validate(for: google())
        var relay = google()
        relay.baseURL = "https://relay.example/v1beta"
        #expect(throws: HubError.self) { try envelope.validate(for: relay) }
    }

    @Test func bearerFileRequiresExplicitEndpointAndProtocol() throws {
        let value = try CredentialImport.parse(Data(#"{"access_token":"test-token","api_address":"https://example.com/v1","api_protocol":"openAIResponses"}"#.utf8))
        let provider = Provider(name: "Bound", baseURL: "https://example.com/v1", apiProtocol: .openAIResponses, authentication: .bearer)
        #expect(try CredentialEnvelope.validateStored(value.value, for: provider) == value.value)
        #expect(throws: HubError.self) {
            try CredentialImport.parse(Data(#"{"access_token":"unbound-token"}"#.utf8))
        }
    }

    @Test(arguments: ["not JSON", "{}", #"{"api_key":"a","GEMINI_API_KEY":"b"}"#, #"{"type":"authorized_user","refresh_token":"x"}"#])
    func invalidOrAmbiguousFilesAreRejected(_ json: String) { #expect(throws: HubError.self) { try CredentialImport.parse(Data(json.utf8)) } }

    @Test func credentialFileLimitsAndNoSecretInError() {
        #expect(throws: HubError.self) { try CredentialImport.parse(Data(repeating: 0, count: CredentialImport.maximumBytes + 1)) }
        do {
            _ = try CredentialImport.parse(Data(#"{"access_token":"PRIVATE_SENTINEL"}"#.utf8))
            Issue.record("Expected rejection")
        } catch { #expect(!error.localizedDescription.contains("PRIVATE_SENTINEL")) }
    }

    @Test func googleRefreshUsesOnlyFixedGoogleTokenEndpointAndCaches() async throws {
        let transport = StubTransport(body: #"{"access_token":"new-access","token_type":"Bearer","expires_in":3600}"#)
        let resolver = CredentialResolver(transport: transport)
        let value = try CredentialEnvelope(baseURL: google().baseURL, authentication: .googleOAuth, google: credential()).encoded()
        let first = try await resolver.resolve(value, for: google())
        let second = try await resolver.resolve(value, for: google())
        #expect(first.secret == "new-access" && second.secret == first.secret && first.bearer)
        let requests = await transport.requests
        #expect(requests.count == 1)
        #expect(requests[0].url?.absoluteString == "https://oauth2.googleapis.com/token")
        let form = String(decoding: try #require(requests[0].httpBody), as: UTF8.self)
        #expect(form.contains("grant_type=refresh_token"))
        #expect(form.contains("refresh_token=test-refresh"))
    }

    @Test func refreshedTokensArePersistedOnlyForMatchingSavedCredentials() async throws {
        let transport = StubTransport(body: #"{"access_token":"new-access","refresh_token":"rotated-refresh","token_type":"Bearer","expires_in":3600}"#)
        let vault = MemoryVault()
        let provider = google()
        let value = try CredentialEnvelope(baseURL: provider.baseURL, authentication: .googleOAuth, google: credential()).encoded()
        try vault.set(value, for: provider.id)
        let resolver = CredentialResolver(transport: transport, vault: vault)
        _ = try await resolver.resolve(value, for: provider)
        let saved = try #require(try vault.read(provider.id))
        let envelope = try #require(try CredentialEnvelope.decode(saved))
        #expect(envelope.google?.refreshToken == "rotated-refresh")
        #expect(envelope.google?.accessToken == "new-access")
        let unsavedProvider = google()
        _ = try await resolver.resolve(value, for: unsavedProvider)
        #expect(try vault.read(unsavedProvider.id) == nil)
    }

    @Test func validAccessTokenDoesNotRefresh() async throws {
        let transport = StubTransport(body: "{}")
        var current = credential()
        current.accessToken = "cached-access"
        current.expiresAt = Date().addingTimeInterval(3600)
        let value = try CredentialEnvelope(baseURL: google().baseURL, authentication: .googleOAuth, google: current).encoded()
        let result = try await CredentialResolver(transport: transport).resolve(value, for: google())
        #expect(result.secret == "cached-access")
        #expect(await transport.requests.isEmpty)
    }

    @Test func oauthMetadataWithPlainAPIKeyIsRejectedBeforeNetwork() async {
        let transport = StubTransport(body: "{}")
        await #expect(throws: HubError.self) { try await CredentialResolver(transport: transport).resolve("not-oauth", for: google()) }
        #expect(await transport.requests.isEmpty)
    }

    @Test func refreshErrorIsRedacted() async {
        let transport = StubTransport(status: 400, body: #"{"error":"refresh-token-PRIVATE"}"#)
        do {
            _ = try await GoogleOAuthClient(transport: transport).refresh(credential())
            Issue.record("Expected failure")
        } catch { #expect(!error.localizedDescription.contains("PRIVATE")) }
    }

    @Test func desktopClientAndAuthorizationURLUsePKCE() throws {
        let client = try GoogleDesktopClient.parse(Data(#"{"installed":{"client_id":"test.apps.googleusercontent.com","client_secret":"secret","auth_uri":"https://evil.example"}}"#.utf8))
        let url = GoogleOAuthClient().authorizationURL(client: client, redirectURI: "http://127.0.0.1:1234/oauth/callback", state: "random-state", verifier: "random-verifier")
        #expect(url.host == "accounts.google.com")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        #expect(query?.first { $0.name == "code_challenge_method" }?.value == "S256")
        #expect(query?.first { $0.name == "state" }?.value == "random-state")
        #expect(query?.first { $0.name == "client_secret" } == nil)
    }

    @Test func pkceMatchesRFC7636Vector() throws {
        #expect(OAuthPKCE.challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk") == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        #expect(try OAuthPKCE.random().count == 43)
        #expect(try OAuthPKCE.random() != OAuthPKCE.random())
    }

    private func callback(_ target: String, host: String = "127.0.0.1:1234") -> Data {
        Data("GET \(target) HTTP/1.1\r\nHost: \(host)\r\n\r\n".utf8)
    }
    @Test func callbackAcceptsOnlyMatchingLoopbackStateAndPath() throws {
        #expect(try OAuthCallback.code(httpRequest: callback("/oauth/callback?code=4%2Fabc&state=expected"), redirectURI: "http://127.0.0.1:1234/oauth/callback", expectedState: "expected") == "4/abc")
    }
    @Test(arguments: [
        "/oauth/callback?code=x&state=wrong", "/oauth/callback?code=x&state=expected&state=wrong",
        "/oauth/callback?code=x&code=y&state=expected", "/wrong?code=x&state=expected",
        "/oauth/callback?code=&state=expected", "/oauth/callback?code=x%0Ainjected&state=expected"
    ])
    func unsafeCallbacksAreRejected(_ target: String) {
        #expect(throws: OAuthCallbackError.self) {
            try OAuthCallback.code(httpRequest: callback(target), redirectURI: "http://127.0.0.1:1234/oauth/callback", expectedState: "expected")
        }
    }
    @Test func hostileHostHeaderIsRejected() {
        #expect(throws: OAuthCallbackError.self) {
            try OAuthCallback.code(httpRequest: callback("/oauth/callback?code=x&state=expected", host: "evil.example"), redirectURI: "http://127.0.0.1:1234/oauth/callback", expectedState: "expected")
        }
    }

    @Test func oauthCredentialsPersistOnlyInVault() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-oauth-tests-\(UUID())/settings.json")
        defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
        let repository = SettingsRepository(fileURL: url)
        let vault = MemoryVault()
        let service = ConfigurationService(persistence: repository, vault: vault)
        let provider = google()
        let value = try CredentialEnvelope(baseURL: provider.baseURL, authentication: .googleOAuth, google: credential()).encoded()
        _ = try service.upsert(provider, newKey: value, settings: AppSettings())
        let raw = try String(contentsOf: url, encoding: .utf8)
        #expect(!raw.contains("test-refresh") && !raw.contains("test-secret"))
        #expect(try vault.read(provider.id) == value)
        #expect(try repository.load().providers.first?.authentication == .googleOAuth)
    }
}
