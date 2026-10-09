import SwiftUI
import AIHubCore

struct UsageView: View {
    @Bindable var state: AppState
    @State private var confirmingClear = false
    @State private var selected: UUID?
    private var records: [UsageRecord] { Array(state.settings.usageRecords.reversed()) }
    private var totals: [String] {
        let currencies = Set(records.compactMap(\.currency)).sorted()
        return currencies.map { currency in
            let total = records.filter { $0.currency == currency && $0.costKnowledge == .estimate }.compactMap(\.estimatedAmount).reduce(Decimal(0), +)
            return "\(currency) \(PriceSchedule.number(total))"
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle("在本机记录文字用量", isOn: Binding(get: { state.settings.recordsUsage }, set: { state.setRecordsUsage($0) }))
                .disabled(state.locked || !state.configurationReady)
            Text("仅保存最近 5000 次成功文字调用的计数与估算，不保存原文、结果、思考或密钥；失败／取消可能仍产生费用，未计入此表。")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text("\(records.count) 条记录 · \(records.filter { $0.costKnowledge == .unknown || $0.costKnowledge == .stalePrice }.count) 条费用待确认")
                Spacer()
                if !totals.isEmpty { Text("参考估算合计：" + totals.joined(separator: "；")) }
            }.font(.caption).foregroundStyle(.secondary)
            Table(records, selection: $selected) {
                TableColumn("时间") { Text($0.completedAt.formatted(date: .abbreviated, time: .shortened)) }.width(155)
                TableColumn("模型") { record in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(record.offering.remoteModelID).lineLimit(1)
                        Text(state.providers.first { $0.id == record.offering.connectionID }?.name ?? "已删除渠道")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
                TableColumn("用量") { Text($0.usage.summary).font(.caption) }.width(190)
                TableColumn("思考配置") { Text($0.reasoning.summary).font(.caption) }.width(110)
                TableColumn("费用") { Text($0.costSummary).font(.caption) }.width(150)
            }
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .overlay { if records.isEmpty { Text("暂无本机用量记录").foregroundStyle(.secondary) } }
            if let record = records.first(where: { $0.id == selected }) {
                Text("\(record.apiProtocol.title) · \(record.backend.title)\(record.priceSnapshotID.map { " · 价格快照 " + $0 } ?? "")")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
        }
        .padding(16)
        .toolbar {
            Button("清除用量记录") { confirmingClear = true }.disabled(records.isEmpty || state.locked)
        }
        .alert("清除本机用量记录？", isPresented: $confirmingClear) {
            Button("取消", role: .cancel) {}
            Button("清除", role: .destructive) { state.clearUsageRecords() }
        } message: { Text("只清除本机统计，不影响模型、凭据或服务商实际账单。") }
    }
}
