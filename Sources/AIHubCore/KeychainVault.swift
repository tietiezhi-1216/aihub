import Foundation
import Security

public struct KeychainVault: CredentialVault {
    private let service: String
    public init(service: String = "app.aihub.provider-credentials") { self.service = service }

    private func query(_ id: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: id.uuidString,
            kSecAttrSynchronizable as String: false
        ]
    }

    public func read(_ providerID: UUID) throws -> String? {
        var query = query(providerID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data, let key = String(data: data, encoding: .utf8) else {
            throw HubError("无法读取钥匙串（\(status)），请检查系统授权。")
        }
        return key
    }

    public func set(_ key: String, for providerID: UUID) throws {
        let attributes = [kSecValueData as String: Data(key.utf8)]
        let status = SecItemUpdate(query(providerID) as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query(providerID)
            item[kSecValueData as String] = Data(key.utf8)
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw HubError("无法保存 API Key 到钥匙串（\(added)）。") }
        } else if status != errSecSuccess {
            throw HubError("无法更新钥匙串（\(status)）。")
        }
    }

    public func delete(_ providerID: UUID) throws {
        let status = SecItemDelete(query(providerID) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw HubError("无法删除钥匙串凭据（\(status)）。")
        }
    }
}
