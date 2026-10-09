import Foundation
import Testing
import AIHubCore
@testable import AIHub

private struct ThinkingSettings: SettingsPersistence {
    let settings: AppSettings
    var failsSaving = false
    func load() throws -> AppSettings { settings }
    func save(_ settings: AppSettings) throws { if failsSaving { throw HubError("Save failure") } }
}
private struct ThinkingVault: CredentialVault {
    let providerID: UUID
    let credential: String
    func read(_ id: UUID) throws -> String? { id == providerID ? credential : nil }
    func set(_ key: String, for providerID: UUID) throws {}
    func delete(_ providerID: UUID) throws {}
}
private actor ThinkingTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let status: Int
    init(status: Int = 200) { self.status = status }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let body = #"{"candidates":[{"content":{"parts":[{"text":"润色结果"}]},"finishReason":"STOP"}]}"#
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

@MainActor struct ThinkingSelectionTests {
    private func settings() -> AppSettings {
        var provider = Provider(name: "", baseURL: ""); provider.selectChannel(.antigravity)
        provider.models = [AIModel(id: "gemini-3.1-pro-high", displayName: "Gemini 3.1 Pro (High)"),
                           AIModel(id: "gemini-3.1-pro-low", displayName: "Gemini 3.1 Pro (Low)")]
        var settings = AppSettings(); settings.providers = [provider]
        settings.chatSelection = .init(providerID: provider.id, modelID: "gemini-3.1-pro-high")
        return settings
    }
    private func vault(_ settings: AppSettings) throws -> ThinkingVault {
        let provider = settings.providers[0]
        var account = AccountOAuthCredential(channel: .antigravity, accessToken: "fake", refreshToken: "fake", expiresAt: Date().addingTimeInterval(3600))
        account.projectID = "owned-project"
        return ThinkingVault(providerID: provider.id, credential: try CredentialEnvelope(baseURL: provider.baseURL, authentication: .accountOAuth, account: account).encoded())
    }
    @Test func llmPickerHasOneModelAndPreservesLegacyHighSelection() throws {
        let settings = settings()
        let state = AppState(repository: ThinkingSettings(settings: settings), vault: try vault(settings))
        #expect(state.chatOptions.count == 1)
        #expect(state.chatOptions[0].modelID == "gemini-3.1-pro-high")
        #expect(state.chatGroup?.name == "Gemini 3.1 Pro")
        #expect(!state.label(for: state.chatOptions[0]).contains("(High)"))
        state.chooseThinking(.low, providerID: settings.providers[0].id, groupID: "gemini-3.1-pro")
        #expect(state.settings.chatSelection?.modelID == "gemini-3.1-pro-low")
        #expect(state.chatOptions.count == 1 && state.chatOptions[0].modelID == "gemini-3.1-pro-low")
        #expect(state.providers[0].thinkingSelections["gemini-3.1-pro"] == "gemini-3.1-pro-low")
    }
    @Test func failedPreferenceSaveKeepsOldRouteAndSelection() throws {
        let settings = settings()
        let state = AppState(repository: ThinkingSettings(settings: settings, failsSaving: true), vault: try vault(settings))
        state.chooseThinking(.low, providerID: settings.providers[0].id, groupID: "gemini-3.1-pro")
        #expect(state.settings == settings)
        #expect(state.error == "Save failure")
    }
    @Test func unlistedThinkingCannotChangeSelectionOrSendARequest() async throws {
        let settings = settings(), transport = ThinkingTransport()
        let state = AppState(repository: ThinkingSettings(settings: settings), vault: try vault(settings), client: AIClient(transport: transport))
        state.chooseThinking(.medium, providerID: settings.providers[0].id, groupID: "gemini-3.1-pro")
        #expect(state.settings == settings)
        #expect(state.chatGroup?.thinkingOptions == [.low, .high])
        #expect(await transport.requests.isEmpty)
    }
    @Test func transformUsesChosenTierAndVerifiesOnlyThatRoute() async throws {
        let settings = settings(), transport = ThinkingTransport()
        let state = AppState(repository: ThinkingSettings(settings: settings), vault: try vault(settings), client: AIClient(transport: transport))
        state.chooseThinking(.low, providerID: settings.providers[0].id, groupID: "gemini-3.1-pro")
        state.transcript = "原文"; state.transform()
        for _ in 0..<100 {
            if !state.isProcessing { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!state.isProcessing && state.error == nil)
        #expect(state.transcript == "原文" && state.transformedText == "润色结果")
        let request = try #require(await transport.requests.first)
        let body = try #require(try JSONSerialization.jsonObject(with: request.httpBody!) as? [String: Any])
        #expect(body["model"] as? String == "gemini-3.1-pro-low")
        #expect(state.providers[0].models.first { $0.id == "gemini-3.1-pro-low" }?.verifiedAt != nil)
        #expect(state.providers[0].models.first { $0.id == "gemini-3.1-pro-high" }?.verifiedAt == nil)
    }
}
