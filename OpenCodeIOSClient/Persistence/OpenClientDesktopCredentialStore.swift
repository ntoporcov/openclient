import Foundation
import Security

struct OpenClientDesktopCredentials: Codable, Equatable {
    let username: String
    let password: String
}

/// App-only, device-local credentials. Never shared with widgets, the plugin,
/// UserDefaults, diagnostics, or the transcript.
struct OpenClientDesktopCredentialStore {
    var service = "com.ntoporcov.openclient.desktop-credentials"

    func load(scope: String) throws -> OpenClientDesktopCredentials? {
        var query = query(scope)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw StorageError.failed }
        return try JSONDecoder().decode(OpenClientDesktopCredentials.self, from: data)
    }

    func save(_ credentials: OpenClientDesktopCredentials, scope: String) throws {
        let data = try JSONEncoder().encode(credentials)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query(scope) as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        guard status == errSecItemNotFound else { throw StorageError.failed }
        var item = query(scope)
        item[kSecValueData as String] = data
        item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw StorageError.failed }
    }

    func delete(scope: String) throws {
        let status = SecItemDelete(query(scope) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw StorageError.failed }
    }

    private func query(_ scope: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
         kSecAttrAccount as String: scope, kSecAttrSynchronizable as String: false]
    }

    enum StorageError: LocalizedError {
        case failed
        var errorDescription: String? { String(localized: "Could not access saved computer credentials in Keychain.") }
    }
}
