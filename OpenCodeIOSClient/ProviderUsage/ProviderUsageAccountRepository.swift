import Foundation

enum ProviderUsageMetadataRepositoryError: Error, Equatable, Sendable {
    case unavailable
    case invalidData
    case writeFailed
}

protocol ProviderUsageMetadataRepository: Sendable {
    func load() async throws -> [ProviderUsageAccount]
    func save(_ accounts: [ProviderUsageAccount]) async throws
}

actor FileProviderUsageMetadataRepository: ProviderUsageMetadataRepository {
    private struct Envelope: Codable {
        static let currentVersion = 1
        let version: Int
        let accounts: [ProviderUsageAccount]
    }

    private let fileURL: URL
    private let fileManager: FileManager

    init(fileURL: URL? = nil, fileManager: FileManager = .default) {
        self.fileManager = fileManager
        if let fileURL {
            self.fileURL = fileURL
        } else {
            let directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("ProviderUsage", isDirectory: true)
            self.fileURL = directory.appendingPathComponent("accounts-v1.json")
        }
    }

    func load() throws -> [ProviderUsageAccount] {
        guard fileManager.fileExists(atPath: fileURL.path) else { return [] }
        do {
            let envelope = try JSONDecoder().decode(Envelope.self, from: Data(contentsOf: fileURL))
            guard envelope.version == Envelope.currentVersion,
                  envelope.accounts.allSatisfy({ $0.version == ProviderUsageAccount.currentVersion }),
                  Set(envelope.accounts.map(\.id)).count == envelope.accounts.count,
                  Set(envelope.accounts.map(\.credentialReference)).count == envelope.accounts.count else {
                throw ProviderUsageMetadataRepositoryError.invalidData
            }
            return envelope.accounts
        } catch let error as ProviderUsageMetadataRepositoryError {
            throw error
        } catch {
            throw ProviderUsageMetadataRepositoryError.invalidData
        }
    }

    func save(_ accounts: [ProviderUsageAccount]) throws {
        do {
            let directory = fileURL.deletingLastPathComponent()
            #if os(iOS)
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.complete]
            )
            #else
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            #endif
            let data = try JSONEncoder().encode(Envelope(version: Envelope.currentVersion, accounts: accounts))
            #if os(iOS)
            try data.write(to: fileURL, options: [.atomic, .completeFileProtection])
            #else
            try data.write(to: fileURL, options: .atomic)
            #endif
        } catch {
            throw ProviderUsageMetadataRepositoryError.writeFailed
        }
    }
}

enum ProviderUsageAccountRepositoryError: Error, Equatable, Sendable {
    case credential(ProviderUsageCredentialRepositoryError)
    case metadata(ProviderUsageMetadataRepositoryError)
    case removalRollbackFailed(
        metadata: ProviderUsageMetadataRepositoryError,
        credential: ProviderUsageCredentialRepositoryError
    )
    case accountMissing
    case credentialRevisionMismatch
}

struct ProviderUsageAccountSaveResult: Equatable, Sendable {
    let account: ProviderUsageAccount
    let supersededCredentialCleanupPending: Bool
}

protocol ProviderUsageAccountRepository: Sendable {
    func load() async throws -> [ProviderUsageAccount]
    func readCredential(accountID: UUID, credentialRevision: Int) async throws -> ProviderUsageTransientSecret
    func save(review: ProviderUsageCredentialReview) async throws -> ProviderUsageAccountSaveResult
    func remove(accountID: UUID) async throws
}

actor TransactionalProviderUsageAccountRepository: ProviderUsageAccountRepository {
    private let credentials: any ProviderUsageCredentialRepository
    private let metadata: any ProviderUsageMetadataRepository
    private let now: @Sendable () -> Date
    private let makeUUID: @Sendable () -> UUID

    init(
        credentials: any ProviderUsageCredentialRepository,
        metadata: any ProviderUsageMetadataRepository,
        now: @escaping @Sendable () -> Date = Date.init,
        makeUUID: @escaping @Sendable () -> UUID = UUID.init
    ) {
        self.credentials = credentials
        self.metadata = metadata
        self.now = now
        self.makeUUID = makeUUID
    }

    func load() async throws -> [ProviderUsageAccount] {
        do { return try await metadata.load() }
        catch let error as ProviderUsageMetadataRepositoryError { throw ProviderUsageAccountRepositoryError.metadata(error) }
    }

    func readCredential(accountID: UUID, credentialRevision: Int) async throws -> ProviderUsageTransientSecret {
        let committedAccounts: [ProviderUsageAccount]
        do { committedAccounts = try await metadata.load() }
        catch let error as ProviderUsageMetadataRepositoryError {
            throw ProviderUsageAccountRepositoryError.metadata(error)
        }
        guard let account = committedAccounts.first(where: { $0.id == accountID }),
              account.credentialRevision == credentialRevision else {
            throw ProviderUsageAccountRepositoryError.credentialRevisionMismatch
        }
        do {
            return try credentials.read(reference: account.credentialReference)
        } catch let error as ProviderUsageCredentialRepositoryError {
            throw ProviderUsageAccountRepositoryError.credential(error)
        }
    }

    func save(review: ProviderUsageCredentialReview) async throws -> ProviderUsageAccountSaveResult {
        let previousAccounts: [ProviderUsageAccount]
        do { previousAccounts = try await metadata.load() }
        catch let error as ProviderUsageMetadataRepositoryError { throw ProviderUsageAccountRepositoryError.metadata(error) }

        let previous = review.candidate.replacingAccountID.flatMap { id in
            previousAccounts.first { $0.id == id }
        }
        if review.candidate.replacingAccountID != nil, previous == nil {
            throw ProviderUsageAccountRepositoryError.accountMissing
        }

        let date = now()
        let credentialReference = makeUUID()
        let account = ProviderUsageAccount(
            id: previous?.id ?? makeUUID(),
            provider: review.candidate.provider,
            sourceConnectionID: review.candidate.sourceConnectionID,
            apiProfile: review.candidate.apiProfile,
            sourceKind: review.candidate.sourceKind,
            credentialKind: review.candidate.credentialKind,
            providerAccountID: review.providerAccountID,
            credentialReference: credentialReference,
            credentialRevision: (previous?.credentialRevision ?? 0) + 1,
            credentialExpiresAt: review.credentialExpiresAt,
            createdAt: previous?.createdAt ?? date,
            updatedAt: date
        )

        do { try credentials.write(review.secret, reference: credentialReference) }
        catch let error as ProviderUsageCredentialRepositoryError {
            throw ProviderUsageAccountRepositoryError.credential(error)
        }

        var updated = previousAccounts.filter { $0.id != account.id }
        updated.append(account)
        do {
            try await metadata.save(updated)
        } catch let error as ProviderUsageMetadataRepositoryError {
            // A failed cleanup can leave only an item in this feature's private namespace.
            // TODO: reconcile service-owned references against committed metadata after startup.
            try? credentials.delete(reference: credentialReference)
            throw ProviderUsageAccountRepositoryError.metadata(error)
        }

        var cleanupPending = false
        if let previous {
            do { try credentials.delete(reference: previous.credentialReference) }
            catch { cleanupPending = true }
        }
        return ProviderUsageAccountSaveResult(
            account: account,
            supersededCredentialCleanupPending: cleanupPending
        )
    }

    func remove(accountID: UUID) async throws {
        let accounts: [ProviderUsageAccount]
        do { accounts = try await metadata.load() }
        catch let error as ProviderUsageMetadataRepositoryError { throw ProviderUsageAccountRepositoryError.metadata(error) }
        guard let account = accounts.first(where: { $0.id == accountID }) else {
            throw ProviderUsageAccountRepositoryError.accountMissing
        }

        let secret: ProviderUsageTransientSecret
        do { secret = try credentials.read(reference: account.credentialReference) }
        catch let error as ProviderUsageCredentialRepositoryError {
            throw ProviderUsageAccountRepositoryError.credential(error)
        }
        do { try credentials.delete(reference: account.credentialReference) }
        catch let error as ProviderUsageCredentialRepositoryError {
            throw ProviderUsageAccountRepositoryError.credential(error)
        }
        do {
            try await metadata.save(accounts.filter { $0.id != accountID })
        } catch let error as ProviderUsageMetadataRepositoryError {
            // Keep committed metadata usable if its atomic replacement fails.
            do {
                try credentials.write(secret, reference: account.credentialReference)
            } catch let credentialError as ProviderUsageCredentialRepositoryError {
                throw ProviderUsageAccountRepositoryError.removalRollbackFailed(
                    metadata: error,
                    credential: credentialError
                )
            }
            throw ProviderUsageAccountRepositoryError.metadata(error)
        }
    }
}
