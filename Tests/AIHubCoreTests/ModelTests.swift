import Foundation
import Testing
@testable import AIHubCore

struct ModelTests {
    @Test(arguments: [
        "whisper-1", "whisper-large-v3-turbo", "gpt-4o-transcribe", "gpt-4o-mini-transcribe",
        "FunAudioLLM/SenseVoiceSmall", "TeleAI/TeleSpeechASR", "vendor/model-asr", "vendor/stt-large"
    ])
    func identifiesSpeech(_ id: String) { #expect(ModelClassifier.classify(id) == .transcription) }

    @Test(arguments: [
        "gpt-4o", "gpt-4o-mini", "llama-3.3-70b-versatile",
        "Qwen/Qwen3-8B", "deepseek-ai/DeepSeek-V3", "mimo-v2.5-pro"
    ])
    func identifiesChat(_ id: String) { #expect(ModelClassifier.classify(id) == .chat) }

    @Test(arguments: [
        ("gpt-4o-mini-tts", ModelCapability.speechSynthesis), ("gpt-4o-transcribe-diarize", .transcription),
        ("gpt-image-1", .image), ("text-embedding-3-large", .embedding), ("bge-reranker-v2", .rerank),
        ("gpt-4o-realtime-preview", .audio), ("gpt-4o-audio-preview", .audio), ("gpt-5-codex", .chat),
        ("flux-1", .image), ("imagen-4.0-generate-001", .image), ("veo-3.1-generate-preview", .video),
        ("sora-2", .video), ("Wan-AI/Wan2.2-T2V", .video), ("CosyVoice2-0.5B", .speechSynthesis)
    ])
    func classifiesCatalogIndependentlyOfInvocation(_ id: String, _ capability: ModelCapability) {
        #expect(ModelClassifier.classify(id) == capability)
    }

    @Test(arguments: ["agnes-2.0-flash", "imagine-chat", "random-model", "speech-magic"])
    func unknownIsNotAssumedChat(_ id: String) { #expect(ModelClassifier.classify(id) == .unknown) }

    @Test func mergePreservesOverridesAndManualModelsButDropsStaleDiscovery() {
        var overridden = AIModel(id: "random-model", capability: .transcription)
        overridden.verifiedAt = Date(timeIntervalSince1970: 123)
        let manual = AIModel(id: "my-private-model", capability: .transcription, source: .manual)
        var provider = Provider(name: "Test", kind: .compatible, baseURL: "https://example.com/v1",
                                models: [overridden, manual, AIModel(id: "stale-discovered")])
        provider.mergeDiscovered([AIModel(id: "random-model"), AIModel(id: "whisper-1")])
        #expect(provider.models.count == 3)
        #expect(provider.models.first { $0.id == "random-model" }?.capability == .transcription)
        #expect(provider.models.first { $0.id == "random-model" }?.verifiedAt == overridden.verifiedAt)
        #expect(provider.models.contains { $0.id == manual.id && $0.source == .manual })
        #expect(!provider.models.contains { $0.id == "stale-discovered" })
        #expect(provider.discoveredAt != nil)
    }

    @Test func manuallyAddedModelRemainsManualAfterDiscoveryAndRemovalFromCatalog() {
        var provider = Provider(name: "Manual", baseURL: "https://example.com/v1",
                                models: [AIModel(id: "custom-model", capability: .chat, source: .manual)])
        provider.mergeDiscovered([AIModel(id: "custom-model")])
        #expect(provider.models.first?.source == .manual)
        provider.mergeDiscovered([])
        #expect(provider.models.first?.id == "custom-model")
    }

    @Test func protocolChangeClearsUnsupportedSpeechSelection() {
        let provider = Provider(name: "Messages", baseURL: "https://example.com/v1",
                                models: [AIModel(id: "whisper-1")], apiProtocol: .anthropic)
        var settings = AppSettings()
        settings.providers = [provider]
        settings.speechSelection = .init(providerID: provider.id, modelID: "whisper-1")
        settings.reconcileSelections()
        #expect(settings.speechSelection == nil)
    }

    @Test func selectionReconciliation() {
        let provider = Provider(name: "A", kind: .openAI, baseURL: ProviderKind.openAI.defaultURL,
                                models: [AIModel(id: "whisper-1"), AIModel(id: "gpt-4o")])
        var settings = AppSettings()
        settings.providers = [provider]
        settings.speechSelection = .init(providerID: provider.id, modelID: "whisper-1")
        settings.chatSelection = .init(providerID: provider.id, modelID: "whisper-1")
        settings.reconcileSelections()
        #expect(settings.speechSelection != nil)
        #expect(settings.chatSelection == nil)
        settings.providers = []
        settings.reconcileSelections()
        #expect(settings.speechSelection == nil)
    }

    @Test func noVerificationByDiscoveryOrManualAddition() {
        #expect(AIModel(id: "whisper-1").verifiedAt == nil)
        #expect(AIModel(id: "private", capability: .transcription, source: .manual).status.contains("未验证"))
    }

    @Test(arguments: ["", "   ", "model\nInjected", String(repeating: "a", count: 257)])
    func invalidModelID(_ value: String) { #expect(throws: HubError.self) { try Validation.modelID(value) } }

    @Test func keyRejectsHeaderInjection() throws {
        #expect(throws: HubError.self) { try Validation.apiKey("key\r\nAuthorization: evil") }
        #expect(try Validation.apiKey("  test-key  ") == "test-key")
    }
}
