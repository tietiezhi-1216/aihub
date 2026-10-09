import Foundation
import Darwin

public protocol SettingsPersistence: Sendable {
    func load() throws -> AppSettings
    func save(_ settings: AppSettings) throws
}

public struct SettingsRepository: SettingsPersistence {
    public let fileURL: URL
    public init(fileURL: URL) { self.fileURL = fileURL }

    public static func applicationDefault() throws -> SettingsRepository {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask,
            appropriateFor: nil, create: true
        )
        return SettingsRepository(fileURL: base.appendingPathComponent("AIHub/settings.json"))
    }

    public func load() throws -> AppSettings {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return AppSettings() }
        do {
            let data = try Data(contentsOf: fileURL)
            var settings = try JSONDecoder().decode(AppSettings.self, from: data)
            guard settings.version == 3,
                  Set(settings.providers.map(\.id)).count == settings.providers.count else {
                throw HubError("配置版本不兼容或包含重复供应商。")
            }
            for provider in settings.providers {
                guard Set(provider.models.map(\.id)).count == provider.models.count else {
                    throw HubError("配置中包含重复模型。")
                }
                _ = try provider.normalizedBaseURL
                try provider.validateChannel()
                for model in provider.models { try model.validateMetadata() }
            }
            guard settings.priceSnapshots.count <= 20_000 else { throw HubError("价格历史超过上限。") }
            for (id, price) in settings.priceSnapshots {
                guard id == price.id else { throw HubError("价格快照身份不匹配。") }
                var model = ModelOffering(id: "price-validation"); model.price = price
                try model.validateMetadata()
            }
            guard settings.usageRecords.count <= 5000, Set(settings.usageRecords.map(\.id)).count == settings.usageRecords.count else { throw HubError("用量记录超过限制或重复。") }
            for record in settings.usageRecords { try record.validate() }
            settings.reconcileSelections()
            return settings
        } catch {
            throw HubError("无法读取配置，原文件未修改。请检查 \(fileURL.path)。")
        }
    }

    public func save(_ settings: AppSettings) throws {
        guard settings.version == 3, settings.priceSnapshots.count <= 20_000, settings.usageRecords.count <= 5000,
              Set(settings.usageRecords.map(\.id)).count == settings.usageRecords.count else {
            throw HubError("配置版本不兼容或价格／用量历史超过上限，原文件未修改。")
        }
        for record in settings.usageRecords { try record.validate() }
        do {
            let directory = fileURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(settings)
            let temporary = directory.appendingPathComponent(".settings-\(UUID().uuidString).tmp")
            defer { try? FileManager.default.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            // Rename is the commit point. No fallible work may follow a successful commit.
            guard rename(temporary.path, fileURL.path) == 0 else {
                throw HubError("配置原子替换失败。")
            }
        } catch {
            throw HubError("无法保存配置，请检查应用数据目录的写入权限。")
        }
    }
}

public protocol CredentialVault: Sendable {
    func read(_ providerID: UUID) throws -> String?
    func set(_ key: String, for providerID: UUID) throws
    func delete(_ providerID: UUID) throws
}

public struct ConfigurationService: Sendable {
    public let persistence: any SettingsPersistence
    public let vault: any CredentialVault

    public init(persistence: any SettingsPersistence, vault: any CredentialVault) {
        self.persistence = persistence
        self.vault = vault
    }

    // Compensating rollback prevents a configuration write failure from replacing the stored key.
    public func upsert(
        _ provider: Provider, newKey: String?, settings: AppSettings
    ) throws -> AppSettings {
        var provider = provider
        provider.name = provider.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !provider.name.isEmpty, provider.name.count <= 80 else {
            throw HubError("渠道名称不能为空或超过 80 字。")
        }
        provider.baseURL = try provider.normalizedBaseURL
        try provider.validateChannel()
        guard Set(provider.models.map(\.id)).count == provider.models.count else {
            throw HubError("模型目录不能包含重复 ID。")
        }
        for model in provider.models { try model.validateMetadata() }
        let previous = settings.providers.first { $0.id == provider.id }
        let endpointChanged = previous.map { $0.baseURL != provider.baseURL } ?? false
        let kindChanged = previous.map {
            $0.channelType != provider.channelType || $0.effectiveProtocol != provider.effectiveProtocol || $0.authentication != provider.authentication
        } ?? false
        let rawReplacement = (newKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let replacement = rawReplacement.isEmpty ? "" : try CredentialEnvelope.validateStored(rawReplacement, for: provider)
        guard provider.requiresAPIKey || provider.authentication == .apiKey else {
            throw HubError("OAuth 和 Bearer 渠道必须提供鉴权凭据。")
        }
        let oldKey = try vault.read(provider.id)
        guard !((endpointChanged || kindChanged) && oldKey != nil && replacement.isEmpty && provider.requiresAPIKey) else {
            throw HubError("连接配置已改变，请重新输入密钥、导入凭据或授权。")
        }
        if endpointChanged || kindChanged || !replacement.isEmpty {
            for index in provider.models.indices { provider.models[index].verifiedAt = nil; provider.models[index].verifications = [] }
            if endpointChanged || kindChanged { provider.discoveredAt = nil }
        } else if previous?.textBackend != provider.textBackend {
            for index in provider.models.indices where provider.models[index].supportsTextOutput {
                provider.models[index].verifications.removeAll { $0.task == .textGeneration }
                provider.models[index].verifiedAt = provider.models[index].verifications.map(\.completedAt).max()
            }
        }
        guard !provider.requiresAPIKey || !replacement.isEmpty || oldKey != nil else {
            throw HubError("请输入 API Key，或为本地兼容服务选择「无需 API Key」。")
        }
        if replacement.isEmpty, provider.requiresAPIKey, let oldKey {
            _ = try CredentialEnvelope.validateStored(oldKey, for: provider)
        }
        var next = settings
        if let index = next.providers.firstIndex(where: { $0.id == provider.id }) {
            next.providers[index] = provider
        } else {
            next.providers.append(provider)
        }
        next.reconcileSelections()
        let keyChanges = !replacement.isEmpty || !provider.requiresAPIKey
        if keyChanges {
            if !provider.requiresAPIKey { try vault.delete(provider.id) }
            else { try vault.set(replacement, for: provider.id) }
        }
        do {
            try persistence.save(next)
        } catch {
            if keyChanges {
                do { try restore(oldKey, for: provider.id) }
                catch { throw HubError("配置保存失败，且凭据回滚失败。请重新检查钥匙串与供应商设置。") }
            }
            throw error
        }
        return next
    }

    public func remove(_ providerID: UUID, settings: AppSettings) throws -> AppSettings {
        let oldKey = try vault.read(providerID)
        var next = settings
        next.providers.removeAll { $0.id == providerID }
        next.reconcileSelections()
        try vault.delete(providerID)
        do { try persistence.save(next) }
        catch {
            do { try restore(oldKey, for: providerID) }
            catch { throw HubError("删除失败，且凭据回滚失败。请重新检查钥匙串。") }
            throw error
        }
        return next
    }

    private func restore(_ key: String?, for providerID: UUID) throws {
        if let key { try vault.set(key, for: providerID) }
        else { try vault.delete(providerID) }
    }
}
