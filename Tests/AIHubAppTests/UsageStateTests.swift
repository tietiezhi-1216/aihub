import Foundation
import Testing
import AIHubCore
import AIHubSDK
@testable import AIHub

private struct UsageSettings: SettingsPersistence {
    var settings: AppSettings
    var fail = false
    func load() throws -> AppSettings { settings }
    func save(_ settings: AppSettings) throws { if fail { throw HubError("保存失败") } }
}
private struct UsageVault: CredentialVault {
    func read(_ providerID: UUID) throws -> String? { "fake-key" }
    func set(_ key: String, for providerID: UUID) throws { throw HubError("Unexpected key write") }
    func delete(_ providerID: UUID) throws { throw HubError("Unexpected key deletion") }
}
private actor UsageTransport: HTTPTransport {
    var requests: [URLRequest] = []
    let fail: Bool
    let delay: Bool
    init(fail: Bool = false, delay: Bool = false) { self.fail = fail; self.delay = delay }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        if delay { try await Task.sleep(for: .seconds(30)) }
        let data = Data(#"{"id":"mock","object":"chat.completion","created":1,"model":"gpt-test","choices":[{"index":0,"message":{"role":"assistant","content":"完整结果"},"finish_reason":"stop"}],"usage":{"prompt_tokens":100,"completion_tokens":50,"prompt_tokens_details":{"cached_tokens":0},"completion_tokens_details":{"reasoning_tokens":0}}}"#.utf8)
        return (data, HTTPURLResponse(url: request.url!, statusCode: fail ? 429 : 200, httpVersion: nil, headerFields: nil)!)
    }
}
@MainActor struct UsageStateTests {
    private func settings(record: Bool = false, backend: TextBackend = .builtIn) -> AppSettings {
        var provider = Provider(name: "测试", baseURL: "https://api.openai.com/v1", textBackend: backend)
        var model = ModelCatalog.model(id: "gpt-test", entry: ["thinking": true, "reasoning": ["supported_efforts": ["low", "high"]]])
        model.metadata.tasks = [.textGeneration, .transcription]
        model.price = PriceSchedule(id: "version1", evidence: .init(.user, source: "用户"), rules: [.init(.inputTokens, amount: 1, per: 100), .init(.outputTokens, amount: 2, per: 100)])
        provider.models = [model]
        var settings = AppSettings(); settings.providers = [provider]; settings.chatSelection = .init(providerID: provider.id, modelID: model.id)
        settings.recordsUsage = record
        return settings
    }
    private func wait(_ state: AppState) async throws {
        for _ in 0..<500 {
            if !state.isProcessing { return }
            try await Task.sleep(for: .milliseconds(2))
        }
        throw HubError("Timed out")
    }
    @Test(arguments: TextBackend.allCases) func successfulTextCollectsCountsButOnlyPersistsWithConsent(_ backend: TextBackend) async throws {
        for enabled in [false, true] {
            let transport = UsageTransport(), settings = settings(record: enabled, backend: backend)
            let state = AppState(repository: UsageSettings(settings: settings), vault: UsageVault(), client: AIClient(transport: transport, textBackend: SwiftAITextBackend(transport: transport)))
            state.transcript = "原文"; state.transform(); try await wait(state)
            #expect(state.transcript == "原文" && state.transformedText == "完整结果")
            #expect(state.lastTextUsage?.usage.input == 100 && state.lastTextUsage?.estimatedAmount == 2)
            #expect(state.settings.usageRecords.count == (enabled ? 1 : 0))
            #expect(await transport.requests.count == 1)
            if enabled {
                #expect(state.settings.priceSnapshots["version1"] != nil)
                let text = String(decoding: try JSONEncoder().encode(state.settings), as: UTF8.self)
                #expect(!text.contains("原文") && !text.contains("完整结果") && !text.contains("fake-key"))
            }
        }
    }
    @Test func choosingParametersInvalidatesTextNotASRAndSavingFailureRollsBack() {
        var settings = settings()
        settings.providers[0].models[0].verify(task: .transcription, api: .openAIChat, backend: .builtIn)
        settings.providers[0].models[0].verify(task: .textGeneration, api: .openAIChat, backend: .builtIn)
        let state = AppState(repository: UsageSettings(settings: settings), vault: UsageVault())
        state.chooseReasoning(.init(effort: "high"), outputLimit: 4096, providerID: settings.providers[0].id, modelID: "gpt-test")
        #expect(state.providers[0].models[0].reasoningSelection?.effort == "high")
        #expect(state.providers[0].models[0].verifications.map(\.task) == [.transcription])
        let failed = AppState(repository: UsageSettings(settings: settings, fail: true), vault: UsageVault())
        failed.chooseReasoning(.init(effort: "high"), outputLimit: 4096, providerID: settings.providers[0].id, modelID: "gpt-test")
        #expect(failed.settings == settings && failed.error != nil)
    }
    @Test func invalidParameterSelectionCannotChangeConfigurationOrOriginalText() {
        let settings = settings(), state = AppState(repository: UsageSettings(settings: settings), vault: UsageVault())
        state.transcript = "原文"
        state.chooseReasoning(.init(effort: "medium"), outputLimit: 4096, providerID: settings.providers[0].id, modelID: "gpt-test")
        #expect(state.settings == settings && state.transcript == "原文" && state.error != nil)
    }
    @Test func withdrawnThinkingBlocksPipelineBeforeAnyAudioUpload() async throws {
        var settings = settings(record: true)
        settings.providers[0].models[0].reasoningSelection = .init(effort: "medium")
        settings.speechSelection = settings.chatSelection
        let transport = UsageTransport()
        let state = AppState(repository: UsageSettings(settings: settings), vault: UsageVault(), client: AIClient(transport: transport))
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("AIHub-usage-\(UUID()).wav")
        try Data([0, 1, 2, 3]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        try state.loadAudio(url); state.transcript = "原文"; state.transcribe(polish: true)
        #expect(!state.isProcessing && state.error?.contains("思考") == true && state.transcript == "原文")
        #expect(await transport.requests.isEmpty && state.settings.usageRecords.isEmpty)
    }
    @Test func failedLedgerSaveNeverLosesGeneratedTextOrOriginal() async throws {
        let state = AppState(repository: UsageSettings(settings: settings(record: true), fail: true), vault: UsageVault(), client: AIClient(transport: UsageTransport()))
        state.transcript = "原文"; state.transform(); try await wait(state)
        #expect(state.transformedText == "完整结果" && state.transcript == "原文")
        #expect(state.lastTextUsage?.usage.input == 100 && state.settings.usageRecords.isEmpty && state.error != nil)
    }
    @Test func failedAndCancelledCallsAreNotClaimedAsSuccessfulOrFree() async throws {
        let limited = UsageTransport(fail: true)
        let state = AppState(repository: UsageSettings(settings: settings(record: true)), vault: UsageVault(), client: AIClient(transport: limited))
        state.transcript = "原文"; state.transform(); try await wait(state)
        #expect(state.settings.usageRecords.isEmpty && state.lastTextUsage == nil && state.transcript == "原文")
        #expect(await limited.requests.count == 1)
        let delayed = UsageTransport(delay: true)
        let cancelled = AppState(repository: UsageSettings(settings: settings(record: true)), vault: UsageVault(), client: AIClient(transport: delayed))
        cancelled.transcript = "原文"; cancelled.transform()
        for _ in 0..<500 { if await !delayed.requests.isEmpty { break }; try await Task.sleep(for: .milliseconds(2)) }
        cancelled.cancelOperation(); try await wait(cancelled)
        #expect(cancelled.settings.usageRecords.isEmpty && cancelled.lastTextUsage == nil && cancelled.transcript == "原文")
    }
    @Test func disablingRecordingKeepsOldRowsAndExplicitClearRemovesThem() async throws {
        let state = AppState(repository: UsageSettings(settings: settings(record: true)), vault: UsageVault(), client: AIClient(transport: UsageTransport()))
        state.transcript = "原文"; state.transform(); try await wait(state)
        state.setRecordsUsage(false)
        #expect(state.settings.usageRecords.count == 1 && !state.settings.recordsUsage)
        state.transform(); try await wait(state)
        #expect(state.settings.usageRecords.count == 1)
        state.clearUsageRecords()
        #expect(state.settings.usageRecords.isEmpty && state.transcript == "原文" && state.transformedText == "完整结果")
    }
    @Test func recordsRetainOnlyNewest5000AndPreserveModelPriceVersions() async throws {
        var settings = settings(record: true)
        let result = TextGenerationResult(text: "不保存", usage: .init(input: 100, output: 50, cacheRead: 0, cacheWrite: 0, accounting: .inclusive))
        let old = UsageRecord(provider: settings.providers[0], modelID: "gpt-test", api: .openAIChat, result: result)
        settings.usageRecords = (0..<5000).map { _ in UsageRecord(provider: settings.providers[0], modelID: "gpt-test", api: .openAIChat, result: result) }
        settings.usageRecords[0] = old
        let state = AppState(repository: UsageSettings(settings: settings), vault: UsageVault(), client: AIClient(transport: UsageTransport()))
        state.transcript = "原文"; state.transform(); try await wait(state)
        #expect(state.settings.usageRecords.count == 5000 && !state.settings.usageRecords.contains { $0.id == old.id })
        #expect(state.settings.usageRecords.last?.priceSnapshotID == "version1")
    }
}
