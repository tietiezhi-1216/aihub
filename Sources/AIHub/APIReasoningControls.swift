import SwiftUI
import AIHubCore

struct APIReasoningControls: View {
    @Bindable var state: AppState
    let providerID: UUID
    let modelID: String
    @State private var control = "default"
    @State private var effort = ""
    @State private var budget = 1024
    @State private var output = 4096
    private var provider: Provider? { state.providers.first { $0.id == providerID } }
    private var model: ModelOffering? { provider?.models.first { $0.id == modelID } }
    private var style: ReasoningWireStyle? {
        guard let provider, let model, let binding = provider.binding(for: model, task: .textGeneration) else { return nil }
        return PublicReasoningPolicy.style(provider: provider, api: binding.apiProtocol)
    }
    private var efforts: [String] {
        let allowed: [String]
        switch style {
        case .openAI: allowed = ["none", "minimal", "low", "medium", "high", "xhigh", "max"]
        case .anthropic: allowed = ["low", "medium", "high", "xhigh", "max"]
        case .gemini: allowed = ["minimal", "low", "medium", "high"]
        default: allowed = []
        }
        return (model?.metadata.reasoning.efforts ?? []).filter { allowed.contains($0) && !(model?.metadata.reasoning.mandatory == true && $0 == "none") }
    }
    var body: some View {
        if let model, style != nil, model.metadata.reasoning.support == .supported {
            VStack(alignment: .leading, spacing: 8) {
                Picker("思考控制", selection: $control) {
                    Text("服务默认").tag("default")
                    if style != .anthropic, !efforts.isEmpty { Text("指定等级").tag("effort") }
                    if style == .anthropic {
                        ForEach(model.metadata.reasoning.modes.filter { ["enabled", "disabled", "adaptive"].contains($0) && !(model.metadata.reasoning.mandatory == true && $0 == "disabled") }, id: \.self) { mode in
                            Text(["enabled": "开启（预算）", "disabled": "关闭", "adaptive": "自适应"][mode]!).tag(mode)
                        }
                    }
                    if style == .gemini, model.metadata.reasoning.supportsBudget {
                        if model.metadata.reasoning.minimumBudget != nil, model.metadata.reasoning.maximumBudget != nil { Text("指定 Token 预算").tag("budget") }
                        if model.metadata.reasoning.allowsAutomaticBudget == true { Text("自动预算").tag("auto_budget") }
                    }
                }
                if control == "effort" || control == "adaptive" && !efforts.isEmpty {
                    Picker("等级", selection: $effort) {
                        Text("请选择／服务默认").tag("")
                        ForEach(efforts, id: \.self) { Text(ReasoningSpec.effortTitle($0)).tag($0) }
                    }
                }
                if ["budget", "enabled"].contains(control) {
                    TextField("思考预算（token）", value: $budget, format: .number)
                    if let min = model.metadata.reasoning.minimumBudget, let max = model.metadata.reasoning.maximumBudget {
                        Text("目录预算范围：\(min)…\(max)").font(.caption).foregroundStyle(.secondary)
                    }
                }
                TextField("输出上限（token）", value: $output, format: .number)
                HStack {
                    Button("应用") { apply() }
                    Button("恢复服务默认") {
                        state.chooseReasoning(.init(), outputLimit: nil, providerID: providerID, modelID: modelID)
                        load()
                    }
                    Spacer()
                    Text("当前：\(model.reasoningSelection?.summary ?? "服务默认")").font(.caption).foregroundStyle(.secondary)
                }
                Text("输出上限包含思考；只发送有规格依据且已映射的选项，不证明账户权限或实际思考强度。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(state.locked)
            .onAppear { load() }
            .onChange(of: modelID) { _, _ in load() }
            .onChange(of: providerID) { _, _ in load() }
        } else if let model {
            if model.reasoningSelection != nil {
                Text("已有思考选择与当前规格或参数映射不兼容；不会自动降档。").font(.caption).foregroundStyle(.secondary)
                Button("恢复服务默认") { state.chooseReasoning(.init(), outputLimit: nil, providerID: providerID, modelID: modelID) }.disabled(state.locked)
            } else if model.metadata.reasoning.support == .supported {
                Text("此渠道的思考参数映射待确认，保持默认调用。").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
    private func load() {
        let selection = model?.reasoningSelection ?? .init()
        effort = selection.effort ?? ""; budget = selection.budget ?? max(1024, model?.metadata.reasoning.minimumBudget ?? 1024)
        output = model?.outputTokenLimit ?? min(model?.metadata.limits.output ?? 4096, 4096)
        if let mode = selection.mode { control = mode.rawValue }
        else if selection.effort != nil { control = "effort" }
        else if selection.budget == -1 { control = "auto_budget" }
        else if selection.budget != nil { control = "budget" }
        else { control = "default" }
    }
    private func apply() {
        var selection = ReasoningSelection()
        switch control {
        case "effort":
            guard !effort.isEmpty else { state.error = "请先选择目录提供的思考等级。"; return }
            selection.effort = effort
        case "budget": selection.budget = budget
        case "auto_budget": selection.budget = -1
        case "enabled": selection.mode = .enabled; selection.budget = budget
        case "disabled": selection.mode = .disabled
        case "adaptive": selection.mode = .adaptive; selection.effort = effort.isEmpty ? nil : effort
        default: break
        }
        state.chooseReasoning(selection, outputLimit: output, providerID: providerID, modelID: modelID)
    }
}
