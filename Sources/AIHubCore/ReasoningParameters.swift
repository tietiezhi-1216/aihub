import Foundation

public enum ThinkingMode: String, Codable, CaseIterable, Sendable { case enabled, disabled, adaptive }
public struct ReasoningSelection: Codable, Equatable, Sendable {
    public var mode: ThinkingMode?
    public var effort: String?
    public var budget: Int?
    public init(mode: ThinkingMode? = nil, effort: String? = nil, budget: Int? = nil) {
        self.mode = mode; self.effort = effort; self.budget = budget
    }
    public var isDefault: Bool { mode == nil && effort == nil && budget == nil }
    public var summary: String {
        if isDefault { return "服务默认" }
        var values = effort.map { [ReasoningSpec.effortTitle($0)] } ?? []
        if let mode { values.append([ThinkingMode.enabled: "开启", .disabled: "关闭", .adaptive: "自适应"][mode]!) }
        if let budget { values.append(budget == -1 ? "自动预算" : "预算 \(budget)") }
        return values.joined(separator: "、")
    }
}
public struct TextCallOptions: Equatable, Sendable {
    public var maxOutputTokens: Int
    public var reasoning: ReasoningSelection
    public var enforceOutputLimit: Bool
    public var usesCompletionLimit: Bool
    public init(maxOutputTokens: Int = 4096, reasoning: ReasoningSelection = .init(), enforceOutputLimit: Bool = false, usesCompletionLimit: Bool = false) {
        self.maxOutputTokens = maxOutputTokens; self.reasoning = reasoning; self.enforceOutputLimit = enforceOutputLimit; self.usesCompletionLimit = usesCompletionLimit
    }
}
public enum ReasoningWireStyle: String, Sendable { case openAI, anthropic, gemini }

public enum PublicReasoningPolicy {
    /// A protocol-compatible URL alone does not establish thinking parameter compatibility.
    public static func style(provider: Provider, api: APIProtocol) -> ReasoningWireStyle? {
        guard !provider.channelType.isSubscription, provider.channelType != .cliProxyAPI else { return nil }
        guard let url = URLComponents(string: provider.baseURL), url.scheme?.lowercased() == "https",
              url.port == nil || url.port == 443, url.user == nil, url.password == nil else { return nil }
        let host = url.host?.lowercased()
        switch (host, api) {
        case ("api.openai.com", .openAIChat), ("api.openai.com", .openAIResponses): return .openAI
        case ("api.anthropic.com", .anthropic): return .anthropic
        case ("generativelanguage.googleapis.com", .gemini): return .gemini
        default: return nil
        }
    }
    public static func options(provider: Provider, modelID: String, api: APIProtocol) throws -> TextCallOptions {
        let model = provider.models.first { $0.id == modelID }
        let limit = model?.outputTokenLimit ?? min(model?.metadata.limits.output ?? 4096, 4096)
        let selection = model?.reasoningSelection ?? .init()
        guard (1...65_536).contains(limit), limit <= (model?.metadata.limits.output ?? 65_536) else { throw HubError("输出上限不在此模型允许的范围内。") }
        if selection.isDefault { return .init(maxOutputTokens: limit, enforceOutputLimit: model?.outputTokenLimit != nil, usesCompletionLimit: style(provider: provider, api: api) == .openAI) }
        guard let style = style(provider: provider, api: api), let model else { throw HubError("此渠道尚未确认思考参数映射；未发送请求，请选择服务默认。") }
        try validate(selection, spec: model.metadata.reasoning, style: style, outputLimit: limit)
        return .init(maxOutputTokens: limit, reasoning: selection, enforceOutputLimit: true)
    }
    public static func validate(_ value: ReasoningSelection, spec: ReasoningSpec, style: ReasoningWireStyle, outputLimit: Int) throws {
        if value.isDefault { return }
        guard spec.support == .supported, let origin = spec.evidence?.origin,
              [.service, .publicCatalog, .user, .channelRule].contains(origin) else { throw unavailable() }
        if let effort = value.effort {
            guard spec.efforts.contains(effort), ModelCatalog.safeControl(effort), effort != "default" else { throw unavailable() }
        }
        if let mode = value.mode, !spec.modes.contains(mode.rawValue) { throw unavailable() }
        if let budget = value.budget {
            guard spec.supportsBudget || style == .anthropic && value.mode == .enabled else { throw unavailable() }
            if budget == -1 { guard spec.allowsAutomaticBudget == true else { throw unavailable() } }
            else if style == .anthropic, value.mode == .enabled {
                guard budget >= 1024, budget < outputLimit,
                      spec.minimumBudget.map({ budget >= $0 }) ?? true,
                      spec.maximumBudget.map({ budget <= $0 }) ?? true else { throw unavailable() }
            } else {
                guard budget >= 0, budget <= 65_536,
                      spec.minimumBudget.map({ budget >= $0 }) ?? false,
                      spec.maximumBudget.map({ budget <= $0 }) ?? false else { throw unavailable() }
            }
        }
        switch style {
        case .openAI:
            guard value.mode == nil, value.budget == nil, let effort = value.effort,
                  ["none", "minimal", "low", "medium", "high", "xhigh", "max"].contains(effort),
                  !(spec.mandatory == true && effort == "none") else { throw unavailable() }
        case .anthropic:
            guard value.effort.map({ ["low", "medium", "high", "xhigh", "max"].contains($0) }) ?? true else { throw unavailable() }
            if value.mode == .enabled {
                guard let budget = value.budget, budget >= 1024, budget < outputLimit, value.effort == nil else { throw unavailable() }
            } else {
                guard value.budget == nil else { throw unavailable() }
                if value.effort != nil { guard value.mode == .adaptive else { throw unavailable() } }
            }
            if value.mode == .disabled, spec.mandatory == true { throw unavailable() }
        case .gemini:
            guard value.mode == nil, !(value.effort != nil && value.budget != nil),
                  value.effort.map({ ["minimal", "low", "medium", "high"].contains($0) }) ?? true else { throw unavailable() }
            if value.budget == 0, spec.mandatory == true { throw unavailable() }
        }
    }
    private static func unavailable() -> HubError {
        HubError("思考配置已不在当前渠道规格或参数约束中。请重新选择；未自动降档，也未发送请求。")
    }
}

/// Applied to serializer output in the bound transport. Only documented fields are modified.
public enum ReasoningWire {
    public static func apply(_ data: Data, api: APIProtocol, options: TextCallOptions) throws -> Data {
        guard var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw HubError("文字请求格式无效。") }
        let selected = options.reasoning
        guard (1...65_536).contains(options.maxOutputTokens),
              selected.effort.map(ModelCatalog.safeControl) ?? true else { throw HubError("文字调用参数无效。") }
        switch api {
        case .openAIChat:
            if selected.isDefault && (options.enforceOutputLimit || options.usesCompletionLimit && (body["max_tokens"] != nil || body["max_completion_tokens"] != nil)) {
                if options.usesCompletionLimit || body["max_completion_tokens"] != nil {
                    body["max_tokens"] = nil; body["max_completion_tokens"] = options.maxOutputTokens
                }
                else { body["max_tokens"] = options.maxOutputTokens }
            }
            if !selected.isDefault {
                guard selected.mode == nil, selected.budget == nil, let effort = selected.effort else { throw HubError("Chat 思考配置无效。") }
                body["reasoning_effort"] = effort
                body["max_tokens"] = nil
                body["max_completion_tokens"] = options.maxOutputTokens
            }
        case .openAIResponses:
            body["max_output_tokens"] = options.maxOutputTokens
            body["store"] = false
            if !selected.isDefault {
                guard selected.mode == nil, selected.budget == nil, let effort = selected.effort else { throw HubError("Responses 思考配置无效。") }
                body["reasoning"] = ["effort": effort]
            }
        case .anthropic:
            body["max_tokens"] = options.maxOutputTokens
            if !selected.isDefault {
                guard selected.mode != .enabled || (selected.budget.map { $0 >= 1024 && $0 < options.maxOutputTokens } ?? false),
                      selected.mode == .enabled || selected.budget == nil else { throw HubError("Anthropic 思考预算无效。") }
                if let mode = selected.mode {
                    var thinking: [String: Any] = ["type": mode.rawValue]
                    if let budget = selected.budget { thinking["budget_tokens"] = budget }
                    body["thinking"] = thinking
                }
                if let effort = selected.effort {
                    var output = body["output_config"] as? [String: Any] ?? [:]
                    output["effort"] = effort; body["output_config"] = output
                }
                if selected.mode != .disabled { body["temperature"] = nil; body["top_p"] = nil; body["top_k"] = nil }
            }
        case .gemini:
            var config = body["generationConfig"] as? [String: Any] ?? [:]
            config["maxOutputTokens"] = options.maxOutputTokens
            if !selected.isDefault {
                guard selected.mode == nil, !(selected.effort != nil && selected.budget != nil) else { throw HubError("Gemini 思考配置不能同时使用等级和预算。") }
                var thinking: [String: Any] = ["includeThoughts": false]
                if let effort = selected.effort { thinking["thinkingLevel"] = effort }
                if let budget = selected.budget { thinking["thinkingBudget"] = budget }
                config["thinkingConfig"] = thinking
            }
            body["generationConfig"] = config
        default:
            guard selected.isDefault else { throw HubError("此协议未接入思考参数。") }
        }
        return try JSONSerialization.data(withJSONObject: body)
    }
}
