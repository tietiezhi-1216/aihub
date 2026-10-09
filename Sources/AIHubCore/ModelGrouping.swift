import Foundation

public enum ModelThinking: String, Codable, CaseIterable, Identifiable, Sendable {
    case standard, off, minimal, low, medium, high, xhigh, thinking, adaptive
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .standard: "默认"
        case .off: "关闭"
        case .minimal: "最低"
        case .low: "低"
        case .medium: "中"
        case .high: "高"
        case .xhigh: "最高"
        case .thinking: "开启"
        case .adaptive: "自动"
        }
    }
}

public struct ModelVariant: Equatable, Sendable {
    public var model: AIModel
    public var thinking: ModelThinking
}

/// Display-only families: raw catalog IDs, metadata and verification remain intact.
/// A family ID must never be sent to a service in place of the selected raw ID.
public struct ModelGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var variants: [ModelVariant]
    public var thinkingOptions: [ModelThinking] {
        ModelThinking.allCases.filter { variant(for: $0) != nil }
    }
    public var hasThinking: Bool { thinkingOptions != [.standard] }
    public var identifierHelp: String { variants.map { $0.model.id }.joined(separator: "\n") }

    public func selected(preferredID: String? = nil, currentID: String? = nil) -> ModelVariant {
        if let current = variants.first(where: { $0.model.id == currentID }) { return current }
        if let preferred = variants.first(where: { $0.model.id == preferredID }) { return preferred }
        let available = variants.filter { $0.model.isAvailable != false }
        let candidates = available.isEmpty ? variants : available
        // Prefer the real base/default route, then the lowest available tier.
        return candidates.first { $0.model.id == id } ?? candidates.first!
    }
    public func variant(for thinking: ModelThinking, preserving currentID: String? = nil) -> ModelVariant? {
        let candidates = variants.filter { $0.thinking == thinking }
        if let actual = candidates.first(where: { $0.model.id == currentID }) ?? candidates.first { return actual }
        return nil
    }
    public func matches(category: ModelCapability?, search: String) -> Bool {
        variants.contains {
            ModelCatalog.matches($0.model, category: category,
                                 search: name.localizedCaseInsensitiveContains(search) ? "" : search)
        }
    }
}

public enum ModelGrouping {
    public static func groups(_ models: [AIModel], channel: ChannelType) -> [ModelGroup] {
        guard channel == .antigravity else {
            return models.map { ModelGroup(id: $0.id, name: $0.name, variants: [ModelVariant(model: $0, thinking: .standard)]) }
        }
        let descriptors = models.map { descriptor($0) }
        let knownIDs = Set(descriptors.map(\.id))
        var buckets: [String: [ModelVariant]] = [:]
        var names: [String: String] = [:]
        for (model, descriptor) in zip(models, descriptors) {
            var identity = descriptor.id
            // Some catalog routes are agent aliases. Merge only into an existing
            // versioned family named by the service, never by name similarity alone.
            if model.id.hasSuffix("-agent"), let alias = descriptor.alias, knownIDs.contains(alias) { identity = alias }
            buckets[identity, default: []].append(ModelVariant(model: model, thinking: descriptor.thinking))
            if names[identity] == nil || model.id == identity { names[identity] = descriptor.name }
        }
        return buckets.map { id, variants in
            let sorted = variants.sorted { a, b in
                let aRank = ModelThinking.allCases.firstIndex(of: a.thinking)!
                let bRank = ModelThinking.allCases.firstIndex(of: b.thinking)!
                if aRank != bRank { return aRank < bRank }
                // Prefer non-alias, explicit tier routes over agent aliases.
                if a.model.id.hasSuffix("-agent") != b.model.id.hasSuffix("-agent") { return !a.model.id.hasSuffix("-agent") }
                return a.model.id.localizedStandardCompare(b.model.id) == .orderedAscending
            }
            return ModelGroup(id: id, name: names[id] ?? id, variants: sorted)
        }.sorted { $0.id.localizedStandardCompare($1.id) == .orderedAscending }
    }

    private struct Descriptor {
        var id: String
        var name: String
        var thinking: ModelThinking
        var alias: String?
    }
    private static func descriptor(_ model: AIModel) -> Descriptor {
        guard model.supportsTextOutput else { return Descriptor(id: model.id, name: model.name, thinking: .standard) }
        let knownFamily = model.id.hasPrefix("gemini-") || model.id.hasPrefix("claude-") || model.id.hasPrefix("gpt-oss-")
        guard knownFamily else { return Descriptor(id: model.id, name: model.name, thinking: .standard) }
        let suffixes: [(String, ModelThinking)] = [
            ("-extra-low", .minimal), ("-minimal", .minimal), ("-xhigh", .xhigh),
            ("-thinking", .thinking), ("-adaptive", .adaptive), ("-medium", .medium),
            ("-high", .high), ("-low", .low), ("-off", .off)
        ]
        var id = model.id
        var level: ModelThinking = .standard
        if let suffix = suffixes.first(where: { id.hasSuffix($0.0) }) {
            id.removeLast(suffix.0.count); level = suffix.1
        }
        var name = model.name
        let labels: [(String, ModelThinking)] = [
            (" (Extra Low)", .minimal), (" (Minimal)", .minimal), (" (XHigh)", .xhigh),
            (" (Thinking)", .thinking), (" (Adaptive)", .adaptive), (" (Medium)", .medium),
            (" (High)", .high), (" (Low)", .low), (" (Off)", .off)
        ]
        if let label = labels.first(where: { name.lowercased().hasSuffix($0.0.lowercased()) }) {
            name.removeLast(label.0.count)
            // The service's explicit label can override a legacy route's tier name.
            level = label.1
        } else if model.displayName == nil { name = id }
        let alias = model.id.hasSuffix("-agent") ? name.lowercased().replacingOccurrences(of: " ", with: "-") : nil
        return Descriptor(id: id, name: name, thinking: level, alias: alias)
    }
}

extension Provider {
    public var modelGroups: [ModelGroup] { ModelGrouping.groups(models, channel: channelType) }
    public func selectedVariant(in group: ModelGroup, currentID: String? = nil) -> ModelVariant {
        group.selected(preferredID: thinkingSelections[group.id], currentID: currentID)
    }
    public mutating func selectThinking(_ thinking: ModelThinking, in groupID: String, currentID: String? = nil) -> String? {
        guard channelType == .antigravity,
              let group = modelGroups.first(where: { $0.id == groupID }),
              let variant = group.variant(for: thinking, preserving: currentID ?? thinkingSelections[groupID]),
              variant.model.isAvailable != false else { return nil }
        thinkingSelections[groupID] = variant.model.id
        return variant.model.id
    }
    public mutating func reconcileThinkingSelections() {
        let groups = modelGroups
        thinkingSelections = thinkingSelections.filter { key, value in
            channelType == .antigravity && groups.contains { $0.id == key && $0.variants.contains { $0.model.id == value } }
        }
    }
}
