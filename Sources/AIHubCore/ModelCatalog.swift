import Foundation
import CoreFoundation

public enum ModelModality: String, Codable, CaseIterable, Sendable {
    case text, image, video, audio, document, other
    public var title: String {
        switch self {
        case .text: "文本"
        case .image: "图片"
        case .video: "视频"
        case .audio: "语音"
        case .document: "文档"
        case .other: "其他"
        }
    }
}

/// Descriptions, origins and pricing are independent of executable adapters and authorization.
public enum ModelCatalog {
    public static func model(id: String, entry: [String: Any], displayName: String? = nil, priceCurrency: String? = nil, fetchedAt: Date? = nil) -> AIModel {
        var model = AIModel(id: id, displayName: safeText(displayName ?? entry["name"] as? String, maximum: 256).flatMap { $0 == id ? nil : $0 })
        let evidence = MetadataEvidence(.service, source: "渠道模型接口", at: fetchedAt)
        let architecture = entry["architecture"] as? [String: Any] ?? [:]
        let caps = entry["capabilities"] as? [String: Any] ?? [:]
        let methods = entry["supportedGenerationMethods"] as? [String] ?? entry["supported_generation_methods"] as? [String] ?? []
        model.generationMethods = Array(methods.prefix(64)).compactMap { safeText($0, maximum: 128) }
        model.inputModalities = modalities(entry["input_modalities"] ?? entry["inputModalities"] ?? architecture["input_modalities"])
        model.outputModalities = modalities(entry["output_modalities"] ?? entry["outputModalities"] ?? architecture["output_modalities"])
        if model.inputModalities.isEmpty, let mime = entry["supportedMimeTypes"] as? [String: Any] {
            model.inputModalities = mime.keys.sorted().compactMap { key in
                guard mime[key] as? Bool != false else { return nil }
                return modality(key)
            }.uniqued()
        }
        if entry["supportsImages"] as? Bool == true || supported(caps["image_input"]) == true {
            if !model.inputModalities.contains(.image) { model.inputModalities.append(.image) }
        }
        if supported(caps["pdf_input"]) == true && !model.inputModalities.contains(.document) { model.inputModalities.append(.document) }
        if entry["disabled"] as? Bool == true { model.isAvailable = false }
        else { model.isAvailable = entry["available"] as? Bool ?? entry["isAvailable"] as? Bool }

        var tasks = taskValues(entry["tasks"])
        if methods.contains("embedContent") || methods.contains("batchEmbedContents") || methods.contains("embedText") {
            tasks.append(.embedding); model.capability = .embedding
        }
        if entry["supportsImageGeneration"] as? Bool == true || methods.contains("generateImages") || model.outputModalities.contains(.image) {
            tasks.append(.imageGeneration); model.capability = .image
        }
        if entry["supportsVideoGeneration"] as? Bool == true || methods.contains("generateVideos") || model.outputModalities.contains(.video) {
            tasks.append(.videoGeneration); model.capability = .video
        }
        if model.outputModalities.contains(.audio) && !model.outputModalities.contains(.text),
           !tasks.contains(.speechSynthesis) {
            // Text -> audio may be music/sound, not necessarily speech synthesis.
            if model.capability == .speechSynthesis { tasks.append(.speechSynthesis) }
            else { model.capability = .audio; tasks.append(.audioGeneration) }
        }
        if model.outputModalities.contains(.text), ![.transcription, .speechSynthesis, .audio, .embedding, .rerank].contains(model.capability),
           Set(tasks).isDisjoint(with: [.transcription, .speechSynthesis, .embedding, .rerank]) {
            tasks.append(.textGeneration)
            if model.capability == .unknown { model.capability = .chat }
        } else if methods.contains("generateContent"), model.capability == .unknown {
            tasks.append(.textGeneration); model.capability = .chat
        }
        if !tasks.isEmpty {
            model.metadata.tasks = tasks.uniqued()
            model.metadata.evidence["tasks"] = evidence
            if model.capability == .unknown, let task = tasks.first {
                model.capability = capability(for: task)
            }
        }
        if !model.inputModalities.isEmpty { model.metadata.evidence["inputModalities"] = evidence }
        if !model.outputModalities.isEmpty { model.metadata.evidence["outputModalities"] = evidence }
        model.metadata.reasoning = reasoning(entry: entry, capabilities: caps, evidence: evidence)
        model.metadata.limits = .init(context: positiveInt(entry["context_length"]),
            input: positiveInt(entry["inputTokenLimit"] ?? entry["max_input_tokens"]),
            output: positiveInt(entry["outputTokenLimit"] ?? entry["max_tokens"] ?? (entry["top_provider"] as? [String: Any])?["max_completion_tokens"]))
        if model.metadata.limits != ModelLimits() { model.metadata.evidence["limits"] = evidence }
        let endpoints = entry["supported_endpoints"] as? [String] ?? []
        model.metadata.bindings = Array(endpoints.prefix(16)).compactMap { endpoint in
            let api: APIProtocol
            switch endpoint {
            case "responses", "/responses", "/v1/responses": api = .openAIResponses
            case "chat/completions", "/chat/completions", "/v1/chat/completions", "chat.completions": api = .openAIChat
            default: return nil
            }
            return .init(task: .textGeneration, apiProtocol: api, evidence: evidence)
        }
        model.price = PriceCatalog.service(entry["pricing"], currency: priceCurrency ?? (entry["pricing"] as? [String: Any])?["currency"] as? String, at: fetchedAt ?? Date(), source: "渠道模型接口")
        return model
    }
    public static func reasoning(entry: [String: Any], capabilities: [String: Any] = [:], evidence: MetadataEvidence) -> ReasoningSpec {
        var result = ReasoningSpec()
        let reasoning = entry["reasoning"] as? [String: Any] ?? [:]
        let thinking = capabilities["thinking"] as? [String: Any] ?? [:]
        let effort = capabilities["effort"] as? [String: Any] ?? [:]
        if let declared = supported(capabilities["thinking"]) ?? entry["supportsThinking"] as? Bool ?? entry["thinking"] as? Bool ?? entry["reasoning"] as? Bool {
            result.support = declared ? .supported : .unsupported
        }
        result.efforts = controlValues(reasoning["supported_efforts"])
        result.efforts += effort.keys.sorted().filter { $0 != "supported" && supported(effort[$0]) == true && safeControl($0) }
        result.efforts = result.efforts.uniqued()
        result.modes = (thinking["types"] as? [String: Any] ?? [:]).filter { supported($0.value) == true }.keys.sorted().filter(safeControl)
        result.minimumBudget = nonnegativeInt(entry["minThinkingBudget"])
        result.maximumBudget = nonnegativeInt(entry["maxThinkingBudget"])
        result.supportsBudget = result.minimumBudget != nil || result.maximumBudget != nil
        if let min = result.minimumBudget, let max = result.maximumBudget, min > max {
            result.minimumBudget = nil; result.maximumBudget = nil; result.supportsBudget = false
        }
        result.mandatory = reasoning["mandatory"] as? Bool
        result.defaultEffort = (reasoning["default_effort"] as? String).flatMap { safeControl($0) ? $0 : nil }
        if !result.efforts.isEmpty || !result.modes.isEmpty || result.supportsBudget { result.support = .supported }
        // An explicit false is not overridden by stray optional fields.
        if supported(capabilities["thinking"]) == false || entry["supportsThinking"] as? Bool == false || entry["thinking"] as? Bool == false || entry["reasoning"] as? Bool == false {
            result = ReasoningSpec(); result.support = .unsupported
        }
        if result.support != .unknown { result.evidence = evidence }
        return result
    }
    public static func matches(_ model: AIModel, category: ModelCapability?, search: String) -> Bool {
        let matchesType = category == nil || model.capability == category || category == .multimodal && model.isMultimodal ||
            category.map { !Set(ModelTask.inferred(from: $0)).isDisjoint(with: model.tasks) } == true
        return matchesType && (search.isEmpty || model.id.localizedCaseInsensitiveContains(search) || model.name.localizedCaseInsensitiveContains(search))
    }
    public static func safeText(_ value: String?, maximum: Int) -> String? {
        guard let value, !value.isEmpty, value.utf8.count <= maximum,
              !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else { return nil }
        return value
    }
    public static func positiveInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
              let value = value as? Int, value > 0, value <= 100_000_000 else { return nil }; return value
    }
    public static func nonnegativeInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.rounded() == number.doubleValue,
              let value = value as? Int, value >= 0, value <= 100_000_000 else { return nil }; return value
    }
    public static func safeControl(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 40 && value.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-".contains($0)) }
    }
    public static func controlValues(_ value: Any?) -> [String] {
        Array((value as? [String] ?? []).prefix(16)).filter(safeControl).uniqued()
    }
    public static func supported(_ value: Any?) -> Bool? { (value as? [String: Any])?["supported"] as? Bool }
    public static func modalities(_ raw: Any?) -> [ModelModality] {
        Array((raw as? [String] ?? []).prefix(16)).map(modality).uniqued()
    }
    private static func modality(_ value: String) -> ModelModality {
        let lower = value.lowercased()
        if lower == "text" || lower.hasPrefix("text/") { return .text }
        if lower == "image" || lower.hasPrefix("image/") { return .image }
        if lower == "video" || lower.hasPrefix("video/") { return .video }
        if lower == "audio" || lower == "speech" || lower.hasPrefix("audio/") { return .audio }
        if ["pdf", "file", "document", "application/pdf"].contains(lower) { return .document }
        return .other
    }
    private static func taskValues(_ raw: Any?) -> [ModelTask] {
        controlValues(raw).compactMap { value in
            ModelTask(rawValue: value) ?? ["chat": .textGeneration, "image": .imageGeneration, "video": .videoGeneration, "asr": .transcription, "tts": .speechSynthesis][value]
        }
    }
    private static func capability(for task: ModelTask) -> ModelCapability {
        switch task {
        case .textGeneration: .chat
        case .imageGeneration: .image
        case .videoGeneration: .video
        case .audioGeneration: .audio
        case .transcription: .transcription
        case .speechSynthesis: .speechSynthesis
        case .embedding: .embedding
        case .rerank: .rerank
        }
    }
}

extension Array where Element: Hashable {
    fileprivate func uniqued() -> Self {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
