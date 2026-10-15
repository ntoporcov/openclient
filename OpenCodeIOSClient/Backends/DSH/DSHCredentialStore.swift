import Foundation
import Security

struct DSHCredential: Codable, Equatable, Sendable {
    let baseURL: URL
    let token: String
    var username: String? = nil
    var password: String? = nil

    init(serverURL: String, token: String) throws {
        let input = serverURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = token.trimmingCharacters(in: .whitespacesAndNewlines)
        // Keep accepting launch links copied from dsh web, as well as separate fields.
        if token.isEmpty {
            try self.init(launchURL: input)
            return
        }
        guard var components = URLComponents(string: input),
              components.query == nil, components.fragment == nil else { throw DSHLoginError.invalidLink }
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        guard let url = components.url else { throw DSHLoginError.invalidLink }
        try self.init(launchURL: url.absoluteString)
    }

    init(serverURL: String, username: String, password: String) throws {
        guard let url = URL(string: serverURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.query == nil, components.fragment == nil,
              let configuration = try? DSHConfiguration(url: url),
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !password.isEmpty else {
            throw DSHLoginError.invalidAccount
        }
        baseURL = configuration.baseURL
        token = ""
        self.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
        self.password = password
    }

    var configuration: DSHConfiguration {
        get throws {
            var value = try DSHConfiguration(url: launchURL)
            value.username = username
            value.password = password
            return value
        }
    }

    init(launchURL: String) throws {
        guard let url = URL(string: launchURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw DSHLoginError.invalidLink
        }
        let configuration: DSHConfiguration
        do { configuration = try DSHConfiguration(url: url) }
        catch { throw DSHLoginError.invalidLink }
        guard let token = configuration.launchToken, !token.isEmpty else { throw DSHLoginError.invalidLink }
        self.baseURL = configuration.baseURL
        self.token = token
    }

    var launchURL: URL {
        if username != nil { return baseURL }
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)!
        components.queryItems = [.init(name: "token", value: token)]
        return components.url!
    }
}

enum DSHLoginError: Error, LocalizedError {
    case invalidLink, invalidAccount, authentication, accountAuthentication, unavailable, storage

    var errorDescription: String? {
        switch self {
        case .invalidLink: String(localized: "Paste the full DSH launch URL, including its token.")
        case .invalidAccount: String(localized: "Enter a server URL, username, and password. Use the server URL without a token or query string.")
        case .accountAuthentication: String(localized: "DSH password login failed. Check your credentials and auth-gate configuration. Use the browser for accounts requiring a verification code or password change.")
        case .authentication: String(localized: "This DSH login has expired or is invalid. Paste a fresh launch URL from your server.")
        case .unavailable: String(localized: "Could not connect to DSH. Check the server address, network, and Tailscale connection, then try again.")
        case .storage: String(localized: "Could not access the saved DSH login in Keychain. Unlock your device and try again.")
        }
    }
}

protocol DSHCredentialPersisting {
    func load() throws -> DSHCredential?
    func save(_ credential: DSHCredential) throws
    func delete() throws
}

/// One atomic, device-local Keychain record. Never uses OpenClient's shared group
/// or UserDefaults; the server origin and token cannot become mismatched.
struct DSHCredentialStore: DSHCredentialPersisting {
    var service = "com.ntoporcov.dshclient.login"

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: "server"]
    }

    func load() throws -> DSHCredential? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data,
              let credential = try? JSONDecoder().decode(DSHCredential.self, from: data) else { throw DSHLoginError.storage }
        return credential
    }

    func save(_ credential: DSHCredential) throws {
        let data = try JSONEncoder().encode(credential)
        let attributes: [String: Any] = [kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlockedThisDeviceOnly]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            status = SecItemAdd(query.merging(attributes) { _, new in new } as CFDictionary, nil)
        }
        guard status == errSecSuccess, try load() == credential else { throw DSHLoginError.storage }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw DSHLoginError.storage }
    }
}
