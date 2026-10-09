import Foundation
import Testing
@testable import AIHubCore

struct TokenUsageTests {
    @Test func openAIInclusiveCacheAndReasoningBecomeDisjointBuckets() throws {
        let usage = TokenUsageParser.parse(Data(#"{"usage":{"prompt_tokens":1000,"completion_tokens":600,"prompt_tokens_details":{"cached_tokens":400},"completion_tokens_details":{"reasoning_tokens":200}}}"#.utf8), api: .openAIChat)
        let price = PriceSchedule(id: "snapshot", evidence: .init(.user, source: "用户"), rules: [
            .init(.inputTokens, amount: 2, per: 1000), .init(.cacheReadTokens, amount: 1, per: 1000),
            .init(.outputTokens, amount: 4, per: 1000), .init(.reasoningTokens, amount: 3, per: 1000)
        ])
        let billable = usage.billable(for: price)
        #expect(billable.values[.inputTokens] == 600 && billable.values[.outputTokens] == 400)
        #expect(billable.values[.cacheReadTokens] == 400 && billable.values[.reasoningTokens] == 200)
        #expect(price.estimate(billable)?.amount == Decimal(string: "3.8"))
    }
    @Test func thinkingIncludedInOutputIsNotCountedTwiceWithoutASeparateRate() {
        let usage = TokenUsage(input: 100, output: 600, cacheRead: 0, cacheWrite: 0, reasoning: 200, accounting: .inclusive)
        let price = PriceSchedule(id: "snapshot", evidence: .init(.user, source: "用户"), rules: [.init(.inputTokens, amount: 1, per: 1000), .init(.outputTokens, amount: 2, per: 1000)])
        #expect(usage.billable(for: price).values[.outputTokens] == 600)
        #expect(price.estimate(usage.billable(for: price))?.amount == Decimal(string: "1.3"))
    }
    @Test func anthropicUncachedInputDoesNotSubtractCacheAgainAndContextIncludesAllInputs() {
        let usage = TokenUsageParser.parse(Data(#"{"usage":{"input_tokens":100,"output_tokens":50,"cache_read_input_tokens":400,"cache_creation_input_tokens":200,"cache_creation":{"ephemeral_5m_input_tokens":200}}}"#.utf8), api: .anthropic)
        let price = PriceSchedule(id: "snapshot", evidence: .init(.user, source: "用户"), rules: [
            .init(.inputTokens, amount: 1, per: 1000), .init(.outputTokens, amount: 2, per: 1000),
            .init(.cacheReadTokens, amount: 1, per: 1000), .init(.cacheWriteTokens, amount: 1, per: 1000)
        ])
        #expect(usage.contextTokens == 700 && usage.billable(for: price).values[.inputTokens] == 100)
        #expect(price.estimate(usage.billable(for: price))?.amount == Decimal(string: "0.8"))
    }
    @Test func geminiVisibleAndThoughtTokensAreCombinedExactlyOnce() {
        let usage = TokenUsageParser.parse(Data(#"{"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":50,"thoughtsTokenCount":200,"totalTokenCount":350,"cachedContentTokenCount":20}}"#.utf8), api: .gemini)
        #expect(usage.output == 250 && usage.reasoning == 200 && usage.cacheRead == 20)
        let old = TokenUsageParser.parse(Data(#"{"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":50,"totalTokenCount":150}}"#.utf8), api: .gemini)
        #expect(old.output == 50 && old.reasoning == 0)
        let ambiguous = TokenUsageParser.parse(Data(#"{"usageMetadata":{"promptTokenCount":100,"candidatesTokenCount":50,"totalTokenCount":350}}"#.utf8), api: .gemini)
        #expect(ambiguous.output == nil)
    }
    @Test func repeatedSSEUsageSnapshotsAreNotSummed() {
        let data = Data(("data: " + #"{"type":"response.completed","response":{"usage":{"input_tokens":100,"output_tokens":50}}}"# + "\n\n").utf8)
        let usage = TokenUsageParser.account(data + data, channel: .codex)
        #expect(usage.input == 100 && usage.output == 50)
    }
    @Test func unknownMissingAndInconsistentCountsDoNotProduceZeroFees() {
        let price = PriceSchedule(id: "snapshot", evidence: .init(.user, source: "用户"), rules: [.init(.inputTokens, amount: 1, per: 1), .init(.outputTokens, amount: 1, per: 1), .init(.cacheReadTokens, amount: 1, per: 1)])
        #expect(price.estimate(TokenUsage().billable(for: price)) == nil)
        let missingCache = TokenUsage(input: 100, output: 50, accounting: .inclusive)
        #expect(price.estimate(missingCache.billable(for: price)) == nil)
        let invalid = TokenUsage(input: 100, output: 50, cacheRead: 200, accounting: .inclusive)
        #expect(price.estimate(invalid.billable(for: price)) == nil)
        let boolean = TokenUsageParser.parse(Data(#"{"usage":{"prompt_tokens":true,"completion_tokens":-1}}"#.utf8), api: .openAIChat)
        #expect(boolean.input == nil && boolean.output == nil)
    }
    @Test func unsupportedLongTTLAndToolBillingRemainUnknown() {
        let usage = TokenUsageParser.parse(Data(#"{"usage":{"input_tokens":100,"output_tokens":50,"cache_creation":{"ephemeral_1h_input_tokens":100}}}"#.utf8), api: .anthropic)
        #expect(usage.extraBillingUnknown)
    }
    @Test func ledgerStoresCountsNotUserTextAndPricesAreCapturedByVersion() throws {
        var model = AIModel(id: "gpt-test")
        model.price = PriceSchedule(id: "version1", evidence: .init(.user, source: "用户"), rules: [.init(.inputTokens, amount: 1, per: 100), .init(.outputTokens, amount: 2, per: 100)])
        let provider = Provider(name: "PRIVATE_EMAIL", baseURL: "https://api.openai.com/v1", models: [model])
        let result = TextGenerationResult(text: "PRIVATE_USER_TEXT", usage: .init(input: 100, output: 50, cacheRead: 0, cacheWrite: 0, accounting: .inclusive))
        let record = UsageRecord(provider: provider, modelID: model.id, api: .openAIChat, result: result)
        #expect(record.estimatedAmount == 2 && record.priceSnapshotID == "version1")
        let encoded = try JSONEncoder().encode(record), text = String(decoding: encoded, as: UTF8.self)
        #expect(!text.contains("PRIVATE_USER_TEXT") && !text.contains("PRIVATE_EMAIL"))
        #expect(try JSONDecoder().decode(UsageRecord.self, from: encoded) == record)
    }
    @Test func subscriptionAndStalePricesAreNotTreatedAsFree() {
        var provider = Provider(name: "", baseURL: ""); provider.selectChannel(.codex)
        let result = TextGenerationResult(text: "结果", usage: .init(input: 100, output: 50))
        let account = UsageRecord(provider: provider, modelID: "gpt-test", api: .openAIResponses, result: result)
        #expect(account.costKnowledge == .subscription && account.estimatedAmount == nil)
        var model = AIModel(id: "gpt-test")
        model.price = PriceSchedule(id: "old", evidence: .init(.publicCatalog, source: "目录", at: Date(timeIntervalSince1970: 1)), rules: [])
        let api = Provider(name: "API", baseURL: "https://api.openai.com/v1", models: [model])
        let record = UsageRecord(provider: api, modelID: model.id, api: .openAIChat, result: result)
        #expect(record.costKnowledge == .stalePrice && record.estimatedAmount == nil)
    }
    @Test func missingCacheCountsRemainUnknownEvenWithoutListedCacheDiscount() {
        let price = PriceSchedule(id: "partial", evidence: .init(.user, source: "用户"), rules: [.init(.inputTokens, amount: 1, per: 1), .init(.outputTokens, amount: 1, per: 1)])
        #expect(price.estimate(TokenUsage(input: 100, output: 50, accounting: .inclusive).billable(for: price)) == nil)
    }
    @Test func officialChatUsesCompletionCapWithoutInventingDefaultThinking() throws {
        let data = Data(#"{"model":"new-unrecognized-model","max_tokens":4096,"messages":[]}"#.utf8)
        let options = TextCallOptions(usesCompletionLimit: true)
        let body = try #require(try JSONSerialization.jsonObject(with: ReasoningWire.apply(data, api: .openAIChat, options: options)) as? [String: Any])
        #expect(body["max_tokens"] == nil && body["max_completion_tokens"] as? Int == 4096)
        #expect(body["reasoning_effort"] == nil)
    }
    @Test func ambiguousCachedAudioIsNotCountedTwice() {
        let price = PriceSchedule(id: "audio", evidence: .init(.user, source: "用户"), rules: [.init(.inputTokens, amount: 1, per: 1), .init(.cacheReadTokens, amount: 1, per: 1), .init(.inputAudioTokens, amount: 1, per: 1), .init(.outputTokens, amount: 1, per: 1)])
        let usage = TokenUsage(input: 1000, output: 50, cacheRead: 100, cacheWrite: 0, inputAudio: 200, accounting: .inclusive)
        #expect(price.estimate(usage.billable(for: price)) == nil)
    }
    @Test func versionTwoAlsoMigratesWithoutRecordingOrBackendChanges() throws {
        var provider = Provider(name: "原连接", baseURL: "https://api.openai.com/v1", models: [AIModel(id: "gpt-test")])
        provider.textBackend = .builtIn
        var settings = AppSettings(); settings.providers = [provider]
        var json = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(settings)) as? [String: Any])
        json["version"] = 2; json["recordsUsage"] = nil; json["usageRecords"] = nil
        let migrated = try JSONDecoder().decode(AppSettings.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(migrated.version == 3 && migrated.providers[0].id == provider.id && migrated.providers[0].textBackend == .builtIn)
        #expect(!migrated.recordsUsage && migrated.usageRecords.isEmpty)
        #expect(throws: HubError.self) { try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":4,"providers":[]}"#.utf8)) }
    }
    @Test func ASRVerificationNeverDependsOnTextThinkingPreference() {
        var model = AIModel(id: "dual"); model.reasoningSelection = .init(effort: "high")
        model.verify(task: .transcription, api: .openAIChat, backend: .builtIn)
        model.verify(task: .transcription, api: .openAIChat, backend: .builtIn)
        #expect(model.verifications.count == 1 && model.verifications[0].reasoning == nil)
        model.verify(task: .textGeneration, api: .openAIChat, backend: .builtIn)
        #expect(model.verifications.last?.reasoning?.effort == "high")
    }
    @Test func oldSettingsDisableRecordingAndKeepDefaultThinking() throws {
        let settings = try JSONDecoder().decode(AppSettings.self, from: Data(#"{"version":1,"providers":[]}"#.utf8))
        #expect(!settings.recordsUsage && settings.usageRecords.isEmpty)
        let model = try JSONDecoder().decode(AIModel.self, from: Data(#"{"id":"gpt-test","capability":"chat"}"#.utf8))
        #expect(model.reasoningSelection == nil && model.outputTokenLimit == nil)
    }
}
