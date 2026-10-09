import Foundation

public enum ModelTask: String, Codable, CaseIterable, Sendable {
    case textGeneration, imageGeneration, videoGeneration, audioGeneration, transcription, speechSynthesis, embedding, rerank
    public var title: String {
        switch self {
        case .textGeneration: "文字生成"
        case .imageGeneration: "图片生成"
        case .videoGeneration: "视频生成"
        case .audioGeneration: "音频生成"
        case .transcription: "语音识别 (ASR)"
        case .speechSynthesis: "语音合成 (TTS)"
        case .embedding: "向量 / 嵌入"
        case .rerank: "重排序"
        }
    }
    public static func inferred(from capability: ModelCapability) -> [Self] {
        switch capability {
        case .chat: [.textGeneration]
        case .image: [.imageGeneration]
        case .video: [.videoGeneration]
        case .transcription: [.transcription]
        case .speechSynthesis: [.speechSynthesis]
        case .audio: [.audioGeneration]
        case .embedding: [.embedding]
        case .rerank: [.rerank]
        default: []
        }
    }
}

public enum MetadataOrigin: String, Codable, Sendable {
    case service, publicCatalog, channelRule, user, nameHint, legacy
    public var title: String {
        switch self {
        case .service: "服务返回"
        case .publicCatalog: "公共目录参考"
        case .channelRule: "渠道适配规则"
        case .user: "用户指定"
        case .nameHint: "名称推测"
        case .legacy: "旧配置"
        }
    }
}
public struct MetadataEvidence: Codable, Equatable, Sendable {
    public var origin: MetadataOrigin
    public var source: String
    public var fetchedAt: Date?
    public init(_ origin: MetadataOrigin, source: String, at date: Date? = nil) {
        self.origin = origin; self.source = source; self.fetchedAt = date
    }
}

public struct ModelDeveloper: Codable, Equatable, Hashable, Sendable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}
/// Qualified identities are optional. Similar names never establish model identity.
public struct ModelIdentity: Codable, Equatable, Hashable, Sendable {
    public var namespace: String
    public var modelID: String
    public init(namespace: String, modelID: String) { self.namespace = namespace; self.modelID = modelID }
}
public struct ModelDefinition: Codable, Equatable, Sendable {
    public var identity: ModelIdentity
    public var developer: ModelDeveloper?
    public var name: String
    public var evidence: MetadataEvidence
    public init(identity: ModelIdentity, developer: ModelDeveloper? = nil, name: String, evidence: MetadataEvidence) {
        self.identity = identity; self.developer = developer; self.name = name; self.evidence = evidence
    }
}

public enum CapabilityKnowledge: String, Codable, Sendable { case unknown, unsupported, supported }
/// Orthogonal controls: adaptive/toggle is not an effort tier; default is not off.
public struct ReasoningSpec: Codable, Equatable, Sendable {
    public var support: CapabilityKnowledge = .unknown
    public var modes: [String] = []
    public var efforts: [String] = []
    public var minimumBudget: Int?
    public var maximumBudget: Int?
    public var supportsBudget = false
    public var allowsAutomaticBudget: Bool?
    public var mandatory: Bool?
    public var defaultEffort: String?
    public var evidence: MetadataEvidence?
    public init() {}
    public var summary: String {
        if support == .unsupported { return "不支持" }
        if support == .unknown { return "待确认" }
        var values = efforts.map(Self.effortTitle)
        values += modes.map { ["enabled": "开启", "disabled": "关闭", "adaptive": "自适应" ][$0] ?? $0 }
        if supportsBudget {
            if let minimumBudget, let maximumBudget { values.append("预算 \(minimumBudget)…\(maximumBudget)") }
            else { values.append("Token 预算") }
        }
        return values.isEmpty ? "支持 · 档位待确认" : values.joined(separator: "、")
    }
    public static func effortTitle(_ value: String) -> String {
        ["none": "关闭", "minimal": "最低", "low": "低", "medium": "中", "high": "高", "xhigh": "更高", "max": "最高", "default": "默认"][value] ?? value
    }
}

public struct ModelLimits: Codable, Equatable, Sendable {
    public var context: Int?
    public var input: Int?
    public var output: Int?
    public init(context: Int? = nil, input: Int? = nil, output: Int? = nil) {
        self.context = context; self.input = input; self.output = output
    }
}
/// Contains no URLs, headers, auth changes, or arbitrary JSON request fragments.
public struct InvocationBinding: Codable, Equatable, Sendable {
    public var task: ModelTask
    public var apiProtocol: APIProtocol
    public var evidence: MetadataEvidence
    public init(task: ModelTask, apiProtocol: APIProtocol, evidence: MetadataEvidence) {
        self.task = task; self.apiProtocol = apiProtocol; self.evidence = evidence
    }
}
public struct InvocationVerification: Codable, Equatable, Sendable {
    public var task: ModelTask
    public var apiProtocol: APIProtocol
    public var backend: TextBackend
    public var completedAt: Date
    public var reasoning: ReasoningSelection?
}

public struct ModelMetadata: Codable, Equatable, Sendable {
    public var tasks: [ModelTask] = []
    public var reasoning = ReasoningSpec()
    public var limits = ModelLimits()
    public var bindings: [InvocationBinding] = []
    /// Field-level origins; public data never becomes account authorization evidence.
    public var evidence: [String: MetadataEvidence] = [:]
    public init() {}
}

public struct OfferingIdentity: Hashable, Codable, Sendable {
    public var connectionID: UUID
    public var remoteModelID: String
    public init(connectionID: UUID, remoteModelID: String) {
        self.connectionID = connectionID; self.remoteModelID = remoteModelID
    }
}
