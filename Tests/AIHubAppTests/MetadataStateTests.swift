import Foundation
import Testing
import AIHubCore
@testable import AIHub

private struct MetadataSettings: SettingsPersistence {
    var settings: AppSettings
    var failsSaving = false
    func load() throws -> AppSettings { settings }
    func save(_ settings: AppSettings) throws { if failsSaving { throw HubError("保存失败") } }
}
private struct MetadataVault: CredentialVault {
    func read(_ providerID: UUID) throws -> String? { "existing-key" }
    func set(_ key: String, for providerID: UUID) throws { throw HubError("Must not write credentials") }
    func delete(_ providerID: UUID) throws { throw HubError("Must not delete credentials") }
}
private actor MetadataTransport: HTTPTransport {
    var requests: [URLRequest] = []
    var status: Int
    var delay: Bool
    init(status: Int = 200, delay: Bool = false) { self.status = status; self.delay = delay }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay { try await Task.sleep(for: .seconds(30)) }
        let fixture = #"{"openai":{"models":{"gpt-test":{"name":"GPT","reasoning":true,"reasoning_options":[{"type":"effort","values":["low","high"]}],"modalities":{"input":["text"],"output":["text"]},"cost":{"input":2,"output":8}}}}}"#
        return (Data((status == 200 ? fixture : "PRIVATE_UPSTREAM_SECRET").utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor struct MetadataStateTests {
    private func initial() -> AppSettings {
        var settings = AppSettings()
        settings.providers = [Provider(name: "OpenAI", baseURL: "https://api.openai.com/v1", models: [AIModel(id: "gpt-test"), AIModel(id: "whisper-1")])]
        settings.chatSelection = .init(providerID: settings.providers[0].id, modelID: "gpt-test")
        return settings
    }
    private func wait(_ state: AppState) async throws {
        for _ in 0..<500 {
            if !state.isUpdatingMetadata { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HubError("Metadata update timed out")
    }
    @Test func protocolOverrideIsPerModelAndDefaultRestoresServiceDeclaration() {
        var settings = initial()
        settings.providers[0].models[0].metadata.bindings = [.init(task: .textGeneration, apiProtocol: .openAIResponses, evidence: .init(.service, source: "服务"))]
        let state = AppState(repository: MetadataSettings(settings: settings), vault: MetadataVault())
        let id = settings.providers[0].id
        state.chooseModelProtocol(.openAIChat, providerID: id, modelID: "gpt-test")
        #expect(state.providers[0].binding(for: state.providers[0].models[0], task: .textGeneration)?.apiProtocol == .openAIChat)
        #expect(state.providers[0].effectiveProtocol == .openAIChat && state.providers[0].models[1] == settings.providers[0].models[1])
        state.chooseModelProtocol(.automatic, providerID: id, modelID: "gpt-test")
        #expect(state.providers[0].binding(for: state.providers[0].models[0], task: .textGeneration)?.apiProtocol == .openAIResponses)
    }
    @Test func protocolChangeInvalidatesOnlyMatchingTextVerificationAndSaveFailureRollsBack() {
        var settings = initial()
        settings.providers[0].models[0].metadata.tasks = [.textGeneration, .transcription]
        settings.providers[0].models[0].verify(task: .transcription, api: .openAIChat, backend: .builtIn)
        settings.providers[0].models[0].verify(task: .textGeneration, api: .openAIChat, backend: .swiftAI)
        let state = AppState(repository: MetadataSettings(settings: settings), vault: MetadataVault())
        state.chooseModelProtocol(.openAIResponses, providerID: settings.providers[0].id, modelID: "gpt-test")
        #expect(state.providers[0].models[0].verifications.map(\.task) == [.transcription])
        let failed = AppState(repository: MetadataSettings(settings: settings, failsSaving: true), vault: MetadataVault())
        failed.chooseModelProtocol(.openAIResponses, providerID: settings.providers[0].id, modelID: "gpt-test")
        #expect(failed.settings == settings && failed.error != nil)
    }
    @Test func publicUpdateNeverTouchesCredentialsOriginalTextOrBackend() async throws {
        let settings = initial(), transport = MetadataTransport()
        let state = AppState(repository: MetadataSettings(settings: settings), vault: MetadataVault(), metadataClient: PublicRegistryClient(transport: transport))
        state.transcript = "用户原文"; state.transformedText = "已整理文字"
        state.updatePublicMetadata(); try await wait(state)
        #expect(state.error == nil && state.providers[0].models[0].metadata.reasoning.efforts == ["low", "high"])
        #expect(state.providers[0].models[0].price != nil && state.providers[0].textBackend == .builtIn)
        #expect(state.transcript == "用户原文" && state.transformedText == "已整理文字")
        let requests = await transport.requests
        #expect(requests.count == 1 && requests[0].httpBody == nil && requests[0].value(forHTTPHeaderField: "Authorization") == nil)
    }
    @Test func failedUpdateLeavesCurrentCatalogAndDraftUntouched() async throws {
        let settings = initial(), transport = MetadataTransport(status: 429)
        let state = AppState(repository: MetadataSettings(settings: settings), vault: MetadataVault(), metadataClient: PublicRegistryClient(transport: transport))
        state.transcript = "保留原文"
        state.updatePublicMetadata(); try await wait(state)
        #expect(state.settings == settings && state.transcript == "保留原文" && state.publicRegistry == nil)
        #expect(state.error?.contains("PRIVATE_UPSTREAM_SECRET") == false && state.error?.contains("429") == true)
        #expect(await transport.requests.count == 1)
    }
    @Test func cancelledUpdateDoesNotModifyConfiguration() async throws {
        let settings = initial(), transport = MetadataTransport(delay: true)
        let state = AppState(repository: MetadataSettings(settings: settings), vault: MetadataVault(), metadataClient: PublicRegistryClient(transport: transport))
        state.updatePublicMetadata()
        for _ in 0..<1000 { if await !transport.requests.isEmpty { break }; await Task.yield() }
        state.cancelMetadataUpdate(); try await wait(state)
        #expect(state.settings == settings && state.publicRegistry == nil && state.error == nil)
        #expect(await transport.requests.count == 1)
    }
}
