import Foundation
import Testing
@testable import AIHubCore

struct ModelPricingTests {
    @Test func decimalRatesPreservePrecisionAndUnitScale() throws {
        let raw: [String: Any] = ["prompt": "0.000000123456789", "completion": "0.000002"]
        let price = try #require(PriceCatalog.service(raw, currency: "USD", at: Date(), source: "服务"))
        let estimate = try #require(price.estimate(.init(values: [.inputTokens: 1_000_000, .outputTokens: 100], complete: true)))
        #expect(estimate.amount == Decimal(string: "0.123656789"))
        #expect(estimate.priceSnapshotID == price.id)
    }
    @Test func tieredRatesRequireContextAndSelectExactlyOneRule() throws {
        let price = try #require(PriceCatalog.publicCatalog(["input": 2, "output": 8, "tiers": [["tier": ["size": 200_000], "input": 4, "output": 12]]], at: Date()))
        #expect(price.estimate(.init(values: [.inputTokens: 1_000_000], complete: true)) == nil)
        #expect(price.estimate(.init(values: [.inputTokens: 1_000_000], contextTokens: 200_000, complete: true))?.amount == 2)
        #expect(price.estimate(.init(values: [.inputTokens: 1_000_000], contextTokens: 200_001, complete: true))?.amount == 4)
    }
    @Test func pricesHaveStableContentIDsButIndependentRetrievalDates() throws {
        let raw: [String: Any] = ["input": 2, "output": 8]
        let a = try #require(PriceCatalog.publicCatalog(raw, at: Date(timeIntervalSince1970: 1)))
        let b = try #require(PriceCatalog.publicCatalog(raw, at: Date(timeIntervalSince1970: 2)))
        #expect(a.id == b.id && a.evidence.fetchedAt != b.evidence.fetchedAt)
        let changed = try #require(PriceCatalog.publicCatalog(["input": 3, "output": 8], at: Date()))
        #expect(changed.id != a.id)
        #expect(try JSONDecoder().decode(PriceSchedule.self, from: JSONEncoder().encode(a)) == a)
    }
    @Test func missingRatesIncompleteUsageAndSubscriptionNeverBecomeZero() throws {
        let price = try #require(PriceCatalog.publicCatalog(["input": 2, "output": 8], at: Date()))
        #expect(price.estimate(.init(values: [.inputTokens: 100])) == nil)
        #expect(price.estimate(.init(values: [.audioSeconds: 60], complete: true)) == nil)
        #expect(price.estimate(.init(values: [.inputTokens: -1], complete: true)) == nil)
        var subscription = price; subscription.mode = .subscription
        #expect(subscription.estimate(.init(values: [.inputTokens: 100], complete: true)) == nil)
        #expect(AIModel(id: "unknown").priceSummary.contains("待确认"))
    }
    @Test func cacheBucketsAreExplicitAndNotAddedOnTopOfInclusiveInput() {
        let price = PriceSchedule(id: "snapshot", evidence: .init(.user, source: "用户"), rules: [
            .init(.inputTokens, amount: 2, per: 1_000_000), .init(.cacheReadTokens, amount: Decimal(string: "0.2")!, per: 1_000_000)
        ])
        let quote = price.estimate(.init(values: [.inputTokens: 500_000, .cacheReadTokens: 500_000], complete: true))
        #expect(quote?.amount == Decimal(string: "1.1"))
    }
    @Test func nonTokenRulesSupportResolutionAndAudioDuration() {
        let price = PriceSchedule(id: "mixed", currency: "CNY", evidence: .init(.user, source: "用户"), rules: [
            .init(.images, amount: 1, per: 1, conditions: .init(attributes: ["size": "1024"])),
            .init(.audioSeconds, amount: 6, per: 60)
        ])
        #expect(price.estimate(.init(values: [.images: 2], complete: true)) == nil)
        #expect(price.estimate(.init(values: [.images: 2, .audioSeconds: 30], attributes: ["size": "1024"], complete: true))?.amount == 5)
    }
    @Test func oldPriceVersionsRemainResolvableAfterNewRatesArrive() throws {
        let old = try #require(PriceCatalog.publicCatalog(["input": 2, "output": 8], at: Date(timeIntervalSince1970: 1)))
        let new = try #require(PriceCatalog.publicCatalog(["input": 3, "output": 8], at: Date()))
        var model = AIModel(id: "gpt-test"); model.price = old
        var settings = AppSettings(); settings.providers = [Provider(name: "API", baseURL: "https://example.com/v1", models: [model])]
        settings.reconcileSelections()
        settings.providers[0].models[0].price = new; settings.reconcileSelections()
        #expect(settings.priceSnapshots[old.id] == old && settings.priceSnapshots[new.id] == new)
        #expect(old.isStale() && !new.isStale())
        #expect(try JSONDecoder().decode(AppSettings.self, from: JSONEncoder().encode(settings)).priceSnapshots == settings.priceSnapshots)
    }
    @Test func malformedRatesUnknownUnitsAndOverridesAreNotGuessed() {
        for value in ["NaN", "-1", "0.1USD", "1,000", "Infinity"] { #expect(PriceCatalog.decimal(value) == nil) }
        #expect(PriceCatalog.decimal(true) == nil)
        #expect(PriceCatalog.service(["prompt": "1"], currency: nil, at: Date(), source: "服务") == nil)
        #expect(PriceCatalog.service(["prompt": "1", "overrides": [:]], currency: "USD", at: Date(), source: "服务") == nil)
        #expect(PriceCatalog.service(["image_output": "0.01"], currency: "USD", at: Date(), source: "服务") == nil)
    }
}
