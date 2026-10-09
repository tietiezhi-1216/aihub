import Foundation
import Testing
@testable import AIHubCore

struct ModelGroupingTests {
    private func model(_ id: String, _ name: String? = nil) -> AIModel { AIModel(id: id, displayName: name) }
    private func provider(_ models: [AIModel]) -> Provider {
        var provider = Provider(name: "", baseURL: "")
        provider.selectChannel(.antigravity); provider.models = models
        return provider
    }
    private func legacyJSON(_ provider: Provider) throws -> [String: Any] {
        let value = try #require(try JSONSerialization.jsonObject(with: JSONEncoder().encode(provider)) as? [String: Any])
        let connection = try #require(value["connection"] as? [String: Any])
        let catalog = try #require(value["catalog"] as? [String: Any])
        return connection.merging(catalog) { _, right in right }
    }
    @Test func highAndLowBecomeOneFamilyWithoutLosingIDs() throws {
        let models = [model("gemini-3.1-pro-high", "Gemini 3.1 Pro (High)"), model("gemini-3.1-pro-low", "Gemini 3.1 Pro (Low)")]
        let provider = provider(models)
        let group = try #require(provider.modelGroups.first)
        #expect(provider.modelGroups.count == 1 && provider.models.count == 2)
        #expect(group.id == "gemini-3.1-pro" && group.name == "Gemini 3.1 Pro")
        #expect(group.thinkingOptions == [.low, .high])
        #expect(group.selected().model.id == "gemini-3.1-pro-low")
        #expect(group.variants.map { $0.model.id }.sorted() == models.map(\.id).sorted())
        #expect(group.matches(category: .chat, search: "high"))
    }
    @Test func serviceTierLabelOverridesLegacyIDAndAgentAliasesStayRoutable() throws {
        let models = [model("gemini-3.5-flash-extra-low", "Gemini 3.5 Flash (Low)"),
                      model("gemini-3.5-flash-low", "Gemini 3.5 Flash (Medium)"),
                      model("gemini-3-flash-agent", "Gemini 3.5 Flash (High)")]
        let groups = provider(models).modelGroups
        let group = try #require(groups.first)
        #expect(groups.count == 1 && group.id == "gemini-3.5-flash")
        #expect(group.thinkingOptions == [.low, .medium, .high])
        #expect(group.variant(for: .medium)?.model.id == "gemini-3.5-flash-low")
        #expect(group.variant(for: .high)?.model.id == "gemini-3-flash-agent")
    }
    @Test func duplicateTierAliasesHaveOneOptionAndPreserveExistingRoute() throws {
        let models = [model("gemini-3.1-pro-high", "Gemini 3.1 Pro (High)"),
                      model("gemini-pro-agent", "Gemini 3.1 Pro (High)"),
                      model("gemini-3.1-pro-low", "Gemini 3.1 Pro (Low)")]
        var provider = provider(models)
        let group = try #require(provider.modelGroups.first)
        #expect(provider.modelGroups.count == 1 && group.variants.count == 3)
        #expect(group.thinkingOptions == [.low, .high])
        #expect(provider.selectThinking(.high, in: group.id, currentID: "gemini-pro-agent") == "gemini-pro-agent")
        #expect(group.variant(for: .high)?.model.id == "gemini-3.1-pro-high")
    }
    @Test func onlyThinkingVariantDoesNotInventOffOrOtherTiers() throws {
        let group = try #require(provider([model("claude-sonnet-4-6", "Claude Sonnet 4.6 (Thinking)")]).modelGroups.first)
        #expect(group.name == "Claude Sonnet 4.6" && group.thinkingOptions == [.thinking])
        #expect(group.variant(for: .off) == nil)
    }
    @Test func versionsImagesAndUnknownModelsDoNotMergeByDisplayName() {
        let models = [model("gemini-2.5-flash", "Shared Name"), model("gemini-2.5-flash-lite", "Shared Name"),
                      model("gemini-3.5-flash-lite", "Shared Name"), model("gemini-3.1-flash-image"),
                      model("gemini-3.1-pro-high-preview"), model("unknown-high", "Shared Name")]
        #expect(provider(models).modelGroups.count == models.count)
        #expect(ModelGrouping.groups(models, channel: .gemini).map(\.id) == models.map(\.id))
    }
    @Test func otherChannelsKeepSeparateRows() {
        let models = [model("gemini-pro-high"), model("gemini-pro-low")]
        for channel in [ChannelType.gemini, .codex, .grok, .custom] {
            #expect(ModelGrouping.groups(models, channel: channel).count == 2)
        }
    }
    @Test func selectionRoundtripAndOldConfigurationCompatibility() throws {
        var provider = provider([model("gemini-3.1-pro-high"), model("gemini-3.1-pro-low")])
        _ = provider.selectThinking(.high, in: "gemini-3.1-pro")
        #expect(try JSONDecoder().decode(Provider.self, from: JSONEncoder().encode(provider)) == provider)
        var json = try legacyJSON(provider)
        json["thinkingSelections"] = nil
        let restored = try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(restored.thinkingSelections.isEmpty && restored.models.count == 2)
    }
    @Test func legacyHighSelectionIsPreservedUntilUserChangesThinking() {
        var provider = provider([model("gemini-3.1-pro-high"), model("gemini-3.1-pro-low")])
        var settings = AppSettings(); settings.providers = [provider]
        settings.chatSelection = .init(providerID: provider.id, modelID: "gemini-3.1-pro-high")
        settings.reconcileSelections()
        #expect(settings.chatSelection?.modelID == "gemini-3.1-pro-high")
        _ = provider.selectThinking(.low, in: "gemini-3.1-pro")
        settings.providers = [provider]; settings.reconcileSelections()
        #expect(settings.chatSelection?.modelID == "gemini-3.1-pro-low")
    }
    @Test func refreshPreservesPreferencesAndIndividualVerification() {
        var high = model("gemini-3.1-pro-high"); high.verifiedAt = Date(timeIntervalSince1970: 123)
        var provider = provider([high, model("gemini-3.1-pro-low")])
        _ = provider.selectThinking(.high, in: "gemini-3.1-pro")
        provider.mergeDiscovered([model("gemini-3.1-pro-high"), model("gemini-3.1-pro-low")])
        #expect(provider.thinkingSelections["gemini-3.1-pro"] == high.id)
        #expect(provider.selectedVariant(in: provider.modelGroups[0]).model.verifiedAt == high.verifiedAt)
        _ = provider.selectThinking(.low, in: "gemini-3.1-pro")
        #expect(provider.selectedVariant(in: provider.modelGroups[0]).model.verifiedAt == nil)
        provider.mergeDiscovered([model("gemini-3.1-pro-high")])
        #expect(provider.thinkingSelections.isEmpty)
    }
    @Test func invalidAndUnavailableThinkingChoicesCannotChangeRoute() {
        var high = model("gemini-3.1-pro-high"); high.isAvailable = false
        var provider = provider([high, model("gemini-3.1-pro-low")])
        #expect(provider.selectThinking(.high, in: "gemini-3.1-pro") == nil)
        #expect(provider.selectThinking(.off, in: "gemini-3.1-pro") == nil)
        #expect(provider.thinkingSelections.isEmpty)
        provider.thinkingSelections = ["gemini-3.1-pro": "gemini-other-high"]
        provider.reconcileThinkingSelections()
        #expect(provider.thinkingSelections.isEmpty)
    }
    @Test func thinkingOptionsComeOnlyFromActualCatalogVariants() {
        var provider = provider([model("gemini-3.1-pro-low"), model("gemini-3.1-pro-high")])
        #expect(provider.modelGroups[0].thinkingOptions == [.low, .high])
        #expect(provider.modelGroups[0].variant(for: .medium) == nil)
        #expect(provider.selectThinking(.medium, in: "gemini-3.1-pro") == nil)
        #expect(provider.thinkingSelections.isEmpty)
        // A middle tier appears only if a real directory entry supplies it.
        provider.mergeDiscovered([model("gemini-3.1-pro-low"), model("gemini-3.1-pro-medium"), model("gemini-3.1-pro-high")])
        #expect(provider.modelGroups[0].thinkingOptions == [.low, .medium, .high])
        #expect(provider.selectThinking(.medium, in: "gemini-3.1-pro") == "gemini-3.1-pro-medium")
    }
    @Test func withdrawnExperimentalPreferenceIsNotSilentlyDowngraded() throws {
        let provider = provider([model("gemini-3.1-pro-low"), model("gemini-3.1-pro-high")])
        var json = try legacyJSON(provider)
        json["thinkingSelections"] = ["gemini-3.1-pro": "gemini-3.1-pro-low"]
        json["thinkingOverrides"] = ["gemini-3.1-pro": "medium"]
        let restored = try JSONDecoder().decode(Provider.self, from: JSONSerialization.data(withJSONObject: json))
        var settings = AppSettings(); settings.providers = [restored]
        settings.chatSelection = .init(providerID: restored.id, modelID: "gemini-3.1-pro-low")
        settings.reconcileSelections()
        #expect(settings.chatSelection == nil)
        #expect(settings.providers[0].thinkingSelections.isEmpty)
        #expect(settings.providers[0].models.allSatisfy { $0.verifiedAt == nil })
    }
    @Test func requestBodyUsesChosenRealIDNotFamilyOrInventedThinkingConfig() throws {
        var provider = provider([model("gemini-3.1-pro-high"), model("gemini-3.1-pro-low")])
        _ = provider.selectThinking(.high, in: "gemini-3.1-pro")
        let variant = provider.selectedVariant(in: provider.modelGroups[0])
        let body = try AccountProtocol.generationBody(channel: .antigravity, model: variant.model.id, text: "输入", instruction: "整理", project: "owned-project")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["model"] as? String == "gemini-3.1-pro-high")
        #expect(json["thinkingConfig"] == nil)
    }
}
