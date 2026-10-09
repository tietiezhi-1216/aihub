import Foundation

extension ModelOffering {
    /// Bound persisted/configurable metadata too, not just network discovery payloads.
    public func validateMetadata() throws {
        _ = try Validation.modelID(id)
        guard metadata.tasks.count <= ModelTask.allCases.count, metadata.bindings.count <= 16,
              metadata.evidence.count <= 32, verifications.count <= 128,
              inputModalities.count <= 16, outputModalities.count <= 16,
              generationMethods.count <= 64,
              metadata.reasoning.efforts.count <= 16, metadata.reasoning.modes.count <= 16,
              metadata.reasoning.efforts.allSatisfy(ModelCatalog.safeControl),
              metadata.reasoning.modes.allSatisfy(ModelCatalog.safeControl),
              generationMethods.allSatisfy({ ModelCatalog.safeText($0, maximum: 128) != nil }) else {
            throw HubError("模型元数据超过限制或含无效字段。")
        }
        let numbers = [metadata.limits.context, metadata.limits.input, metadata.limits.output,
                       metadata.reasoning.minimumBudget, metadata.reasoning.maximumBudget].compactMap { $0 }
        guard numbers.allSatisfy({ (0...100_000_000).contains($0) }) else { throw HubError("模型限制或思考预算无效。") }
        if let min = metadata.reasoning.minimumBudget, let max = metadata.reasoning.maximumBudget, min > max { throw HubError("模型思考预算范围无效。") }
        for evidence in Array(metadata.evidence.values) + metadata.bindings.map(\.evidence) + [metadata.reasoning.evidence, definition?.evidence, price?.evidence].compactMap({ $0 }) {
            guard ModelCatalog.safeText(evidence.source, maximum: 512) != nil else { throw HubError("模型信息来源无效。") }
        }
        if let limit = outputTokenLimit, !(1...65_536).contains(limit) { throw HubError("输出上限无效。") }
        if let selection = reasoningSelection {
            if let effort = selection.effort, !ModelCatalog.safeControl(effort) { throw HubError("思考等级字段无效。") }
            if let budget = selection.budget, !(-1...65_536).contains(budget) { throw HubError("思考预算字段无效。") }
        }
        if let definition {
            _ = try Validation.modelID(definition.identity.modelID)
            guard ModelCatalog.safeText(definition.identity.namespace, maximum: 128) != nil,
                  ModelCatalog.safeText(definition.name, maximum: 256) != nil else { throw HubError("模型参考身份无效。") }
        }
        if let price {
            guard price.rules.count <= 128, ModelCatalog.safeText(price.id, maximum: 128) != nil,
                  price.currency.count == 3, price.currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else { throw HubError("模型价格格式无效。") }
            for rule in price.rules {
                guard !rule.amount.isNaN, !rule.quantity.isNaN, rule.amount >= 0, rule.quantity > 0,
                      rule.conditions.attributes.count <= 16,
                      rule.conditions.attributes.allSatisfy({ ModelCatalog.safeText($0.key, maximum: 64) != nil && ModelCatalog.safeText($0.value, maximum: 128) != nil }) else {
                    throw HubError("模型价格规则无效。")
                }
            }
        }
    }
}
