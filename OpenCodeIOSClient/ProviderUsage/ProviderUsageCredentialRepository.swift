import Foundation
import Security

enum ProviderUsageCredentialRepositoryError: Error, Equatable, Sendable {
    case missing
    case unavailable
    case writeFailed
    case readBackFailed
    case deleteFailed
    case invalidConfiguration
}

protocol ProviderUsageCredentialRepository: Sendable {
    func write(_ secret: ProviderUsageTransientSecret, reference: UUID) throws
    func read(reference: UUID) throws -> ProviderUsageTransientSecret
    func delete(reference: UUID) throws
}

struct UnavailableProviderUsageCredentialRepository: ProviderUsageCredentialRepository {
    let error: ProviderUsageCredentialRepositoryError

    init(error: ProviderUsageCredentialRepositoryError = .invalidConfiguration) {
        self.error = error
    }

    func write(_ secret: ProviderUsageTransientSecret, reference: UUID) throws { throw error }
    func read(reference: UUID) throws -> ProviderUsageTransientSecret { throw error }
    func delete(reference: UUID) throws { throw error }
}

protocol ProviderUsageSecurityClient: AnyObject {
    func add(_ attributes: [String: Any]) -> OSStatus
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus
    func delete(_ query: [String: Any]) -> OSStatus
}

final class SystemProviderUsageSecurityClient: ProviderUsageSecurityClient {
    func add(_ attributes: [String: Any]) -> OSStatus {
        SecItemAdd(attributes as CFDictionary, nil)
    }

    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        SecItemCopyMatching(query as CFDictionary, &result)
    }

    func delete(_ query: [String: Any]) -> OSStatus {
        SecItemDelete(query as CFDictionary)
    }
}

final class KeychainProviderUsageCredentialRepository: ProviderUsageCredentialRepository, @unchecked Sendable {
    static let service = "com.ntoporcov.openclient.provider-usage"
    static let privateAccessGroupInfoKey = "ProviderUsagePrivateKeychainAccessGroup"

    private let accessGroup: String
    private let security: any ProviderUsageSecurityClient

    convenience init(bundle: Bundle = .main) throws {
        guard let accessGroup = bundle.object(forInfoDictionaryKey: Self.privateAccessGroupInfoKey) as? String,
              !accessGroup.isEmpty else {
            throw ProviderUsageCredentialRepositoryError.invalidConfiguration
        }
        self.init(accessGroup: accessGroup, security: SystemProviderUsageSecurityClient())
    }

    init(accessGroup: String, security: any ProviderUsageSecurityClient) {
        self.accessGroup = accessGroup
        self.security = security
    }

    func write(_ secret: ProviderUsageTransientSecret, reference: UUID) throws {
        var query = baseQuery(reference: reference)
        query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        query[kSecValueData as String] = Data(secret.value.utf8)
        let status = security.add(query)
        guard status == errSecSuccess else {
            if Self.isUnavailable(status) { throw ProviderUsageCredentialRepositoryError.unavailable }
            throw ProviderUsageCredentialRepositoryError.writeFailed
        }

        do {
            guard try read(reference: reference) == secret else {
                throw ProviderUsageCredentialRepositoryError.readBackFailed
            }
        } catch let error as ProviderUsageCredentialRepositoryError {
            _ = security.delete(baseQuery(reference: reference))
            if error == .unavailable { throw error }
            throw ProviderUsageCredentialRepositoryError.readBackFailed
        }
    }

    func read(reference: UUID) throws -> ProviderUsageTransientSecret {
        var query = baseQuery(reference: reference)
        query[kSecAttrSynchronizable as String] = kCFBooleanFalse
        query[kSecReturnData as String] = kCFBooleanTrue
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = security.copyMatching(query, result: &result)
        guard status == errSecSuccess else { throw Self.readError(status) }
        guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
            throw ProviderUsageCredentialRepositoryError.readBackFailed
        }
        return ProviderUsageTransientSecret(value: value)
    }

    func delete(reference: UUID) throws {
        let status = security.delete(baseQuery(reference: reference))
        guard status == errSecSuccess else {
            if status == errSecItemNotFound { throw ProviderUsageCredentialRepositoryError.missing }
            if Self.isUnavailable(status) { throw ProviderUsageCredentialRepositoryError.unavailable }
            throw ProviderUsageCredentialRepositoryError.deleteFailed
        }
    }

    private func baseQuery(reference: UUID) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: Self.service,
            kSecAttrAccount as String: reference.uuidString,
            kSecAttrAccessGroup as String: accessGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
        ]
    }

    private static func readError(_ status: OSStatus) -> ProviderUsageCredentialRepositoryError {
        if status == errSecItemNotFound { return .missing }
        if isUnavailable(status) { return .unavailable }
        return .readBackFailed
    }

    private static func isUnavailable(_ status: OSStatus) -> Bool {
        status == errSecInteractionNotAllowed || status == errSecNotAvailable || status == errSecAuthFailed
    }
}
