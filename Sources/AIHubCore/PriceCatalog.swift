import Foundation
import CryptoKit
import CoreFoundation

public enum PriceCatalog {
    public static func service(_ raw: Any?, currency: String?, at date: Date, source: String) -> PriceSchedule? {
        guard let raw = raw as? [String: Any], let currency,
              currency.count == 3, currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else { return nil }
        let dimensions: [(String, UsageDimension)] = [
            ("prompt", .inputTokens), ("completion", .outputTokens), ("internal_reasoning", .reasoningTokens),
            ("input_cache_read", .cacheReadTokens), ("input_cache_write", .cacheWriteTokens),
            ("audio", .inputAudioTokens), ("audio_output", .outputAudioTokens)
        ]
        let rules = dimensions.compactMap { key, dimension -> PriceRule? in
            guard let amount = decimal(raw[key]) else { return nil }
            return .init(dimension, amount: amount, per: 1)
        }
        // Unparsed overrides make the quote incomplete; don't pretend the base rate is exact.
        guard !rules.isEmpty, raw["overrides"] == nil else { return nil }
        return snapshot(currency: currency, rules: rules, evidence: .init(.service, source: source, at: date))
    }
    public static func publicCatalog(_ raw: Any?, at date: Date) -> PriceSchedule? {
        guard let raw = raw as? [String: Any] else { return nil }
        let dimensions: [(String, UsageDimension)] = [
            ("input", .inputTokens), ("output", .outputTokens), ("reasoning", .reasoningTokens),
            ("cache_read", .cacheReadTokens), ("cache_write", .cacheWriteTokens),
            ("input_audio", .inputAudioTokens), ("output_audio", .outputAudioTokens)
        ]
        var tiers = raw["tiers"] as? [[String: Any]] ?? []
        if let over = raw["context_over_200k"] as? [String: Any], tiers.isEmpty {
            var tier = over; tier["tier"] = ["size": 200_000]; tiers = [tier]
        }
        let boundaries = tiers.compactMap { ModelCatalog.positiveInt(($0["tier"] as? [String: Any])?["size"]) }.sorted()
        guard boundaries.count == tiers.count, Set(boundaries).count == boundaries.count, tiers.count <= 16 else { return nil }
        var rules: [PriceRule] = []
        for (key, dimension) in dimensions {
            guard let base = decimal(raw[key]) else { continue }
            rules.append(.init(dimension, amount: base, per: 1_000_000,
                               conditions: .init(contextAtMost: boundaries.first)))
            for (index, boundary) in boundaries.enumerated() {
                guard let tier = tiers.first(where: { ModelCatalog.positiveInt(($0["tier"] as? [String: Any])?["size"]) == boundary }),
                      let amount = decimal(tier[key]) else { continue }
                rules.append(.init(dimension, amount: amount, per: 1_000_000,
                    conditions: .init(contextAbove: boundary, contextAtMost: index + 1 < boundaries.count ? boundaries[index + 1] : nil)))
            }
        }
        guard !rules.isEmpty else { return nil }
        return snapshot(currency: "USD", rules: rules, evidence: .init(.publicCatalog, source: "https://models.dev/api.json", at: date))
    }
    public static func decimal(_ raw: Any?) -> Decimal? {
        let string: String
        if let value = raw as? String { string = value }
        else if let value = raw as? NSNumber {
            guard CFGetTypeID(value) != CFBooleanGetTypeID() else { return nil }
            string = value.stringValue
        } else { return nil }
        guard string.count <= 64, string.range(of: #"^[0-9]+(?:\.[0-9]+)?(?:[eE][+-]?[0-9]+)?$"#, options: .regularExpression) != nil, let value = Decimal(string: string, locale: Locale(identifier: "en_US_POSIX")),
              !value.isNaN, value >= 0, value <= 1_000_000_000 else { return nil }
        return value
    }
    private static func snapshot(currency: String, rules: [PriceRule], evidence: MetadataEvidence) -> PriceSchedule {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let data = (try? encoder.encode(rules)) ?? Data()
        let digest = SHA256.hash(data: Data(currency.utf8) + data).map { String(format: "%02x", $0) }.joined()
        return .init(id: digest, currency: currency, evidence: evidence, rules: rules)
    }
}
