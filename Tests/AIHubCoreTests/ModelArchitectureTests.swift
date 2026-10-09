import Foundation
import Testing
@testable import AIHubCore

struct ModelArchitectureTests {
    @Test func versionOneMigratesWithoutChangingConnectionOrKeyReference() throws {
        let id = UUID()
        let data = Data("""
        {"version":1,"providers":[{"id":"\(id)","name":"原渠道","baseURL":"https://api.openai.com/v1","models":[{"id":"gpt-test","capability":"chat","source":"manual"}],"thinkingSelections":{}}],"chatSelection":{"providerID":"\(id)","modelID":"gpt-test"},"language":"zh","vocabulary":"专有名词"}
        """.utf8)
        var settings = try JSONDecoder().decode(AppSettings.self, from: data)
        settings.reconcileSelections()
        let provider = try #require(settings.providers.first)
        #expect(settings.version == 3 && provider.id == id && provider.connection.credentialReference == id)
        #expect(provider.textBackend == .builtIn && provider.models[0].source == .manual)
        #expect(settings.chatSelection?.modelID == "gpt-test" && settings.vocabulary == "专有名词")
        let encoded = try JSONEncoder().encode(settings)
        let json = try #require(try JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        let saved = try #require((json["providers"] as? [[String: Any]])?.first)
        #expect(saved["connection"] != nil && saved["catalog"] != nil && saved["baseURL"] == nil)
        #expect(try JSONDecoder().decode(AppSettings.self, from: encoded) == settings)
    }
    @Test func sharedIDIsNotSharedChannelIdentity() {
        let model = AIModel(id: "same-model")
        let a = Provider(name: "A", baseURL: "https://a.example/v1", models: [model])
        let b = Provider(name: "B", baseURL: "https://b.example/v1", models: [model])
        #expect(a.offeringIdentity(model) != b.offeringIdentity(model))
        #expect(a.models[0].definition == nil && b.models[0].definition == nil)
    }
    @Test func tasksAndModalitiesAreIndependentAndNonTextAdaptersStayUnavailable() {
        let model = ModelCatalog.model(id: "new-model", entry: ["input_modalities": ["text", "image"], "output_modalities": ["text", "image"]])
        #expect(Set(model.tasks) == [.textGeneration, .imageGeneration])
        let provider = Provider(name: "API", baseURL: "https://example.com/v1", models: [model])
        #expect(provider.chatModels.count == 1 && provider.binding(for: model, task: .imageGeneration) == nil)
        #expect(ModelCatalog.matches(model, category: .chat, search: ""))
        let vision = ModelCatalog.model(id: "vision", entry: ["input_modalities": ["text", "image"], "output_modalities": ["text"]])
        #expect(!vision.tasks.contains(.imageGeneration))
    }
    @Test func textToAudioAloneDoesNotClaimSpeechSynthesis() {
        let model = ModelCatalog.model(id: "music-new", entry: ["input_modalities": ["text"], "output_modalities": ["audio"]])
        #expect(model.tasks == [.audioGeneration] && !model.tasks.contains(.speechSynthesis))
        let tts = ModelCatalog.model(id: "known-tts", entry: ["input_modalities": ["text"], "output_modalities": ["audio"]])
        #expect(tts.tasks == [.speechSynthesis])
    }
    @Test func explicitASRDescriptionIsNotConvertedToLLMByTextOutput() {
        let model = ModelCatalog.model(id: "unknown-speech", entry: ["tasks": ["transcription"], "input_modalities": ["audio"], "output_modalities": ["text"]])
        #expect(model.tasks == [.transcription] && !model.supportsTextOutput)
    }
    @Test func anthropicCapabilitiesKeepModesAndEffortsSeparate() {
        let model = ModelCatalog.model(id: "claude-test", entry: [
            "max_input_tokens": 200_000, "max_tokens": 4096,
            "capabilities": ["image_input": ["supported": true], "pdf_input": ["supported": true],
                "thinking": ["supported": true, "types": ["adaptive": ["supported": true], "enabled": ["supported": false]]],
                "effort": ["supported": true, "low": ["supported": true], "high": ["supported": true], "medium": ["supported": false]]]
        ])
        #expect(model.inputModalities == [.image, .document])
        #expect(model.metadata.reasoning.modes == ["adaptive"])
        #expect(Set(model.metadata.reasoning.efforts) == ["low", "high"])
        #expect(model.metadata.limits.input == 200_000 && model.metadata.reasoning.evidence?.origin == .service)
    }
    @Test func explicitThinkingFalseWinsOverOptionalFieldsAndInvalidBudgetsAreNotOffered() {
        let denied = ModelCatalog.model(id: "test", entry: ["supportsThinking": false, "minThinkingBudget": 32, "reasoning": ["supported_efforts": ["high"]]])
        #expect(denied.metadata.reasoning.support == .unsupported && denied.metadata.reasoning.efforts.isEmpty)
        let invalid = ModelCatalog.model(id: "test", entry: ["supportsThinking": true, "minThinkingBudget": 100, "maxThinkingBudget": 32])
        #expect(!invalid.metadata.reasoning.supportsBudget)
        #expect(ModelCatalog.positiveInt(true) == nil && ModelCatalog.positiveInt(1.5) == nil)
    }
    @Test func openRouterMetadataIsReadWithoutInventingGenerationSupport() throws {
        let provider = Provider(name: "Router", baseURL: "https://openrouter.ai/api/v1")
        let page = try ProtocolAdapter.modelPage(data: Data(#"{"data":[{"id":"lab/custom","architecture":{"input_modalities":["text","image"],"output_modalities":["text"]},"reasoning":{"supported_efforts":["low","high"],"mandatory":true},"pricing":{"prompt":"0.000002","completion":"0.000008"},"context_length":65536}]}"#.utf8), protocol: .openAIChat, provider: provider)
        let model = try #require(page.models.first)
        #expect(model.isMultimodal && model.metadata.reasoning.efforts == ["low", "high"])
        #expect(model.metadata.reasoning.mandatory == true && model.metadata.limits.context == 65536)
        #expect(model.price?.rules.first?.quantity == 1 && model.verifiedAt == nil)
    }
    @Test func freshMetadataTimestampsDoNotInvalidateButChangedCapabilitiesDo() {
        let a = ModelCatalog.model(id: "gpt-test", entry: ["thinking": true], fetchedAt: Date(timeIntervalSince1970: 1))
        let b = ModelCatalog.model(id: "gpt-test", entry: ["thinking": true], fetchedAt: Date(timeIntervalSince1970: 2))
        #expect(a.hasSameExecutionDescription(as: b))
        var old = a; old.verify(task: .textGeneration, api: .openAIChat, backend: .builtIn)
        var provider = Provider(name: "API", baseURL: "https://example.com/v1", models: [old])
        provider.mergeDiscovered([b]); #expect(provider.models[0].verifications.count == 1)
        provider.mergeDiscovered([ModelCatalog.model(id: "gpt-test", entry: ["thinking": false])])
        #expect(provider.models[0].verifications.isEmpty && provider.models[0].verifiedAt == nil)
    }
    @Test func publicRegistryEnrichesOnlyExactOfficialConnectionAndNeverSubscriptionOrUnknownGateway() throws {
        let registry = try sampleRegistry()
        let models = [ModelCatalog.model(id: "gemini-test", entry: [:])]
        let google = Provider(name: "API", baseURL: "https://generativelanguage.googleapis.com/v1beta", apiProtocol: .gemini)
        let enriched = registry.enrich(models, for: google)
        #expect(enriched[0].metadata.reasoning.efforts == ["low", "high"] && enriched[0].price != nil)
        #expect(enriched[0].verifiedAt == nil && enriched[0].definition?.developer?.name == "Google")
        var account = Provider(name: "", baseURL: ""); account.selectChannel(.antigravity)
        let gateway = Provider(name: "未知中转", baseURL: "https://unknown.example/v1")
        #expect(registry.enrich(models, for: account) == models && registry.enrich(models, for: gateway) == models)
        #expect(registry.enrich([AIModel(id: "gemini-test-high")], for: google)[0].definition == nil)
    }
    @Test func serviceRestrictionsAndManualTasksWinOverPublicReferences() throws {
        let registry = try sampleRegistry()
        let provider = Provider(name: "API", baseURL: "https://generativelanguage.googleapis.com/v1beta", apiProtocol: .gemini)
        var model = ModelCatalog.model(id: "gemini-test", entry: ["thinking": false, "input_modalities": ["text"], "output_modalities": ["audio"], "inputTokenLimit": 100])
        model.classify(.speechSynthesis)
        let enriched = registry.enrich([model], for: provider)[0]
        #expect(enriched.metadata.reasoning.support == .unsupported)
        #expect(enriched.inputModalities == [.text] && enriched.outputModalities == [.audio])
        #expect(enriched.tasks == [.speechSynthesis] && !enriched.supportsTextOutput && enriched.metadata.limits.input == 100)
    }
    @Test func manualBindingsSurviveRefreshAndDoNotChangeAuthenticationBoundary() {
        var model = AIModel(id: "gpt-test")
        model.metadata.bindings = [.init(task: .textGeneration, apiProtocol: .openAIResponses, evidence: .init(.user, source: "用户"))]
        var provider = Provider(name: "API", baseURL: "https://example.com/v1", models: [model])
        provider.mergeDiscovered([AIModel(id: "gpt-test")])
        #expect(provider.binding(for: provider.models[0], task: .textGeneration)?.apiProtocol == .openAIResponses)
        provider.apiProtocol = .anthropic
        #expect(provider.binding(for: provider.models[0], task: .textGeneration) == nil)
    }
    @Test func listingBothOpenAIProtocolsKeepsTheConfiguredDefault() {
        let model = ModelCatalog.model(id: "gpt-test", entry: ["supported_endpoints": ["responses", "chat/completions"]])
        let provider = Provider(name: "Chat", baseURL: "https://example.com/v1", models: [model])
        #expect(provider.binding(for: model, task: .textGeneration)?.apiProtocol == .openAIChat)
    }
    @Test func metadataBoundsAreValidatedOnPersistence() throws {
        var model = AIModel(id: "gpt-test")
        model.metadata.reasoning.efforts = Array(repeating: "high", count: 17)
        #expect(throws: HubError.self) { try model.validateMetadata() }
        model.metadata.reasoning.efforts = ["high\nprivate"]
        #expect(throws: HubError.self) { try model.validateMetadata() }
    }
    private func sampleRegistry() throws -> PublicModelRegistry {
        try .parse(Data(#"{"google":{"models":{"gemini-test":{"name":"Gemini","reasoning":true,"reasoning_options":[{"type":"effort","values":["low","high"]}],"modalities":{"input":["text","image"],"output":["text"]},"limit":{"context":1024,"input":512},"cost":{"input":2,"output":8}}}}}"#.utf8))
    }
}
