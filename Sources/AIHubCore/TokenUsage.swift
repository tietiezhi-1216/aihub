import Foundation
import CoreFoundation

public enum InputAccounting: String, Codable, Sendable { case inclusive, exclusive, unknown }
/// Counts only. Never stores response text, thinking, request bodies, identities or credentials.
public struct TokenUsage: Codable, Equatable, Sendable {
    public var input: Int?
    public var output: Int?
    public var cacheRead: Int?
    public var cacheWrite: Int?
    public var reasoning: Int?
    public var inputAudio: Int?
    public var outputAudio: Int?
    public var accounting: InputAccounting
    public var extraBillingUnknown: Bool
    public init(input: Int? = nil, output: Int? = nil, cacheRead: Int? = nil, cacheWrite: Int? = nil,
                reasoning: Int? = nil, inputAudio: Int? = nil, outputAudio: Int? = nil,
                accounting: InputAccounting = .unknown, extraBillingUnknown: Bool = false) {
        self.input = input; self.output = output; self.cacheRead = cacheRead; self.cacheWrite = cacheWrite
        self.reasoning = reasoning; self.inputAudio = inputAudio; self.outputAudio = outputAudio
        self.accounting = accounting; self.extraBillingUnknown = extraBillingUnknown
    }
    public var summary: String {
        guard input != nil || output != nil else { return "用量未返回或无法确认" }
        let title = accounting == .exclusive && contextTokens == nil ? "未缓存输入" : "输入"
        return "\(title) \((contextTokens ?? input).map(String.init) ?? "—") · 输出 \(output.map(String.init) ?? "—") token"
    }
    /// Full reported input for context tiers; Anthropic uncached input excludes cache reads/writes.
    public var contextTokens: Int? {
        guard countsAreValid, let input else { return nil }
        if accounting == .exclusive {
            guard let cacheRead, let cacheWrite else { return nil }
            return input + cacheRead + cacheWrite
        }
        return accounting == .inclusive ? input : nil
    }
    private var countsAreValid: Bool {
        [input, output, cacheRead, cacheWrite, reasoning, inputAudio, outputAudio].compactMap { $0 }.allSatisfy { (0...100_000_000).contains($0) }
    }
    public func billable(for price: PriceSchedule) -> BillableUsage {
        guard countsAreValid, let input, let output, cacheRead != nil, cacheWrite != nil,
              accounting != .unknown, !extraBillingUnknown else { return .init(values: [:]) }
        // Cached audio overlaps the cached-input and audio totals. No cross-bucket detail, no estimate.
        if (inputAudio ?? 0) > 0 && (cacheRead ?? 0) + (cacheWrite ?? 0) > 0 { return .init(values: [:]) }
        let dimensions = Set(price.rules.map(\.dimension))
        var values: [UsageDimension: Decimal] = [:]
        var ordinaryInput = input, ordinaryOutput = output
        if dimensions.contains(.cacheReadTokens) {
            guard let cacheRead else { return .init(values: [:]) }
            values[.cacheReadTokens] = Decimal(cacheRead)
            if accounting == .inclusive { ordinaryInput -= cacheRead }
        } else if let cacheRead, cacheRead > 0 { return .init(values: [:]) }
        if dimensions.contains(.cacheWriteTokens) {
            guard let cacheWrite else { return .init(values: [:]) }
            values[.cacheWriteTokens] = Decimal(cacheWrite)
            if accounting == .inclusive { ordinaryInput -= cacheWrite }
        } else if let cacheWrite, cacheWrite > 0 { return .init(values: [:]) }
        if dimensions.contains(.reasoningTokens) {
            guard let reasoning else { return .init(values: [:]) }
            values[.reasoningTokens] = Decimal(reasoning); ordinaryOutput -= reasoning
        }
        if dimensions.contains(.inputAudioTokens) {
            guard let inputAudio else { return .init(values: [:]) }
            values[.inputAudioTokens] = Decimal(inputAudio); ordinaryInput -= inputAudio
        } else if let inputAudio, inputAudio > 0 { return .init(values: [:]) }
        if dimensions.contains(.outputAudioTokens) {
            guard let outputAudio else { return .init(values: [:]) }
            values[.outputAudioTokens] = Decimal(outputAudio); ordinaryOutput -= outputAudio
        } else if let outputAudio, outputAudio > 0 { return .init(values: [:]) }
        guard ordinaryInput >= 0, ordinaryOutput >= 0 else { return .init(values: [:]) }
        values[.inputTokens] = Decimal(ordinaryInput); values[.outputTokens] = Decimal(ordinaryOutput)
        return .init(values: values, contextTokens: contextTokens, complete: true)
    }
}

public enum TokenUsageParser {
    public static func parse(_ data: Data, api: APIProtocol) -> TokenUsage {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return .init() }
        return parse(json, api: api)
    }
    public static func parse(_ json: [String: Any], api: APIProtocol) -> TokenUsage {
        let count = ModelCatalog.nonnegativeInt
        switch api {
        case .openAIChat, .openAIResponses:
            let usage = json["usage"] as? [String: Any] ?? [:]
            let inputs = usage[api == .openAIResponses ? "input_tokens_details" : "prompt_tokens_details"] as? [String: Any] ?? [:]
            let outputs = usage[api == .openAIResponses ? "output_tokens_details" : "completion_tokens_details"] as? [String: Any] ?? [:]
            return .init(input: count(usage[api == .openAIResponses ? "input_tokens" : "prompt_tokens"]),
                output: count(usage[api == .openAIResponses ? "output_tokens" : "completion_tokens"]),
                cacheRead: count(inputs["cached_tokens"]), cacheWrite: 0, reasoning: count(outputs["reasoning_tokens"]),
                inputAudio: count(inputs["audio_tokens"]) ?? 0, outputAudio: count(outputs["audio_tokens"]) ?? 0, accounting: .inclusive)
        case .anthropic:
            let usage = json["usage"] as? [String: Any] ?? [:]
            let cache = usage["cache_creation"] as? [String: Any] ?? [:]
            let server = usage["server_tool_use"] as? [String: Any] ?? [:]
            let writes = count(usage["cache_creation_input_tokens"])
            let ttlUnknown = (writes ?? 0) > 0 && count(cache["ephemeral_5m_input_tokens"]) != writes
            return .init(input: count(usage["input_tokens"]), output: count(usage["output_tokens"]),
                cacheRead: count(usage["cache_read_input_tokens"]), cacheWrite: count(usage["cache_creation_input_tokens"]),
                reasoning: nil, inputAudio: 0, outputAudio: 0, accounting: .exclusive,
                extraBillingUnknown: ttlUnknown || (count(cache["ephemeral_1h_input_tokens"]) ?? 0) > 0 || server.values.contains { (count($0) ?? 0) > 0 })
        case .gemini:
            let usage = json["usageMetadata"] as? [String: Any] ?? [:]
            let input = count(usage["promptTokenCount"]), visible = count(usage["candidatesTokenCount"]), total = count(usage["totalTokenCount"])
            var thoughts = count(usage["thoughtsTokenCount"])
            if thoughts == nil, let input, let visible, let total, total == input + visible { thoughts = 0 }
            let output = visible.flatMap { visible in thoughts.map { visible + $0 } }
            return .init(input: input, output: output, cacheRead: count(usage["cachedContentTokenCount"]), cacheWrite: 0,
                reasoning: thoughts, inputAudio: 0, outputAudio: 0, accounting: .inclusive,
                extraBillingUnknown: (count(usage["toolUsePromptTokenCount"]) ?? 0) > 0)
        default: return .init()
        }
    }
    public static func account(_ data: Data, channel: ChannelType) -> TokenUsage {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return parse(json["response"] as? [String: Any] ?? json, api: channel.apiProtocol)
        }
        guard let frames = try? SSE.frames(data) else { return .init() }
        var result = TokenUsage()
        for frame in frames {
            guard let json = try? JSONSerialization.jsonObject(with: Data(frame.utf8)) as? [String: Any] else { continue }
            let object = json["response"] as? [String: Any] ?? json
            let usage = parse(object, api: channel.apiProtocol)
            // SSE usage is cumulative snapshots, not token deltas. Never sum repeated frames.
            if usage.input != nil || usage.output != nil { result = usage }
        }
        return result
    }
}

public struct TextGenerationResult: Equatable, Sendable {
    public var text: String
    public var usage: TokenUsage
    public init(text: String, usage: TokenUsage = .init()) { self.text = text; self.usage = usage }
}
public enum CostKnowledge: String, Codable, Sendable { case estimate, unknown, subscription, stalePrice }
public struct UsageRecord: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID
    public var completedAt: Date
    public var offering: OfferingIdentity
    public var apiProtocol: APIProtocol
    public var backend: TextBackend
    public var reasoning: ReasoningSelection
    public var usage: TokenUsage
    public var costKnowledge: CostKnowledge
    public var priceSnapshotID: String?
    public var currency: String?
    public var estimatedAmount: Decimal?
    public init(provider: Provider, modelID: String, api: APIProtocol, result: TextGenerationResult, at date: Date = Date()) {
        id = UUID(); completedAt = date; offering = .init(connectionID: provider.id, remoteModelID: modelID)
        apiProtocol = api; backend = provider.textBackend; usage = result.usage
        let model = provider.models.first { $0.id == modelID }; reasoning = model?.reasoningSelection ?? .init()
        if provider.channelType.isSubscription { costKnowledge = .subscription; return }
        guard let price = model?.price else { costKnowledge = .unknown; return }
        priceSnapshotID = price.id
        guard !price.isStale(at: date) else { costKnowledge = .stalePrice; return }
        guard let estimate = price.estimate(usage.billable(for: price)) else { costKnowledge = .unknown; return }
        costKnowledge = .estimate; currency = estimate.currency; estimatedAmount = estimate.amount
    }
    public var costSummary: String {
        switch costKnowledge {
        case .subscription: "订阅 · 非 API 账单"
        case .stalePrice: "价格过期 · 未估算"
        case .unknown: "费用待确认"
        case .estimate:
            if let currency, let estimatedAmount { "约 \(currency) \(PriceSchedule.number(estimatedAmount))" } else { "费用待确认" }
        }
    }
}
