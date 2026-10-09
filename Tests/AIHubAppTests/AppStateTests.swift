import Foundation
import Testing
import AIHubCore
import AIHubSDK
@testable import AIHub

private struct EmptyVault: CredentialVault {
    func read(_ providerID: UUID) throws -> String? { nil }
    func set(_ key: String, for providerID: UUID) throws {}
    func delete(_ providerID: UUID) throws {}
}

private struct InitialSettings: SettingsPersistence {
    let settings: AppSettings
    var failsSaving = false
    func load() throws -> AppSettings { settings }
    func save(_ settings: AppSettings) throws {
        if failsSaving { throw HubError("Save failure") }
    }
}

private struct BrokenSettings: SettingsPersistence {
    func load() throws -> AppSettings { throw HubError("Broken settings") }
    func save(_ settings: AppSettings) throws { throw HubError("Must not save") }
}

private actor AppTransport: HTTPTransport {
    var count = 0
    var requests: [URLRequest] = []
    let fail: Bool
    let delay: Duration?
    let failChat: Bool
    let delayChat: Duration?
    init(fail: Bool = false, delay: Duration? = nil, failChat: Bool = false, delayChat: Duration? = nil) {
        self.fail = fail; self.delay = delay; self.failChat = failChat; self.delayChat = delayChat
    }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        count += 1
        requests.append(request)
        let isChat = request.url?.path.hasSuffix("chat/completions") == true
        if let delay = isChat ? delayChat ?? delay : delay { try await Task.sleep(for: delay) }
        let body = request.url?.path.hasSuffix("transcriptions") == true
            ? #"{"text":"识别原文"}"#
            : #"{"id":"chat_mock","object":"chat.completion","created":1,"model":"gpt-4o-mini","choices":[{"index":0,"message":{"role":"assistant","content":"转换结果"},"finish_reason":"stop"}],"usage":{"prompt_tokens":4,"completion_tokens":2,"total_tokens":6}}"#
        let response = HTTPURLResponse(url: request.url!, statusCode: fail || isChat && failChat ? 500 : 200, httpVersion: nil, headerFields: nil)!
        return (Data(body.utf8), response)
    }
}

@MainActor
struct AppStateTests {
    private func makeSettings(backend: TextBackend = .builtIn) -> AppSettings {
        let provider = Provider(name: "Test", kind: .compatible, baseURL: "http://localhost:8000/v1",
                                requiresAPIKey: false, models: [AIModel(id: "whisper-1"), AIModel(id: "gpt-4o-mini")], textBackend: backend)
        var settings = AppSettings()
        settings.providers = [provider]
        settings.speechSelection = .init(providerID: provider.id, modelID: "whisper-1")
        settings.chatSelection = .init(providerID: provider.id, modelID: "gpt-4o-mini")
        return settings
    }

    private func audioFile() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-app-tests-\(UUID()).wav")
        try Data([0, 1, 2, 3]).write(to: url)
        return url
    }

    private func awaitFinished(_ state: AppState) async throws {
        for _ in 0..<500 {
            if !state.isProcessing { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw HubError("Timed out waiting for operation")
    }

    @Test func importDoesNotUploadAndDiscardDoesNotDeleteOriginal() async throws {
        let transport = AppTransport()
        let state = AppState(repository: InitialSettings(settings: makeSettings()), vault: EmptyVault(), client: AIClient(transport: transport))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        #expect(state.audioURL == audio)
        #expect(await transport.count == 0)
        state.discardAudio()
        #expect(!state.hasAudio)
        #expect(FileManager.default.fileExists(atPath: audio.path))
    }

    @Test func speechCompletesAndMarksOnlyInvokedModelVerified() async throws {
        let state = AppState(repository: InitialSettings(settings: makeSettings()), vault: EmptyVault(), client: AIClient(transport: AppTransport()))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        state.transcribe()
        #expect(state.isProcessing)
        try await awaitFinished(state)
        #expect(state.transcript == "识别原文")
        #expect(state.lastTranscription == "识别原文")
        #expect(state.hasAudio)
        #expect(state.providers.first?.speechModels.first?.verifiedAt != nil)
        #expect(state.providers.first?.chatModels.first?.verifiedAt == nil)
    }

    @Test func failurePreservesTextAndAudioForRetry() async throws {
        let state = AppState(repository: InitialSettings(settings: makeSettings()), vault: EmptyVault(), client: AIClient(transport: AppTransport(fail: true)))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        state.transcript = "已有文字"
        state.transcribe()
        try await awaitFinished(state)
        #expect(state.transcript == "已有文字")
        #expect(state.hasAudio)
        #expect(state.error != nil)
        #expect(state.providers.first?.speechModels.first?.verifiedAt == nil)
    }

    @Test func cancellationNeverOverwritesText() async throws {
        let transport = AppTransport(delay: .seconds(2))
        let state = AppState(repository: InitialSettings(settings: makeSettings()), vault: EmptyVault(), client: AIClient(transport: transport))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        state.transcript = "保留原文"
        state.transcribe()
        try await Task.sleep(for: .milliseconds(50))
        state.cancelOperation()
        try await Task.sleep(for: .milliseconds(50))
        #expect(!state.isProcessing)
        #expect(state.transcript == "保留原文")
        #expect(state.error == nil)
        #expect(state.hasAudio)
    }

    @Test func transformKeepsOriginalText() async throws {
        let state = AppState(repository: InitialSettings(settings: makeSettings()), vault: EmptyVault(), client: AIClient(transport: AppTransport()))
        state.transcript = "原始口述"
        state.transform()
        try await awaitFinished(state)
        #expect(state.transcript == "原始口述")
        #expect(state.transformedText == "转换结果")
        #expect(state.providers.first?.chatModels.first?.verifiedAt != nil)
    }

    @Test(arguments: TextBackend.allCases) func pipelineSendsASRTextToLLMAndPreservesOriginal(_ backend: TextBackend) async throws {
        let transport = AppTransport()
        var settings = makeSettings(backend: backend); settings.recordsUsage = true
        let state = AppState(repository: InitialSettings(settings: settings), vault: EmptyVault(), client: AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport)))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        state.transcribe(polish: true)
        try await awaitFinished(state)
        #expect(state.transcript == "识别原文" && state.lastTranscription == "识别原文")
        #expect(state.transformedText == "转换结果")
        #expect(state.settings.usageRecords.count == 1 && state.settings.usageRecords[0].usage.input == 4)
        #expect(state.providers.first?.speechModels.first?.verifiedAt != nil)
        #expect(state.providers.first?.chatModels.first?.verifiedAt != nil)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/v1/audio/transcriptions", "/v1/chat/completions"])
        let body = try #require(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        let messages = try #require(body["messages"] as? [[String: String]])
        #expect(messages.last?["content"] == "识别原文")
        #expect(messages.first?["content"] == TransformMode.polish.instruction)
        #expect(body["audio"] == nil && body["file"] == nil)
    }

    @Test(arguments: TextBackend.allCases) func llmFailureKeepsSuccessfulASRAndAllowsManualRetry(_ backend: TextBackend) async throws {
        let transport = AppTransport(failChat: true)
        var settings = makeSettings(backend: backend); settings.recordsUsage = true
        let state = AppState(repository: InitialSettings(settings: settings), vault: EmptyVault(), client: AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport)))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        state.transcribe(polish: true)
        try await awaitFinished(state)
        #expect(state.transcript == "识别原文" && state.lastTranscription == "识别原文")
        #expect(state.transformedText.isEmpty && state.hasAudio)
        #expect(state.settings.usageRecords.isEmpty && state.lastTextUsage == nil)
        #expect(state.error?.contains("文字生成") == true)
        #expect(state.providers.first?.speechModels.first?.verifiedAt != nil)
        #expect(state.providers.first?.chatModels.first?.verifiedAt == nil)
        state.transform()
        try await awaitFinished(state)
        #expect(await transport.count == 3) // Retrying LLM must not upload audio again.
        #expect(state.transcript == "识别原文")
    }

    @Test(arguments: TextBackend.allCases) func cancellingLLMDoesNotDiscardASR(_ backend: TextBackend) async throws {
        let transport = AppTransport(delayChat: .seconds(2))
        var settings = makeSettings(backend: backend); settings.recordsUsage = true
        let state = AppState(repository: InitialSettings(settings: settings), vault: EmptyVault(), client: AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport)))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        state.transcribe(polish: true)
        for _ in 0..<100 {
            if state.lastTranscription != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(state.transcript == "识别原文")
        #expect(state.operationLabel.contains("LLM"))
        state.cancelOperation()
        try await Task.sleep(for: .milliseconds(30))
        #expect(!state.isProcessing && state.transcript == "识别原文")
        #expect(state.transformedText.isEmpty && state.error == nil)
        #expect(state.settings.usageRecords.isEmpty && state.lastTextUsage == nil)
        #expect(state.providers.first?.chatModels.first?.verifiedAt == nil)
    }

    @Test func pipelineRequiresLLMSelectionBeforeUploading() async throws {
        var settings = makeSettings(); settings.chatSelection = nil
        let transport = AppTransport()
        let state = AppState(repository: InitialSettings(settings: settings), vault: EmptyVault(), client: AIClient(transport: transport))
        let audio = try audioFile()
        defer { try? FileManager.default.removeItem(at: audio) }
        try state.loadAudio(audio)
        state.transcribe(polish: true)
        #expect(!state.isProcessing && state.error?.contains("LLM") == true)
        #expect(await transport.count == 0)
    }

    @Test func corruptConfigurationBlocksSaving() {
        let state = AppState(repository: BrokenSettings(), vault: EmptyVault())
        #expect(!state.configurationReady)
        #expect(state.error == "Broken settings")
        #expect(throws: HubError.self) {
            try state.saveProvider(makeSettings().providers[0], key: nil)
        }
    }

    @Test func failedSelectionSaveLeavesPreviousChoice() {
        let settings = makeSettings()
        let state = AppState(repository: InitialSettings(settings: settings, failsSaving: true), vault: EmptyVault())
        state.chooseSpeech(nil)
        #expect(state.settings.speechSelection == settings.speechSelection)
        #expect(state.error == "Save failure")
    }
}
