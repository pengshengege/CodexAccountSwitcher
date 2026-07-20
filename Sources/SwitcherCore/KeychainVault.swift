import Foundation
import Security

public protocol LegacyAuthRetrieving: AnyObject {
    func retrieve(for profileID: UUID) throws -> Data
}

/// Compatibility bridge for credentials saved by releases before v0.2.3.
/// AccountLibrary only reads this during an explicit user-initiated switch.
public final class KeychainVault: LegacyAuthRetrieving {
    public static let defaultService = "com.local.CodexAccountSwitcher.auth"

    private let service: String

    public init(service: String = KeychainVault.defaultService) {
        self.service = service
    }

    public func store(_ data: Data, for profileID: UUID) throws {
        let query = baseQuery(for: profileID)
        let update: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrLabel as String: "Codex 账号 \(profileID.uuidString)"
        ]

        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        guard updateStatus == errSecItemNotFound else {
            throw SwitcherError.keychain(updateStatus)
        }

        var addQuery = query
        for (key, value) in update {
            addQuery[key] = value
        }
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly

        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw SwitcherError.keychain(addStatus)
        }
    }

    public func retrieve(for profileID: UUID) throws -> Data {
        var query = baseQuery(for: profileID)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess else {
            throw SwitcherError.keychain(status)
        }
        guard let data = item as? Data else {
            throw SwitcherError.invalidAuthFile("钥匙串中的账号数据格式不正确")
        }
        return data
    }

    public func delete(for profileID: UUID) throws {
        let query = baseQuery(for: profileID)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw SwitcherError.keychain(status)
        }
    }

    private func baseQuery(for profileID: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: profileID.uuidString
        ]
    }
}
