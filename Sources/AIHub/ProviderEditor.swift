import AppKit
import SwiftUI
import UniformTypeIdentifiers
import AIHubCore

struct ProviderEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Bindable var state: AppState
    let original: Provider?
    @State private var draft: Provider
    @State private var selectedChannel: ChannelType?
    @State private var apiKey = ""
    @State private var importedCredential: String?
    @State private var hasStoredKey = false
    @State private var loginIdentity: String?
    @State private var signedIn = false
    @State private var message: String?
    @State private var isError = false
    @State private var fetching = false
    @State private var authenticating = false
    @State private var fetchTask: Task<Void, Never>?
    @State private var loginTask: Task<Void, Never>?
    @State private var googleSession: GoogleOAuthLogin?
    @State private var accountSession: AccountOAuthLogin?
    @State private var confirmingAntigravity = false
    @State private var advanced = false
    @State private var search = ""
    @State private var category: ModelCapability?
    @State private var selectedModel: String?
    @State private var newModel = ""
    @State private var newCapability: ModelCapability = .unknown
    private var busy: Bool { fetching || authenticating }
    private var showsModels: Bool { selectedChannel.map { !$0.usesLogin || signedIn } ?? false }
    private var dialogHeight: CGFloat { selectedChannel == nil ? 190 : showsModels ? 660 : 240 }
    private var canSave: Bool {
        !busy && !state.locked && selectedChannel != nil &&
        !draft.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !draft.baseURL.isEmpty &&
        (!draft.channelType.usesLogin || signedIn) &&
        (!draft.requiresAPIKey || !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || importedCredential != nil || hasStoredKey)
    }

    init(state: AppState, provider: Provider?) {
        self.state = state; original = provider
        _draft = State(initialValue: provider ?? Provider(name: "", baseURL: ""))
        _selectedChannel = State(initialValue: provider?.channelType)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original == nil ? "添加渠道" : "编辑渠道").font(.headline)
            Picker("渠道类型", selection: $selectedChannel) {
                Text("请选择渠道类型").tag(Optional<ChannelType>.none)
                Section("账号登录") {
                    ForEach(ChannelType.loginChannels) { channel in Text(channel.title).tag(Optional(channel)) }
                }
                Section("API 接口") {
                    ForEach(ChannelType.apiChannels) { channel in Text(channel.title).tag(Optional(channel)) }
                }
            }.disabled(busy)
            if let channel = selectedChannel {
                connectionFields(channel).disabled(busy)
                if channel.usesLogin { loginControls(channel) }
                else { apiControls(channel) }
                if showsModels {
                    Divider()
                    HStack {
                        Text("模型").font(.headline)
                        Spacer()
                        Picker("类型", selection: $category) {
                            Text("全部类型").tag(nil as ModelCapability?)
                            ForEach(ModelCapability.allCases) { Text($0.title).tag(Optional($0)) }
                        }.labelsHidden().frame(width: 140)
                        TextField("搜索模型", text: $search).frame(width: 180)
                    }
                    modelsTable.disabled(busy)
                    manualModelControls.disabled(busy)
                    Divider()
                } else { Spacer() }
            } else { Spacer() }
            footer
        }
        .padding(20)
        .textFieldStyle(.roundedBorder)
        .frame(width: 800, height: dialogHeight)
        .onAppear { loadCredentialStatus() }
        .onChange(of: selectedChannel) { _, new in
            guard let new, new != draft.channelType || original == nil && draft.name.isEmpty else { return }
            cancelRequests()
            draft.selectChannel(new)
            apiKey = ""; importedCredential = nil; hasStoredKey = false
            loginIdentity = nil; signedIn = false; message = nil; isError = false
            advanced = false; selectedModel = nil; search = ""
            newCapability = .unknown; category = nil
            if let original, new == original.channelType {
                draft = original
                loadCredentialStatus()
            }
        }
        .onChange(of: draft.baseURL) { _, _ in
            guard draft != original else { return }
            draft.kind = .compatible; invalidateConnection()
        }
        .onChange(of: draft.apiProtocol) { _, _ in
            if !draft.supportsSDKText { draft.textBackend = .builtIn }
            if draft != original { invalidateConnection() }
        }
        .onChange(of: draft.textBackend) { _, _ in
            for index in draft.models.indices where draft.models[index].supportsTextOutput {
                draft.models[index].verifications.removeAll { $0.task == .textGeneration }
                draft.models[index].verifiedAt = draft.models[index].verifications.map(\.completedAt).max()
            }
        }
        .onChange(of: apiKey) { _, new in
            if !new.isEmpty { importedCredential = nil; draft.authentication = .apiKey }
            clearVerification()
        }
        .onChange(of: search) { _, _ in selectedModel = nil }
        .onChange(of: category) { _, _ in selectedModel = nil }
        .onDisappear { cancelRequests(); apiKey = ""; importedCredential = nil }
        .alert("Antigravity 登录", isPresented: $confirmingAntigravity) {
            Button("取消", role: .cancel) {}
            Button("继续登录") { beginLogin(.antigravity) }
        } message: {
            Text("此通道使用非公开接口，可能因服务变更失效，也可能导致账号受限。是否继续？")
        }
        .alert("错误", isPresented: Binding(
            get: { isError && message != nil }, set: { if !$0 { message = nil; isError = false } }
        )) { Button("好", role: .cancel) { message = nil; isError = false } }
        message: { Text(message ?? "") }
    }

    private func connectionFields(_ channel: ChannelType) -> some View {
        Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 10) {
            GridRow { Text("名称"); TextField("名称", text: $draft.name).labelsHidden() }
            if !channel.usesLogin {
                GridRow {
                    Text(channel == .cliProxyAPI ? "本机地址" : "API 地址")
                    TextField(channel == .cliProxyAPI ? "本机地址" : "API 地址", text: $draft.baseURL,
                              prompt: Text(channel == .cliProxyAPI ? "http://127.0.0.1:8317/v1" : "https://example.com/v1")).labelsHidden().autocorrectionDisabled()
                }
                GridRow {
                    Text(channel == .cliProxyAPI ? "本机访问密钥" : "API Key")
                    SecureField(channel == .cliProxyAPI ? "本机访问密钥" : "API Key", text: $apiKey, prompt: Text(credentialPlaceholder))
                        .labelsHidden().textContentType(nil).autocorrectionDisabled().disabled(!draft.requiresAPIKey)
                }
            }
        }
    }
    private func loginControls(_ channel: ChannelType) -> some View {
        HStack {
            Text(signedIn ? "已登录\(loginIdentity.map { " · \($0)" } ?? "")" : "未登录").foregroundStyle(.secondary).lineLimit(1)
            Spacer()
            Button(signedIn ? "重新登录…" : "登录 \(channel.title)…") {
                if channel == .antigravity { confirmingAntigravity = true } else { beginLogin(channel) }
            }.disabled(busy)
            Button("导入登录凭据…") { importCredential() }.disabled(busy)
            Button("获取模型") { fetchModels() }.disabled(busy || !signedIn)
        }
    }
    private func apiControls(_ channel: ChannelType) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Button("验证连接并获取模型") { fetchModels() }.disabled(busy || draft.baseURL.isEmpty)
                Spacer()
                Button("导入鉴权文件…") { importCredential() }.disabled(busy)
                if channel == .custom {
                    Button(advanced ? "收起高级设置" : "高级设置") { advanced.toggle() }.disabled(busy)
                }
            }
            if draft.supportsSDKText {
                Picker("文字后端", selection: $draft.textBackend) {
                    ForEach(TextBackend.allCases) { Text($0.title).tag($0) }
                }
                .help("只影响文字调用；模型目录与 ASR 保留原适配。失败不会自动换后端。")
            }
            if channel == .cliProxyAPI {
                Text("连接已运行的本机服务；账号需在该服务中独立授权，不会复制现有登录凭据。")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if advanced, channel == .custom {
                HStack {
                    Picker("协议", selection: $draft.apiProtocol) {
                        ForEach(APIProtocol.allCases) { api in Text(api.title).tag(api) }
                    }
                    Toggle("需要密钥", isOn: $draft.requiresAPIKey).disabled(draft.authentication != .apiKey)
                }.disabled(busy)
            }
        }
    }
    private var credentialPlaceholder: String {
        if importedCredential != nil { return "已导入凭据" }
        return hasStoredKey ? "留空保持原值" : draft.channelType == .cliProxyAPI ? "输入本机访问密钥" : "输入 API Key"
    }
    private var modelsTable: some View {
        modelsTableContent
        .tableStyle(.inset(alternatesRowBackgrounds: false))
        .scrollIndicators(.automatic)
        .frame(minHeight: 180, maxHeight: .infinity)
        .overlay {
            if filteredModels.isEmpty { Text(draft.models.isEmpty ? "暂无模型" : "无匹配模型").foregroundStyle(.secondary) }
        }
    }
    @ViewBuilder private var modelsTableContent: some View {
        if draft.channelType == .antigravity {
            Table(filteredModels, selection: $selectedModel) {
                identityColumns
                TableColumn("思考") { group in
                    ModelThinkingPicker(group: group, thinking: thinkingBinding(group))
                }.width(90)
                statusColumn
            }
        } else {
            Table(filteredModels, selection: $selectedModel) { identityColumns; statusColumn }
        }
    }
    @TableColumnBuilder<ModelGroup, Never>
    private var identityColumns: some TableColumnContent<ModelGroup, Never> {
        TableColumn("模型名称") { group in
            VStack(alignment: .leading, spacing: 2) {
                Text(group.name).lineLimit(1).textSelection(.enabled).help(group.identifierHelp)
                if let summary = activeVariant(group).model.modalitySummary { Text(summary).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
            }
        }
        TableColumn("类型") { group in
            Picker("能力", selection: capabilityBinding(for: group)) {
                ForEach(ModelCapability.allCases) { capability in Text(capability.title).tag(capability) }
            }.labelsHidden()
        }.width(110)
    }
    @TableColumnBuilder<ModelGroup, Never>
    private var statusColumn: some TableColumnContent<ModelGroup, Never> {
        TableColumn("状态") { group in Text(activeVariant(group).model.status).font(.caption) }.width(125)
    }
    private var manualModelControls: some View {
        HStack {
            TextField("手动输入模型 ID", text: $newModel).onSubmit { addModel() }
            Picker("类型", selection: $newCapability) {
                ForEach(ModelCapability.allCases) { capability in
                    Text(capability == .unknown ? "自动识别类型" : capability.title).tag(capability)
                }
            }.labelsHidden().frame(width: 140)
            Button("添加") { addModel() }.disabled(newModel.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            Button("移除") { removeModelGroup() }.disabled(selectedModel == nil)
        }
    }
    private var footer: some View {
        HStack {
            if busy {
                ProgressView().controlSize(.small)
                Text(fetching ? "获取模型中…" : "等待浏览器登录…")
                Button("取消请求") { cancelRequests() }
            } else if let message, !isError { Text(message).foregroundStyle(.secondary).lineLimit(2) }
            Spacer()
            Button("取消") { close() }.keyboardShortcut(.cancelAction)
            if selectedChannel != nil, !draft.channelType.usesLogin || signedIn {
                Button("保存") { save() }.keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
        }
    }
    private var filteredModels: [ModelGroup] {
        draft.modelGroups.filter { $0.matches(category: category, search: search) }
    }
    private func activeVariant(_ group: ModelGroup) -> ModelVariant {
        let current = draft.thinkingSelections[group.id] == nil && state.settings.chatSelection?.providerID == draft.id
            ? state.settings.chatSelection?.modelID : nil
        return draft.selectedVariant(in: group, currentID: current)
    }
    private func thinkingBinding(_ group: ModelGroup) -> Binding<ModelThinking> {
        Binding(get: { activeVariant(group).thinking }, set: { level in
            _ = draft.selectThinking(level, in: group.id, currentID: activeVariant(group).model.id)
        })
    }
    private func capabilityBinding(for group: ModelGroup) -> Binding<ModelCapability> {
        Binding(get: { activeVariant(group).model.capability }, set: { capability in
            let ids = Set(group.variants.map { $0.model.id })
            for index in draft.models.indices where ids.contains(draft.models[index].id) {
                draft.models[index].classify(capability)
            }
        })
    }
    private func removeModelGroup() {
        guard let group = draft.modelGroups.first(where: { $0.id == selectedModel }) else { return }
        let ids = Set(group.variants.map { $0.model.id })
        draft.models.removeAll { ids.contains($0.id) }
        draft.reconcileThinkingSelections(); selectedModel = nil
    }
    private func invalidateConnection() {
        draft.models.removeAll { $0.source == .discovered }; clearVerification(); selectedModel = nil
    }
    private func clearVerification() {
        for index in draft.models.indices { draft.models[index].verifiedAt = nil; draft.models[index].verifications = [] }
        draft.discoveredAt = nil
    }
    private func loadCredentialStatus() {
        do {
            guard let value = try state.vault.read(draft.id) else { return }
            hasStoredKey = true
            if draft.channelType.usesLogin {
                _ = try CredentialEnvelope.validateStored(value, for: draft)
                signedIn = true
                loginIdentity = try CredentialEnvelope.decode(value)?.account?.email
            }
        } catch { show(error.localizedDescription, error: true) }
    }
    private func resolvedKey() throws -> String? {
        if !draft.requiresAPIKey { return nil }
        if let importedCredential { return importedCredential }
        let entered = try Validation.apiKey(apiKey)
        if !entered.isEmpty { return entered }
        if let original {
            guard try original.normalizedBaseURL == draft.normalizedBaseURL,
                  original.authentication == draft.authentication, original.channelType == draft.channelType,
                  original.effectiveProtocol == draft.effectiveProtocol else { throw HubError("连接已更改，请重新提供凭据或登录。") }
        }
        return try state.vault.read(draft.id)
    }
    private func fetchModels() {
        do {
            _ = try draft.normalizedBaseURL
            let key = try resolvedKey(), snapshot = draft
            fetching = true; message = nil
            fetchTask = Task {
                do { try await updateModels(snapshot: snapshot, key: key) }
                catch is CancellationError { show("已取消。", error: false) }
                catch { show(error.localizedDescription, error: true) }
                fetching = false; fetchTask = nil
            }
        } catch { show(error.localizedDescription, error: true) }
    }
    private func updateModels(snapshot: Provider, key: String?) async throws {
        do {
            let models = try await state.client.discover(provider: snapshot, key: key)
            try Task.checkCancellation()
            if let key, let refreshed = try await state.client.refreshedCredential(key, for: snapshot) { importedCredential = refreshed }
            draft.mergeDiscovered(state.enrichModels(models, for: snapshot)); selectedModel = nil
            show("已获取 \(models.count) 个模型。", error: false)
        } catch {
            // Retain rotated tokens even if the subsequent catalog request failed.
            if !Task.isCancelled, let key,
               let refreshed = try? await state.client.refreshedCredential(key, for: snapshot) { importedCredential = refreshed }
            throw error
        }
    }
    private func credentialFile() throws -> Data? {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false; panel.allowsMultipleSelection = false; panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= CredentialImport.maximumBytes else {
            throw HubError("请选择 256 KB 以内的 JSON 鉴权文件。")
        }
        return try Data(contentsOf: url)
    }
    private func importCredential() {
        do {
            guard let channel = selectedChannel, let data = try credentialFile() else { return }
            let credential = try CredentialImport.parse(data, channel: channel)
            if channel.usesLogin {
                guard credential.authentication == channel.authentication else { throw HubError("请选择对应渠道的登录凭据文件，不能使用 API Key 代替登录。") }
            }
            if credential.authentication == .bearer {
                if let base = credential.baseURL { draft.baseURL = base }
                if let api = credential.apiProtocol {
                    guard channel == .custom || api == channel.apiProtocol else { throw HubError("文件协议与所选渠道不匹配。") }
                    draft.apiProtocol = api
                }
            }
            draft.requiresAPIKey = true; draft.authentication = credential.authentication
            if credential.authentication == .apiKey { apiKey = credential.value; importedCredential = nil }
            else { apiKey = ""; importedCredential = credential.value }
            clearVerification()
            if channel.usesLogin {
                signedIn = true; loginIdentity = try CredentialEnvelope.decode(credential.value)?.account?.email
                fetchModels()
            } else { show("凭据已导入，请验证连接。", error: false) }
        } catch { show(error.localizedDescription, error: true) }
    }
    private func beginLogin(_ channel: ChannelType) {
        do {
            let google: GoogleOAuthLogin?
            let account: AccountOAuthLogin?
            if channel == .googleOAuth {
                guard let data = try credentialFile() else { return }
                google = try GoogleOAuthLogin(client: GoogleDesktopClient.parse(data)); account = nil
            } else { account = try AccountOAuthLogin(channel: channel); google = nil }
            googleSession = google; accountSession = account
            authenticating = true; message = nil
            loginTask = Task {
                do {
                    let value: String
                    if let account { value = try await account.login() }
                    else if let google { value = try await google.login() }
                    else { throw HubError("登录渠道未选择。") }
                    try Task.checkCancellation()
                    draft.authentication = channel.authentication; draft.requiresAPIKey = true
                    apiKey = ""; importedCredential = value; signedIn = true
                    loginIdentity = try CredentialEnvelope.decode(value)?.account?.email
                    clearVerification(); fetching = true
                    do { try await updateModels(snapshot: draft, key: value) }
                    catch is CancellationError { throw CancellationError() }
                    catch { show("登录成功，但模型获取失败：\(error.localizedDescription)", error: true) }
                } catch is CancellationError { show("登录已取消。", error: false) }
                catch { show(error.localizedDescription, error: true) }
                fetching = false; authenticating = false; loginTask = nil; googleSession = nil; accountSession = nil
            }
        } catch { show(error.localizedDescription, error: true) }
    }
    private func addModel() {
        do {
            let id = try Validation.modelID(newModel)
            guard !draft.models.contains(where: { $0.id == id }) else { throw HubError("此模型已在目录中。") }
            draft.models.append(AIModel(id: id, capability: newCapability == .unknown ? nil : newCapability, source: .manual)); draft.models.sort { $0.id < $1.id }
            search = ""; category = nil
            if let group = draft.modelGroups.first(where: { $0.variants.contains { $0.model.id == id } }) {
                selectedModel = group.id
                if let added = group.variants.first(where: { $0.model.id == id }), group.hasThinking {
                    _ = draft.selectThinking(added.thinking, in: group.id, currentID: id)
                }
            }
            newModel = ""
        } catch { show(error.localizedDescription, error: true) }
    }
    private func save() {
        do { try state.saveProvider(draft, key: importedCredential ?? apiKey); apiKey = ""; importedCredential = nil; dismiss() }
        catch { show(error.localizedDescription, error: true) }
    }
    private func show(_ text: String, error: Bool) { message = text; isError = error }
    private func cancelRequests() { fetchTask?.cancel(); loginTask?.cancel(); googleSession?.cancel(); accountSession?.cancel() }
    private func close() { cancelRequests(); apiKey = ""; importedCredential = nil; dismiss() }
}
