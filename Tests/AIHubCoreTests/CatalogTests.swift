import Foundation
import Testing
@testable import AIHubCore

private actor CatalogTransport: HTTPTransport {
    let replies: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ replies: [(Int, String)]) { self.replies = replies }
    func send(_ request: URLRequest, maximumResponseBytes: Int) async throws -> (Data, HTTPURLResponse) {
        let index = min(requests.count, replies.count - 1)
        requests.append(request)
        let (status, body) = replies[index]
        if status == -1 { throw URLError(.cannotConnectToHost) }
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

struct CatalogTests {
    private func account(_ channel: ChannelType = .antigravity) throws -> (Provider, String) {
        var provider = Provider(name: "", baseURL: "")
        provider.selectChannel(channel)
        let credential = AccountOAuthCredential(channel: channel, accessToken: "fake", refreshToken: "fake", expiresAt: Date().addingTimeInterval(3600))
        return (provider, try CredentialEnvelope(baseURL: channel.defaultURL, authentication: .accountOAuth, account: credential).encoded())
    }
    @Test func antigravityCatalogDoesNotRequireProjectAndKeepsAllTypes() async throws {
        let transport = CatalogTransport([(200, #"{"models":{"gpt-image-1":{"supportsImageGeneration":true},"veo-3.1":{},"gemini-test":{"inputModalities":["text","image","audio","video"],"outputModalities":["text"]},"whisper-1":{},"gpt-4o-mini-tts":{},"text-embedding-3-large":{},"future-model":{"disabled":true}}}"#)])
        let (provider, key) = try account()
        let client = AIClient(transport: transport)
        let models = try await client.discover(provider: provider, key: key)
        #expect(models.count == 7)
        #expect(models.first { $0.id == "gpt-image-1" }?.capability == .image)
        #expect(models.first { $0.id == "veo-3.1" }?.capability == .video)
        #expect(models.first { $0.id == "whisper-1" }?.capability == .transcription)
        #expect(models.first { $0.id == "gpt-4o-mini-tts" }?.capability == .speechSynthesis)
        #expect(models.first { $0.id == "future-model" }?.isAvailable == false)
        #expect(models.first { $0.id == "gemini-test" }?.isMultimodal == true)
        #expect(models.allSatisfy { $0.verifiedAt == nil })
        #expect(try await client.refreshedCredential(key, for: provider) == nil)
        let request = try #require(await transport.requests.first)
        #expect(await transport.requests.count == 1)
        #expect(request.url?.absoluteString == "https://daily-cloudcode-pa.googleapis.com/v1internal:fetchAvailableModels")
        #expect(request.httpMethod == "POST" && request.httpBody == Data("{}".utf8))
        #expect(request.value(forHTTPHeaderField: "Client-Metadata") == nil)
        var cached = provider; cached.mergeDiscovered(models)
        #expect(cached.speechModels.isEmpty) // Listed ASR != this channel has an ASR endpoint.
        #expect(cached.chatModels.map(\.id) == ["gemini-test"])
    }
    @Test func catalogSuccessDoesNotGrantGenerationProject() async throws {
        let transport = CatalogTransport([(200, #"{"models":{"gemini-test":{}}}"#), (200, #"{"allowedTiers":[{"id":"free"}]}"#)])
        let (provider, key) = try account()
        let client = AIClient(transport: transport)
        #expect(try await client.discover(provider: provider, key: key).count == 1)
        await #expect(throws: HubError.self) {
            try await client.transform(provider: provider, key: key, model: "gemini-test", text: "private-input", instruction: "整理")
        }
        let requests = await transport.requests
        #expect(requests.map { $0.url!.path } == ["/v1internal:fetchAvailableModels", "/v1internal:loadCodeAssist"])
        #expect(!requests.contains { String(decoding: $0.httpBody ?? Data(), as: UTF8.self).contains("private-input") })
    }
    @Test(arguments: [400, 401, 403, 422, 429])
    func catalogRestrictionsDoNotFallbackOrMentionAudio(_ status: Int) async throws {
        let transport = CatalogTransport([(status, #"{"error":{"message":"PRIVATE_TOKEN private-user@example.com raw audio log"}}"#)])
        let (provider, key) = try account()
        do {
            _ = try await AIClient(transport: transport).discover(provider: provider, key: key)
            Issue.record("Expected error")
        } catch {
            #expect(error.localizedDescription.contains("获取模型列表"))
            #expect(!error.localizedDescription.contains("音频"))
            #expect(!error.localizedDescription.contains("PRIVATE_TOKEN"))
            #expect(!error.localizedDescription.contains("private-user"))
        }
        #expect(await transport.requests.count == 1)
    }
    @Test(arguments: [-1, 404, 500, 503])
    func transientCatalogFailureFallsBackOnlyToFixedProduction(_ status: Int) async throws {
        let transport = CatalogTransport([(status, "{}"), (200, #"{"models":{"gemini-test":{}}}"#)])
        let (provider, key) = try account()
        #expect(try await AIClient(transport: transport).discover(provider: provider, key: key).count == 1)
        let requests = await transport.requests
        #expect(requests.map { $0.url!.host! } == ["daily-cloudcode-pa.googleapis.com", "cloudcode-pa.googleapis.com"])
        #expect(requests.allSatisfy { $0.httpBody == Data("{}".utf8) && $0.url?.scheme == "https" })
    }
    @Test func rpcDiagnosticsExposeOnlyKnownFields() {
        let data = Data(#"{"error":{"message":"PRIVATE_TOKEN","details":[{"fieldViolations":[{"field":"metadata.platform","description":"PRIVATE_TOKEN"},{"field":"PRIVATE_TOKEN"}]}]}}"#.utf8)
        let error = ProviderFailure.http(status: 400, purpose: .catalog, data: data)
        #expect(error.message.contains("metadata.platform"))
        #expect(!error.message.contains("PRIVATE_TOKEN"))
        #expect(error.statusCode == 400)
    }
    @Test func modelMetadataAndClassificationRoundtripWithOldMigration() throws {
        var model = ModelCatalog.model(id: "custom", entry: ["input_modalities": ["text", "image"], "output_modalities": ["text"]])
        #expect(model.capability == .chat && model.isMultimodal && model.supportsTextOutput)
        #expect(model.modalitySummary == "文本、图片 → 文本")
        #expect(try JSONDecoder().decode(AIModel.self, from: JSONEncoder().encode(model)) == model)
        model.capability = .image; model.userClassified = true
        let migrated = try JSONDecoder().decode(AIModel.self, from: Data(#"{"id":"gpt-image-1","capability":"other","source":"discovered","userClassified":false}"#.utf8))
        #expect(migrated.capability == .image)
        let overridden = try JSONDecoder().decode(AIModel.self, from: Data(#"{"id":"gpt-image-1","capability":"chat","source":"manual","userClassified":true}"#.utf8))
        #expect(overridden.capability == .chat && overridden.source == .manual)
    }
    @Test func modalityFilterNeverConfusesCatalogWithInvocation() {
        let models = [AIModel(id: "gpt-image-1"), AIModel(id: "veo-3"), AIModel(id: "unknown-future"),
                      ModelCatalog.model(id: "gpt-test", entry: ["input_modalities": ["image", "text"], "output_modalities": ["text"]])]
        #expect(models.filter { ModelCatalog.matches($0, category: nil, search: "") }.count == 4)
        #expect(models.filter { ModelCatalog.matches($0, category: .multimodal, search: "gpt") }.count == 1)
        let provider = Provider(name: "API", baseURL: "https://example.com/v1", models: models)
        #expect(provider.chatModels.map(\.id) == ["gpt-test"])
        #expect(provider.models.count == 4)
    }
    @Test func geminiKeepsImageVideoTTSAndEmbeddingAlongsideText() throws {
        let page = try ProtocolAdapter.modelPage(data: Data(#"{"models":[{"name":"models/imagen-4.0-generate-001","supportedGenerationMethods":["predict"]},{"name":"models/veo-3.1-generate-preview","supportedGenerationMethods":["predictLongRunning"]},{"name":"models/gemini-2.5-flash-tts","supportedGenerationMethods":["generateContent"]},{"name":"models/text-embedding-004","supportedGenerationMethods":["embedContent"]},{"name":"models/gemini-2.5-flash","supportedGenerationMethods":["generateContent"]}]}"#.utf8), protocol: .gemini)
        #expect(page.models.map(\.capability) == [.image, .video, .speechSynthesis, .embedding, .chat])
        #expect(page.models.allSatisfy { $0.verifiedAt == nil })
    }
    @Test func explicitNonTextOutputNeverEntersLLMSelector() {
        let model = ModelCatalog.model(id: "gemini-future", entry: ["inputModalities": ["text"], "outputModalities": ["audio"], "supportedGenerationMethods": ["generateContent"]])
        #expect(model.capability == .audio && !model.supportsTextOutput)
        let provider = Provider(name: "Google", baseURL: "https://generativelanguage.googleapis.com/v1beta", models: [model])
        #expect(provider.models.count == 1 && provider.chatModels.isEmpty)
    }
    @Test func diarizationUsesChunkingWithoutUnsupportedPrompt() async throws {
        let transport = CatalogTransport([(200, #"{"text":"结果"}"#)])
        _ = try await AIClient(transport: transport).transcribe(provider: Provider(name: "OpenAI", baseURL: "https://api.openai.com/v1"), key: "fake",
            model: "gpt-4o-transcribe-diarize", audio: Data([0, 1]), filename: "audio.wav", vocabulary: "不能发送的提示词")
        let request = try #require(await transport.requests.first)
        let body = String(decoding: request.httpBody!, as: UTF8.self)
        #expect(body.contains("name=\"chunking_strategy\"") && body.contains("auto"))
        #expect(!body.contains("name=\"prompt\""))
    }
}
