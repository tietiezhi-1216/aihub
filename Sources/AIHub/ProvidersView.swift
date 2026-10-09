import SwiftUI
import AIHubCore

struct ProvidersView: View {
    @Bindable var state: AppState
    @State private var selection: UUID?
    @State private var selectedModel: String?
    @State private var editing: Provider?
    @State private var showingNew = false
    @State private var deleting: Provider?
    @State private var search = ""
    @State private var category: ModelCapability?
    @State private var showingDetails = false
    @State private var confirmingMetadata = false

    private var selectedProvider: Provider? { state.providers.first { $0.id == selection } }
    private var models: [ModelGroup] {
        (selectedProvider?.modelGroups ?? []).filter { $0.matches(category: category, search: search) }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 10) {
                Text("渠道").font(.headline)
                Table(state.providers, selection: $selection) {
                    TableColumn("名称") { provider in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(provider.name).lineLimit(1)
                            if provider.name != provider.channelType.title {
                                Text(provider.channelType.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                    TableColumn("模型") { provider in Text("\(provider.modelGroups.count)") }.width(45)
                }
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollIndicators(.automatic)
                .overlay {
                    if state.providers.isEmpty { Text("暂无渠道").foregroundStyle(.secondary) }
                }
            }.frame(width: 240)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text(selectedProvider?.name ?? "模型").font(.headline)
                    Spacer()
                    Picker("类型", selection: $category) {
                        Text("全部类型").tag(nil as ModelCapability?)
                        ForEach(ModelCapability.allCases) { Text($0.title).tag(Optional($0)) }
                    }.labelsHidden().frame(width: 140)
                    TextField("搜索模型", text: $search).textFieldStyle(.roundedBorder).frame(maxWidth: 200)
                }
                if let provider = selectedProvider {
                    HStack {
                        Text(provider.channelType.usesLogin ? "账号登录" : provider.baseURL).lineLimit(1).textSelection(.enabled)
                        Spacer()
                        Text(provider.channelType.title)
                    }.font(.caption).foregroundStyle(.secondary)
                }
                modelsTable
                .tableStyle(.inset(alternatesRowBackgrounds: false))
                .scrollIndicators(.automatic)
                .overlay {
                    if models.isEmpty { Text("暂无模型").foregroundStyle(.secondary) }
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(16)
        .toolbar {
            ToolbarItemGroup {
                Button("添加渠道", systemImage: "plus") { showingNew = true }
                    .disabled(state.locked || !state.configurationReady)
                Button("编辑") { editing = selectedProvider }
                    .disabled(selectedProvider == nil || state.locked)
                Button("删除") { deleting = selectedProvider }
                    .disabled(selectedProvider == nil || state.locked)
                Button("模型详情") { showingDetails = true }
                    .disabled(selectedModel == nil || state.locked)
                Button(state.isUpdatingMetadata ? "取消目录更新" : "更新规格与价格") {
                    if state.isUpdatingMetadata { state.cancelMetadataUpdate() } else { confirmingMetadata = true }
                }
                .disabled(!state.configurationReady || state.locked && !state.isUpdatingMetadata)
                .help(state.publicRegistry.map { "公共目录更新于 " + $0.fetchedAt.formatted() } ?? "从 models.dev 获取公共元数据；不发送密钥、音频或原文。")
            }
        }
        .sheet(isPresented: $showingDetails) {
            if let provider = selectedProvider, let group = models.first(where: { $0.id == selectedModel }) {
                ModelDetailsView(state: state, providerID: provider.id, modelID: activeModel(group).id)
            }
        }
        .alert("更新公共规格与价格？", isPresented: $confirmingMetadata) {
            Button("取消", role: .cancel) {}
            Button("更新") { state.updatePublicMetadata() }
        } message: {
            Text("从 models.dev 下载公共目录，不发送渠道密钥、音频或原文。订阅渠道不套用公开 API 规格；更新不会验证实际调用。")
        }
        .sheet(isPresented: $showingNew) { ProviderEditor(state: state, provider: nil) }
        .sheet(item: $editing) { provider in ProviderEditor(state: state, provider: provider) }
        .alert("删除渠道？", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }
        )) {
            Button("取消", role: .cancel) { deleting = nil }
            Button("删除", role: .destructive) {
                if let deleting { state.deleteProvider(deleting) }
                deleting = nil
            }
        } message: {
            Text("将删除「\(deleting?.name ?? "")」及其凭据。")
        }
        .onAppear { reconcileSelection() }
        .onChange(of: state.providers.map(\.id)) { _, _ in reconcileSelection() }
        .onChange(of: selection) { _, _ in selectedModel = nil; search = ""; category = nil }
        .onChange(of: search) { _, _ in selectedModel = nil }
        .onChange(of: category) { _, _ in selectedModel = nil }
    }

    @ViewBuilder private var modelsTable: some View {
        if selectedProvider?.channelType == .antigravity {
            Table(models, selection: $selectedModel) {
                identityColumns
                TableColumn("思考") { group in
                    ModelThinkingPicker(group: group, thinking: thinkingBinding(group)).disabled(state.locked)
                }.width(90)
                statusColumn
            }
        } else {
            Table(models, selection: $selectedModel) {
                identityColumns
                TableColumn("思考规格") { group in Text(activeModel(group).metadata.reasoning.summary).font(.caption).help("规格来源及可用参数控制见模型详情；目录声明不等于实际调用验证。") }.width(125)
                statusColumn
            }
        }
    }
    @TableColumnBuilder<ModelGroup, Never>
    private var identityColumns: some TableColumnContent<ModelGroup, Never> {
        TableColumn("模型名称") { group in
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).lineLimit(1).help(group.identifierHelp)
                if let summary = activeModel(group).modalitySummary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                else if activeModel(group).displayName != nil { Text(activeModel(group).id).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        TableColumn("类型") { group in Text(activeModel(group).capability.title).help(activeModel(group).tasks.map(\.title).joined(separator: "、")) }.width(110)
    }
    @TableColumnBuilder<ModelGroup, Never>
    private var statusColumn: some TableColumnContent<ModelGroup, Never> {
        TableColumn("状态") { group in Text(activeModel(group).status).font(.caption) }.width(125)
    }
    private func activeModel(_ group: ModelGroup) -> AIModel {
        guard let provider = selectedProvider else { return group.selected().model }
        return state.activeVariant(in: group, provider: provider).model
    }
    private func thinkingBinding(_ group: ModelGroup) -> Binding<ModelThinking> {
        Binding(get: {
            guard let provider = selectedProvider else { return .standard }
            return state.activeVariant(in: group, provider: provider).thinking
        }, set: { level in
            guard let provider = selectedProvider else { return }
            state.chooseThinking(level, providerID: provider.id, groupID: group.id)
        })
    }
    private func reconcileSelection() {
        if !state.providers.contains(where: { $0.id == selection }) { selection = state.providers.first?.id }
    }
}
