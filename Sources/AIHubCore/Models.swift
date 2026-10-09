import Foundation

public enum ProviderKind: String, Codable, CaseIterable, Identifiable, Sendable {
    case openAI, groq, siliconFlow, compatible
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .groq: "Groq"
        case .siliconFlow: "硅基流动"
        case .compatible: "OpenAI 兼容"
        }
    }

    public var defaultURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .groq: "https://api.groq.com/openai/v1"
        case .siliconFlow: "https://api.siliconflow.cn/v1"
        case .compatible: ""
        }
    }

    // Suggestions are never represented as discovered or verified models.
    public var suggestions: [String] {
        switch self {
        case .openAI: ["whisper-1", "gpt-4o-transcribe", "gpt-4o-mini-transcribe"]
        case .groq: ["whisper-large-v3-turbo", "whisper-large-v3"]
        case .siliconFlow: ["FunAudioLLM/SenseVoiceSmall"]
        case .compatible: []
        }
    }
}

public enum ModelCapability: String, Codable, CaseIterable, Identifiable, Sendable {
    case chat, image, video, multimodal, transcription, speechSynthesis, audio, embedding, rerank, other, unknown
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .transcription: "语音识别 (ASR)"
        case .chat: "文本 (LLM)"
        case .image: "图片"
        case .video: "视频"
        case .speechSynthesis: "语音合成 (TTS)"
        case .audio: "语音 / 音频"
        case .multimodal: "多模态"
        case .embedding: "向量 / 嵌入"
        case .rerank: "重排序"
        case .other: "其他"
        case .unknown: "待确认"
        }
    }
}

public enum ModelSource: String, Codable, Sendable {
    case discovered, manual
}

/// Compatibility name for the channel-specific offering, not a global model identity.
public typealias AIModel = ModelOffering

public struct ModelOffering: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var capability: ModelCapability
    public var source: ModelSource
    public var displayName: String?
    public var name: String { displayName ?? id }
    public var userClassified: Bool
    public var verifiedAt: Date?
    public var inputModalities: [ModelModality]
    public var outputModalities: [ModelModality]
    public var generationMethods: [String]
    public var isAvailable: Bool?
    public var definition: ModelDefinition?
    public var metadata = ModelMetadata()
    public var price: PriceSchedule?
    public var verifications: [InvocationVerification] = []
    public var reasoningSelection: ReasoningSelection?
    public var outputTokenLimit: Int?
    public var tasks: [ModelTask] {
        if userClassified { return ModelTask.inferred(from: capability) }
        return metadata.tasks.isEmpty ? ModelTask.inferred(from: capability) : metadata.tasks
    }
    public var priceSummary: String { price?.summary ?? "价格待确认" }
    public mutating func classify(_ capability: ModelCapability) {
        self.capability = capability; userClassified = true
        metadata.evidence["tasks"] = .init(.user, source: "用户分类")
        verifiedAt = nil; verifications = []
    }
    public mutating func verify(task: ModelTask, api: APIProtocol, backend: TextBackend, at date: Date = Date()) {
        let selected = task == .textGeneration ? reasoningSelection : nil
        verifications.removeAll { $0.task == task && $0.apiProtocol == api && $0.backend == backend && $0.reasoning == selected }
        verifications.append(.init(task: task, apiProtocol: api, backend: backend, completedAt: date, reasoning: selected))
        verifiedAt = date
    }

    public init(id: String, capability: ModelCapability? = nil, source: ModelSource = .discovered, displayName: String? = nil) {
        self.id = id
        self.capability = capability ?? ModelClassifier.classify(id)
        self.source = source
        self.displayName = displayName
        self.userClassified = capability != nil
        self.verifiedAt = nil
        self.inputModalities = []
        self.outputModalities = []
        self.generationMethods = []
        self.isAvailable = nil
        self.metadata.evidence["tasks"] = .init(capability == nil ? .nameHint : .user, source: capability == nil ? "模型名称推测" : "用户分类")
    }

    private enum CodingKeys: String, CodingKey {
        case id, capability, source, displayName, userClassified, verifiedAt
        case inputModalities, outputModalities, generationMethods, isAvailable, definition, metadata, price, verifications, reasoningSelection, outputTokenLimit
    }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        capability = try c.decode(ModelCapability.self, forKey: .capability)
        source = try c.decodeIfPresent(ModelSource.self, forKey: .source) ?? .discovered
        displayName = try c.decodeIfPresent(String.self, forKey: .displayName)
        userClassified = try c.decodeIfPresent(Bool.self, forKey: .userClassified) ?? false
        verifiedAt = try c.decodeIfPresent(Date.self, forKey: .verifiedAt)
        inputModalities = try c.decodeIfPresent([ModelModality].self, forKey: .inputModalities) ?? []
        outputModalities = try c.decodeIfPresent([ModelModality].self, forKey: .outputModalities) ?? []
        generationMethods = try c.decodeIfPresent([String].self, forKey: .generationMethods) ?? []
        isAvailable = try c.decodeIfPresent(Bool.self, forKey: .isAvailable)
        definition = try c.decodeIfPresent(ModelDefinition.self, forKey: .definition)
        if let stored = try c.decodeIfPresent(ModelMetadata.self, forKey: .metadata) { metadata = stored }
        else {
            metadata = ModelMetadata()
            metadata.evidence["tasks"] = .init(userClassified ? .user : .legacy, source: userClassified ? "用户分类" : "旧配置分类")
        }
        price = try c.decodeIfPresent(PriceSchedule.self, forKey: .price)
        verifications = try c.decodeIfPresent([InvocationVerification].self, forKey: .verifications) ?? []
        reasoningSelection = try c.decodeIfPresent(ReasoningSelection.self, forKey: .reasoningSelection)
        outputTokenLimit = try c.decodeIfPresent(Int.self, forKey: .outputTokenLimit)
        // Migrate previous generic labels without overriding manual classification.
        if !userClassified, capability == .other || capability == .unknown {
            let inferred = ModelClassifier.classify(id)
            if inferred != .unknown { capability = inferred }
        }
    }
    public var isMultimodal: Bool {
        capability == .multimodal || Set(inputModalities + outputModalities).count > 1
    }
    public var modalitySummary: String? {
        guard !inputModalities.isEmpty || !outputModalities.isEmpty else { return nil }
        let input = inputModalities.map(\.title).joined(separator: "、")
        let output = outputModalities.map(\.title).joined(separator: "、")
        return "\(input.isEmpty ? "—" : input) → \(output.isEmpty ? "—" : output)"
    }
    public var supportsTextOutput: Bool {
        guard outputModalities.isEmpty || outputModalities.contains(.text) else { return false }
        return tasks.contains(.textGeneration) || capability == .multimodal && outputModalities.contains(.text)
    }
    public var status: String {
        if isAvailable == false { return "服务标记不可用" }
        if !verifications.isEmpty { return "调用已验证" }
        if verifiedAt != nil { return "历史调用 · 待复核" }
        if userClassified { return "手动指定 · 未验证" }
        return source == .manual ? "手动添加 · 未验证" : "自动识别 · 未验证"
    }
}

public struct Provider: Identifiable, Codable, Equatable, Sendable {
    public var connection: ProviderConnection
    public var catalog: ProviderCatalog
    // The facade preserves UI/source compatibility while storage is separated.
    public var id: UUID { get { connection.id } set { connection.id = newValue } }
    public var name: String { get { connection.name } set { connection.name = newValue } }
    public var kind: ProviderKind { get { connection.kind } set { connection.kind = newValue } }
    public var baseURL: String { get { connection.baseURL } set { connection.baseURL = newValue } }
    public var requiresAPIKey: Bool { get { connection.requiresAPIKey } set { connection.requiresAPIKey = newValue } }
    public var models: [AIModel] { get { catalog.models } set { catalog.models = newValue } }
    public var discoveredAt: Date? { get { catalog.discoveredAt } set { catalog.discoveredAt = newValue } }
    public var apiProtocol: APIProtocol { get { connection.apiProtocol } set { connection.apiProtocol = newValue } }
    public var authentication: AuthenticationMethod { get { connection.authentication } set { connection.authentication = newValue } }
    public var channelType: ChannelType { get { connection.channelType } set { connection.channelType = newValue } }
    public var thinkingSelections: [String: String] { get { catalog.thinkingSelections } set { catalog.thinkingSelections = newValue } }
    public var textBackend: TextBackend { get { connection.textBackend } set { connection.textBackend = newValue } }
    // Decode-only migration guard for the withdrawn experimental configuration.
    public var withdrawnThinkingModelIDs: Set<String> = []
    public var effectiveProtocol: APIProtocol {
        apiProtocol == .automatic ? APIProtocol.detect(baseURL: baseURL) : apiProtocol
    }
    public var normalizedBaseURL: String {
        get throws { try Endpoint(baseURL, defaultVersion: effectiveProtocol.defaultVersion).baseURL.absoluteString }
    }
    public var usesSiliconFlowSpeech: Bool {
        let host = URLComponents(string: baseURL)?.host?.lowercased() ?? ""
        return kind == .siliconFlow || host == "api.siliconflow.cn" || host == "api.siliconflow.com"
    }

    public init(
        id: UUID = UUID(), name: String, kind: ProviderKind = .compatible, baseURL: String,
        requiresAPIKey: Bool = true, models: [AIModel] = [], discoveredAt: Date? = nil,
        apiProtocol: APIProtocol = .automatic, authentication: AuthenticationMethod = .apiKey,
        channelType: ChannelType? = nil, thinkingSelections: [String: String] = [:], textBackend: TextBackend = .builtIn
    ) {
        connection = .init(id: id, name: name, kind: kind, baseURL: baseURL, requiresAPIKey: requiresAPIKey,
                           apiProtocol: apiProtocol, authentication: authentication, channelType: channelType, textBackend: textBackend)
        catalog = .init(models: models, discoveredAt: discoveredAt, thinkingSelections: thinkingSelections)
    }

    private enum CodingKeys: String, CodingKey {
        case connection, catalog
        case id, name, kind, baseURL, requiresAPIKey, models, discoveredAt, apiProtocol, authentication, channelType, thinkingSelections, textBackend
    }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        if let stored = try c.decodeIfPresent(ProviderConnection.self, forKey: .connection) {
            connection = stored
            catalog = try c.decode(ProviderCatalog.self, forKey: .catalog)
        } else {
            connection = .init(id: try c.decode(UUID.self, forKey: .id), name: try c.decode(String.self, forKey: .name),
                kind: try c.decodeIfPresent(ProviderKind.self, forKey: .kind) ?? .compatible,
                baseURL: try c.decode(String.self, forKey: .baseURL),
                requiresAPIKey: try c.decodeIfPresent(Bool.self, forKey: .requiresAPIKey) ?? true,
                apiProtocol: try c.decodeIfPresent(APIProtocol.self, forKey: .apiProtocol) ?? .automatic,
                authentication: try c.decodeIfPresent(AuthenticationMethod.self, forKey: .authentication) ?? .apiKey,
                channelType: try c.decodeIfPresent(ChannelType.self, forKey: .channelType),
                textBackend: try c.decodeIfPresent(TextBackend.self, forKey: .textBackend) ?? .builtIn)
            catalog = .init(models: try c.decodeIfPresent([AIModel].self, forKey: .models) ?? [],
                discoveredAt: try c.decodeIfPresent(Date.self, forKey: .discoveredAt),
                thinkingSelections: try c.decodeIfPresent([String: String].self, forKey: .thinkingSelections) ?? [:])
        }
        let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
        let overrides = try legacy.decodeIfPresent([String: String].self, forKey: .thinkingOverrides) ?? [:]
        for group in overrides.keys {
            if let rawID = thinkingSelections.removeValue(forKey: group) { withdrawnThinkingModelIDs.insert(rawID) }
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(connection, forKey: .connection)
        try c.encode(catalog, forKey: .catalog)
    }
    private enum LegacyCodingKeys: String, CodingKey { case thinkingOverrides }

    public var speechModels: [AIModel] {
        guard !channelType.isSubscription, channelType != .cliProxyAPI,
              effectiveProtocol.supportsMultipartSpeech || effectiveProtocol == .xiaomi else { return [] }
        return models.filter { $0.tasks.contains(.transcription) && $0.isAvailable != false && binding(for: $0, task: .transcription) != nil }
    }
    public var chatModels: [AIModel] {
        models.filter {
            $0.supportsTextOutput && $0.isAvailable != false && binding(for: $0, task: .textGeneration) != nil
        }
    }

    public mutating func mergeDiscovered(_ incoming: [AIModel], at date: Date = Date()) {
        let existing = Dictionary(uniqueKeysWithValues: models.map { ($0.id, $0) })
        var merged = incoming.map { model in
            guard let old = existing[model.id] else { return model }
            var result = model
            if old.userClassified {
                result.capability = old.capability
                result.userClassified = true
                result.metadata.evidence["tasks"] = old.metadata.evidence["tasks"]
            }
            if old.metadata.bindings.contains(where: { $0.evidence.origin == .user }) {
                result.metadata.bindings = old.metadata.bindings.filter { $0.evidence.origin == .user } + result.metadata.bindings
            }
            result.reasoningSelection = old.reasoningSelection
            result.outputTokenLimit = old.outputTokenLimit
            // Preserve an invalidated preference so a later call fails rather than silently downgrading.
            if old.source == .manual { result.source = .manual }
            if result.hasSameExecutionDescription(as: old) {
                result.verifiedAt = old.verifiedAt; result.verifications = old.verifications
            }
            return result
        }
        let ids = Set(merged.map(\.id))
        merged += models.filter { $0.source == .manual && !ids.contains($0.id) }
        models = merged.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
        discoveredAt = date
        reconcileThinkingSelections()
    }
}

public struct ModelSelection: Codable, Equatable, Hashable, Sendable {
    public var providerID: UUID
    public var modelID: String
    public init(providerID: UUID, modelID: String) {
        self.providerID = providerID
        self.modelID = modelID
    }
}

public struct AppSettings: Codable, Equatable, Sendable {
    public var version = 3
    public var providers: [Provider] = []
    public var speechSelection: ModelSelection?
    public var chatSelection: ModelSelection?
    public var language = ""
    public var vocabulary = ""
    public var priceSnapshots: [String: PriceSchedule] = [:]
    public var recordsUsage = false
    public var usageRecords: [UsageRecord] = []
    public init() {}
    private enum CodingKeys: String, CodingKey { case version, providers, speechSelection, chatSelection, language, vocabulary, priceSnapshots, recordsUsage, usageRecords }
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let storedVersion = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        guard (1...3).contains(storedVersion) else { throw HubError("配置版本不兼容。") }
        version = 3
        providers = try c.decodeIfPresent([Provider].self, forKey: .providers) ?? []
        speechSelection = try c.decodeIfPresent(ModelSelection.self, forKey: .speechSelection)
        chatSelection = try c.decodeIfPresent(ModelSelection.self, forKey: .chatSelection)
        language = try c.decodeIfPresent(String.self, forKey: .language) ?? ""
        vocabulary = try c.decodeIfPresent(String.self, forKey: .vocabulary) ?? ""
        priceSnapshots = try c.decodeIfPresent([String: PriceSchedule].self, forKey: .priceSnapshots) ?? [:]
        recordsUsage = try c.decodeIfPresent(Bool.self, forKey: .recordsUsage) ?? false
        usageRecords = try c.decodeIfPresent([UsageRecord].self, forKey: .usageRecords) ?? []
    }
    public mutating func archivePrices() {
        for price in providers.flatMap({ $0.models.compactMap(\.price) }) where priceSnapshots[price.id] == nil {
            priceSnapshots[price.id] = price
        }
    }

    public mutating func reconcileSelections() {
        archivePrices()
        for index in providers.indices {
            let provider = providers[index]
            if let selection = chatSelection, selection.providerID == provider.id,
               provider.withdrawnThinkingModelIDs.contains(selection.modelID) { chatSelection = nil }
            providers[index].withdrawnThinkingModelIDs = []
            providers[index].reconcileThinkingSelections()
        }
        func exists(_ selection: ModelSelection?, _ capability: ModelCapability) -> Bool {
            guard let selection else { return false }
            return providers.contains { provider in
                guard provider.id == selection.providerID else { return false }
                let candidates = capability == .transcription ? provider.speechModels : provider.chatModels
                return candidates.contains { $0.id == selection.modelID }
            }
        }
        if !exists(speechSelection, .transcription) { speechSelection = nil }
        if let selection = chatSelection,
           let provider = providers.first(where: { $0.id == selection.providerID }),
           let group = provider.modelGroups.first(where: { $0.variants.contains { $0.model.id == selection.modelID } }),
           let preferred = provider.thinkingSelections[group.id],
           provider.chatModels.contains(where: { $0.id == preferred }) {
            chatSelection = .init(providerID: provider.id, modelID: preferred)
        }
        if !exists(chatSelection, .chat) { chatSelection = nil }
    }
}

public enum ModelClassifier {
    // Model names are hints, not a protocol capability guarantee.
    public static func classify(_ id: String) -> ModelCapability {
        let lower = id.lowercased()
        let tokens = Set(lower.split { !$0.isLetter && !$0.isNumber }.map(String.init))
        func family(_ value: String) -> Bool {
            tokens.contains { token in
                token == value || token.hasPrefix(value) && token.dropFirst(value.count).first?.isNumber == true
            }
        }
        if tokens.contains("tts") || lower.contains("cosyvoice") || lower.contains("fish-speech") { return .speechSynthesis }
        if tokens.contains("asr") || tokens.contains("stt") ||
            tokens.contains("whisper") || tokens.contains("transcribe") ||
            lower.contains("sensevoicesmall") || lower.contains("telespeechasr") {
            return .transcription
        }
        if !tokens.isDisjoint(with: ["video", "sora", "veo", "wan", "hunyuanvideo", "cogvideo"]) || family("veo") || family("wan") { return .video }
        if !tokens.isDisjoint(with: ["image", "imagen", "flux", "dalle"]) ||
            lower.contains("dall-e") || lower.contains("stable-diffusion") || lower.contains("kolors") || family("imagen") { return .image }
        if !tokens.isDisjoint(with: ["rerank", "reranker"]) { return .rerank }
        if !tokens.isDisjoint(with: ["embedding", "embed", "embeddings", "bge", "e5"]) { return .embedding }
        if !tokens.isDisjoint(with: ["audio", "realtime"]) { return .audio }
        if !tokens.isDisjoint(with: ["moderation", "search"]) { return .other }
        if tokens.contains("multimodal") { return .multimodal }
        if ["gpt", "llama", "qwen", "deepseek", "mistral", "gemma", "glm", "kimi", "mimo", "claude", "gemini", "grok", "codex"].contains(where: family) {
            return .chat
        }
        return .unknown
    }
}

public struct HubError: LocalizedError, Equatable, Sendable {
    public var message: String
    public var statusCode: Int?
    public var isNetworkFailure: Bool
    public var errorDescription: String? { message }
    public init(_ message: String, statusCode: Int? = nil, isNetworkFailure: Bool = false) {
        self.message = message; self.statusCode = statusCode; self.isNetworkFailure = isNetworkFailure
    }
}

public enum Validation {
    public static func modelID(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 256,
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw HubError("模型 ID 不能为空、包含控制字符或超过 256 字节。")
        }
        return value
    }

    public static func apiKey(_ raw: String) throws -> String {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              value.utf8.count <= 4096 else {
            throw HubError("API Key 格式无效，请检查是否含换行。")
        }
        return value
    }
}
