import SwiftUI
import AIHubCore

struct ModelDetailsView: View {
    @Bindable var state: AppState
    let providerID: UUID
    let modelID: String
    @Environment(\.dismiss) private var dismiss
    private var provider: Provider? { state.providers.first { $0.id == providerID } }
    private var model: ModelOffering? { provider?.models.first { $0.id == modelID } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model?.name ?? modelID).font(.headline)
            ScrollView {
                if let provider, let model {
                    Form {
                        Section("渠道模型") {
                            item("渠道", provider.channelType.title)
                            item("真实模型 ID", model.id)
                            if let developer = model.definition?.developer { item("模型厂商（目录参考）", developer.name) }
                            if let identity = model.definition?.identity { item("参考目录身份", "\(identity.namespace)/\(identity.modelID)") }
                            item("任务", model.tasks.isEmpty ? "待确认" : model.tasks.map(\.title).joined(separator: "、"))
                            item("输入／输出", model.modalitySummary ?? "待确认")
                            item("调用状态", model.status)
                        }
                        Section("调用接口") {
                            ForEach(model.tasks, id: \.self) { task in
                                item(task.title, provider.binding(for: model, task: task).map { provider.channelType.isSubscription ? provider.channelType.title + "（账号专用接口）" : $0.apiProtocol.title } ?? "仅目录管理 · 尚未接入")
                            }
                            if !provider.channelType.isSubscription, [.openAIChat, .openAIResponses].contains(provider.effectiveProtocol), model.supportsTextOutput {
                                Picker("文字协议", selection: protocolBinding(model)) {
                                    Text("默认／服务声明").tag(APIProtocol.automatic)
                                    Text(APIProtocol.openAIChat.title).tag(APIProtocol.openAIChat)
                                    Text(APIProtocol.openAIResponses.title).tag(APIProtocol.openAIResponses)
                                }
                                .disabled(state.locked)
                                .help("只修改此模型的文字接口；失败不会切换协议。密钥和目标地址不变。")
                            }
                            if let context = model.metadata.limits.context { item("上下文限制", "\(context) token") }
                            if let input = model.metadata.limits.input { item("输入限制", "\(input) token") }
                            if let output = model.metadata.limits.output { item("输出限制", "\(output) token") }
                        }
                        Section("思考规格") {
                            if provider.channelType == .antigravity,
                               let group = provider.modelGroups.first(where: { $0.variants.contains { $0.model.id == model.id } }), group.hasThinking {
                                item("真实路由档位", group.thinkingOptions.map(\.title).joined(separator: "、"))
                            }
                            item("参数规格", model.metadata.reasoning.summary)
                            if let evidence = model.metadata.reasoning.evidence { evidenceRow("来源", evidence) }
                            if !provider.channelType.isSubscription {
                                APIReasoningControls(state: state, providerID: provider.id, modelID: model.id)
                            }
                        }
                        Section("价格") {
                            if provider.channelType.isSubscription {
                                item("计费", "订阅 · 权限与额度以账户为准")
                            } else if let price = model.price {
                                item("计费", price.summary)
                                evidenceRow("来源", price.evidence)
                                if price.isStale() { item("时效", "超过 14 天未更新或时效未知，仅作参考") }
                                item("价格快照", price.id)
                                if let date = price.effectiveFrom { item("生效时间", date.formatted()) }
                                ForEach(Array(price.rules.enumerated()), id: \.offset) { _, rule in
                                    item(rule.dimension.title, "\(price.currency) \(PriceSchedule.number(rule.amount))/\(PriceSchedule.number(rule.quantity)) \(rule.dimension.unitTitle)\(conditions(rule.conditions))")
                                }
                                Text("目录价格用于参考与估算，不等于实际账单。")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else { item("计费", "价格待确认 · 不代表免费") }
                        }
                        Section("信息来源") {
                            ForEach(model.metadata.evidence.keys.sorted(), id: \.self) { key in
                                if let evidence = model.metadata.evidence[key] { evidenceRow(fieldTitle(key), evidence) }
                            }
                            ForEach(Array(model.verifications.enumerated()), id: \.offset) { _, verification in
                                item("调用记录", verificationSummary(verification))
                            }
                        }
                    }.formStyle(.grouped)
                }
            }
            HStack { Spacer(); Button("完成") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(20).frame(width: 660, height: 650)
    }
    private func item(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).textSelection(.enabled) }
    }
    private func evidenceRow(_ title: String, _ evidence: MetadataEvidence) -> some View {
        item(title, "\(evidence.origin.title) · \(evidence.source)\(evidence.fetchedAt.map { " · " + $0.formatted() } ?? "")")
    }
    private func fieldTitle(_ field: String) -> String {
        ["tasks": "任务", "inputModalities": "输入模态", "outputModalities": "输出模态", "limits": "限制", "limits.context": "上下文参考", "limits.input": "输入限制参考", "limits.output": "输出限制参考"][field] ?? field
    }
    private func verificationSummary(_ record: InvocationVerification) -> String {
        let thinking = record.task == .textGeneration ? " · " + (record.reasoning?.summary ?? "历史／默认配置") : ""
        return "\(record.task.title) · \(record.apiProtocol.title) · \(record.backend.title)\(thinking) · \(record.completedAt.formatted())"
    }
    private func conditions(_ value: PriceConditions) -> String {
        var result: [String] = []
        if let above = value.contextAbove { result.append("上下文 > \(above)") }
        if let maximum = value.contextAtMost { result.append("上下文 ≤ \(maximum)") }
        result += value.attributes.keys.sorted().map { "\($0)=\(value.attributes[$0] ?? "")" }
        return result.isEmpty ? "" : "（\(result.joined(separator: "，"))）"
    }
    private func protocolBinding(_ model: ModelOffering) -> Binding<APIProtocol> {
        Binding(get: { model.metadata.bindings.first { $0.task == .textGeneration && $0.evidence.origin == .user }?.apiProtocol ?? .automatic },
                set: { state.chooseModelProtocol($0, providerID: providerID, modelID: modelID) })
    }
}
