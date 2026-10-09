import Foundation
import Testing
@testable import AIHubCore

// Mutable fake state is protected by one lock per object.
final class MemoryVault: CredentialVault, @unchecked Sendable {
    private let lock = NSLock()
    private var keys: [UUID: String] = [:]
    func read(_ providerID: UUID) throws -> String? { lock.withLock { keys[providerID] } }
    func set(_ key: String, for providerID: UUID) throws { lock.withLock { keys[providerID] = key } }
    func delete(_ providerID: UUID) throws { lock.withLock { keys[providerID] = nil } }
}

struct FailingPersistence: SettingsPersistence {
    func load() throws -> AppSettings { AppSettings() }
    func save(_ settings: AppSettings) throws { throw HubError("Simulated write failure") }
}

struct PersistenceTests {
    func temporaryRepository() -> SettingsRepository {
        SettingsRepository(fileURL: FileManager.default.temporaryDirectory
            .appendingPathComponent("AIHub-tests-\(UUID())/settings.json"))
    }

    @Test func settingsRoundtripNeverPersistsKey() throws {
        let repository = temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository.fileURL.deletingLastPathComponent()) }
        let vault = MemoryVault()
        let service = ConfigurationService(persistence: repository, vault: vault)
        var model = AIModel(id: "whisper-1")
        model.verifiedAt = Date()
        let provider = Provider(name: "Personal", kind: .openAI, baseURL: "https://api.openai.com/v1", models: [model])
        let saved = try service.upsert(provider, newKey: "test-secret-never-persist", settings: AppSettings())
        #expect(try repository.load() == saved)
        let raw = try String(contentsOf: repository.fileURL, encoding: .utf8)
        #expect(!raw.contains("test-secret-never-persist"))
        #expect(try vault.read(provider.id) == "test-secret-never-persist")
        let attributes = try FileManager.default.attributesOfItem(atPath: repository.fileURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

    @Test func backendChangeClearsOnlyTextVerificationAndKeepsKey() throws {
        let repository = temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository.fileURL.deletingLastPathComponent()) }
        let vault = MemoryVault(), date = Date()
        var speech = AIModel(id: "whisper-1"); speech.verifiedAt = date
        var chat = AIModel(id: "gpt-4o-mini"); chat.verifiedAt = date
        let provider = Provider(name: "Backend", baseURL: "https://api.openai.com/v1", models: [speech, chat])
        try vault.set("unchanged-key", for: provider.id)
        var settings = AppSettings(); settings.providers = [provider]
        var changed = provider; changed.textBackend = .swiftAI
        let service = ConfigurationService(persistence: repository, vault: vault)
        let saved = try service.upsert(changed, newKey: nil, settings: settings)
        #expect(saved.providers[0].speechModels[0].verifiedAt == date)
        #expect(saved.providers[0].chatModels[0].verifiedAt == nil)
        #expect(try vault.read(provider.id) == "unchanged-key")
        #expect(try repository.load() == saved)
        let failing = ConfigurationService(persistence: FailingPersistence(), vault: vault)
        #expect(throws: HubError.self) { try failing.upsert(changed, newKey: nil, settings: settings) }
        #expect(try vault.read(provider.id) == "unchanged-key")
    }

    @Test func failedSaveRestoresPreviousKey() throws {
        let vault = MemoryVault()
        let provider = Provider(name: "A", kind: .openAI, baseURL: ProviderKind.openAI.defaultURL)
        try vault.set("old-key", for: provider.id)
        let service = ConfigurationService(persistence: FailingPersistence(), vault: vault)
        #expect(throws: HubError.self) { try service.upsert(provider, newKey: "new-key", settings: AppSettings()) }
        #expect(try vault.read(provider.id) == "old-key")
    }

    @Test func failedCreationLeavesNoOrphanKey() throws {
        let vault = MemoryVault()
        let provider = Provider(name: "A", kind: .openAI, baseURL: ProviderKind.openAI.defaultURL)
        let service = ConfigurationService(persistence: FailingPersistence(), vault: vault)
        #expect(throws: HubError.self) { try service.upsert(provider, newKey: "new-key", settings: AppSettings()) }
        #expect(try vault.read(provider.id) == nil)
    }

    @Test func failedDeleteRestoresKey() throws {
        let vault = MemoryVault()
        let provider = Provider(name: "A", kind: .openAI, baseURL: ProviderKind.openAI.defaultURL)
        try vault.set("old", for: provider.id)
        var settings = AppSettings()
        settings.providers = [provider]
        let service = ConfigurationService(persistence: FailingPersistence(), vault: vault)
        #expect(throws: HubError.self) { try service.remove(provider.id, settings: settings) }
        #expect(try vault.read(provider.id) == "old")
    }

    @Test func blankKeyPreservesExistingKeyAndEndpointChangeRequiresReentry() throws {
        let repository = temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository.fileURL.deletingLastPathComponent()) }
        let vault = MemoryVault()
        let service = ConfigurationService(persistence: repository, vault: vault)
        var provider = Provider(name: "A", kind: .openAI, baseURL: ProviderKind.openAI.defaultURL)
        let first = try service.upsert(provider, newKey: "old", settings: AppSettings())
        let next = try service.upsert(provider, newKey: "", settings: first)
        #expect(try vault.read(provider.id) == "old")
        provider.baseURL = "https://another.example/v1"
        #expect(throws: HubError.self) { try service.upsert(provider, newKey: "", settings: next) }
        #expect(try vault.read(provider.id) == "old")
        #expect(try repository.load() == next)
        let changed = try service.upsert(provider, newKey: "explicit-new", settings: next)
        #expect(changed.providers.first?.baseURL == provider.baseURL)
    }

    @Test func deleteClearsSelectionsAndKey() throws {
        let repository = temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository.fileURL.deletingLastPathComponent()) }
        let vault = MemoryVault()
        let service = ConfigurationService(persistence: repository, vault: vault)
        let provider = Provider(name: "A", kind: .openAI, baseURL: ProviderKind.openAI.defaultURL,
                                models: [AIModel(id: "whisper-1")])
        var settings = try service.upsert(provider, newKey: "old", settings: AppSettings())
        settings.speechSelection = .init(providerID: provider.id, modelID: "whisper-1")
        let next = try service.remove(provider.id, settings: settings)
        #expect(next.providers.isEmpty)
        #expect(next.speechSelection == nil)
        #expect(try vault.read(provider.id) == nil)
    }

    @Test func keylessModeRemovesOldKey() throws {
        let repository = temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository.fileURL.deletingLastPathComponent()) }
        let vault = MemoryVault()
        let service = ConfigurationService(persistence: repository, vault: vault)
        var provider = Provider(name: "Local", kind: .compatible, baseURL: "http://localhost:8000/v1")
        let old = try service.upsert(provider, newKey: "old", settings: AppSettings())
        provider.requiresAPIKey = false
        _ = try service.upsert(provider, newKey: nil, settings: old)
        #expect(try vault.read(provider.id) == nil)
    }

    @Test func corruptSettingsRemainUntouched() throws {
        let repository = temporaryRepository()
        defer { try? FileManager.default.removeItem(at: repository.fileURL.deletingLastPathComponent()) }
        try FileManager.default.createDirectory(at: repository.fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bad = Data("{ broken configuration".utf8)
        try bad.write(to: repository.fileURL)
        #expect(throws: HubError.self) { try repository.load() }
        #expect(try Data(contentsOf: repository.fileURL) == bad)
    }

    @Test func duplicateModelsRejectedBeforeSavingCredentials() throws {
        let repository = temporaryRepository()
        let vault = MemoryVault()
        let provider = Provider(name: "A", kind: .openAI, baseURL: ProviderKind.openAI.defaultURL,
                                models: [AIModel(id: "whisper-1"), AIModel(id: "whisper-1")])
        let service = ConfigurationService(persistence: repository, vault: vault)
        #expect(throws: HubError.self) { try service.upsert(provider, newKey: "key", settings: AppSettings()) }
        #expect(try vault.read(provider.id) == nil)
    }
}
