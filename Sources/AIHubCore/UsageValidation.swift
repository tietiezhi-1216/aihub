import Foundation

extension UsageRecord {
    public func validate() throws {
        _ = try Validation.modelID(offering.remoteModelID)
        let counts = [usage.input, usage.output, usage.cacheRead, usage.cacheWrite, usage.reasoning, usage.inputAudio, usage.outputAudio].compactMap { $0 }
        guard counts.allSatisfy({ (0...100_000_000).contains($0) }), reasoning.effort.map(ModelCatalog.safeControl) ?? true,
              reasoning.budget.map({ (-1...65_536).contains($0) }) ?? true else { throw HubError("用量记录字段无效。") }
        if let amount = estimatedAmount { guard !amount.isNaN, amount >= 0 else { throw HubError("用量金额无效。") } }
        if let currency { guard currency.count == 3 && currency.allSatisfy({ $0.isASCII && $0.isUppercase }) else { throw HubError("用量货币无效。") } }
        if costKnowledge == .estimate, estimatedAmount == nil || currency == nil || priceSnapshotID == nil { throw HubError("用量估算记录不完整。") }
    }
}
