import Foundation

public enum BillingMode: String, Codable, Sendable { case metered, subscription, local, unknown }
public enum UsageDimension: String, Codable, CaseIterable, Sendable {
    // All token quantities are disjoint billing buckets, not inclusive totals.
    case inputTokens, outputTokens, reasoningTokens, cacheReadTokens, cacheWriteTokens
    case inputAudioTokens, outputAudioTokens, audioSeconds, characters, images, videoSeconds, requests
    public var title: String {
        switch self {
        case .inputTokens: "输入"
        case .outputTokens: "输出"
        case .reasoningTokens: "独立思考"
        case .cacheReadTokens: "缓存读取"
        case .cacheWriteTokens: "缓存写入"
        case .inputAudioTokens: "音频输入"
        case .outputAudioTokens: "音频输出"
        case .audioSeconds: "音频时长"
        case .characters: "字符"
        case .images: "图片"
        case .videoSeconds: "视频时长"
        case .requests: "请求"
        }
    }
    public var unitTitle: String {
        switch self {
        case .audioSeconds, .videoSeconds: "秒"
        case .characters: "字符"
        case .images: "张"
        case .requests: "次"
        default: "token"
        }
    }
}
public struct PriceConditions: Codable, Equatable, Sendable {
    public var contextAbove: Int?
    public var contextAtMost: Int?
    public var attributes: [String: String] = [:]
    public init(contextAbove: Int? = nil, contextAtMost: Int? = nil, attributes: [String: String] = [:]) {
        self.contextAbove = contextAbove; self.contextAtMost = contextAtMost; self.attributes = attributes
    }
    public func matches(contextTokens: Int?, attributes actual: [String: String]) -> Bool {
        if let contextAbove { guard let contextTokens, contextTokens > contextAbove else { return false } }
        if let contextAtMost { guard let contextTokens, contextTokens <= contextAtMost else { return false } }
        return attributes.allSatisfy { actual[$0.key] == $0.value }
    }
}
public struct PriceRule: Codable, Equatable, Sendable {
    public var dimension: UsageDimension
    public var quantity: Decimal
    public var amount: Decimal
    public var conditions: PriceConditions
    public init(_ dimension: UsageDimension, amount: Decimal, per quantity: Decimal, conditions: PriceConditions = .init()) {
        self.dimension = dimension; self.amount = amount; self.quantity = quantity; self.conditions = conditions
    }
}
/// A snapshot, not an invoice. Nil price is unknown, never zero/free.
public struct PriceSchedule: Codable, Equatable, Sendable {
    public var id: String
    public var mode: BillingMode
    public var currency: String
    public var effectiveFrom: Date?
    public var evidence: MetadataEvidence
    public var rules: [PriceRule]
    public init(id: String, mode: BillingMode = .metered, currency: String = "USD", effectiveFrom: Date? = nil,
                evidence: MetadataEvidence, rules: [PriceRule] = []) {
        self.id = id; self.mode = mode; self.currency = currency; self.effectiveFrom = effectiveFrom
        self.evidence = evidence; self.rules = rules
    }
    public func isStale(at date: Date = Date()) -> Bool {
        guard let fetched = evidence.fetchedAt else { return evidence.origin != .user }
        return date.timeIntervalSince(fetched) > 14 * 86400
    }
    public var summary: String {
        switch mode {
        case .subscription: return "订阅 · 额度以账户为准"
        case .local: return "本机 · 成本待确认"
        case .unknown: return "价格待确认"
        case .metered:
            let base = rules.filter { $0.conditions == PriceConditions() }
            guard !base.isEmpty else { return "分条件计费" }
            return base.prefix(2).map {
                "\($0.dimension.title) \(currency) \(Self.number($0.amount))/\(Self.number($0.quantity)) \($0.dimension.unitTitle)"
            }.joined(separator: "；")
        }
    }
    public static func number(_ value: Decimal) -> String { NSDecimalNumber(decimal: value).stringValue }
    /// Missing metrics/rates/conditions or ambiguous tiers produce unknown, not an underestimated total.
    public func estimate(_ usage: BillableUsage) -> CostEstimate? {
        guard mode == .metered, usage.complete, usage.values.values.allSatisfy({ $0 >= 0 }) else { return nil }
        var total: Decimal = 0
        for (dimension, count) in usage.values where count > 0 {
            let matching = rules.filter { $0.dimension == dimension && $0.conditions.matches(contextTokens: usage.contextTokens, attributes: usage.attributes) }
            guard matching.count == 1, let rule = matching.first, rule.quantity > 0, rule.amount >= 0 else { return nil }
            total += count * rule.amount / rule.quantity
        }
        return .init(priceSnapshotID: id, currency: currency, amount: total)
    }
}
public struct BillableUsage: Equatable, Sendable {
    public var values: [UsageDimension: Decimal]
    public var contextTokens: Int?
    public var attributes: [String: String]
    public var complete: Bool
    public init(values: [UsageDimension: Decimal], contextTokens: Int? = nil, attributes: [String: String] = [:], complete: Bool = false) {
        self.values = values; self.contextTokens = contextTokens; self.attributes = attributes; self.complete = complete
    }
}
public struct CostEstimate: Equatable, Sendable {
    public var priceSnapshotID: String
    public var currency: String
    public var amount: Decimal
}
