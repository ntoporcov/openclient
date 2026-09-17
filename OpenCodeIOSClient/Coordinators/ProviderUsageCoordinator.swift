import Foundation

protocol ProviderUsageCredentialImporter: Sendable {
    func importCredential(for candidate: ProviderUsageSetupCandidate) async throws -> ProviderUsageCredentialReview
    func renewCredential(
        for candidate: ProviderUsageSetupCandidate,
        expectedAccountID: String,
        currentAccessToken: String
    ) async throws -> ProviderUsageCredentialRenewal
}

extension ProviderUsageCredentialImporter {
    func renewCredential(
        for candidate: ProviderUsageSetupCandidate,
        expectedAccountID: String,
        currentAccessToken: String
    ) async throws -> ProviderUsageCredentialRenewal {
        throw ProviderUsageCredentialImportError.unsupportedSource
    }
}

protocol ProviderUsageFetching: Sendable {
    func fetchUsage(
        provider: ProviderUsageProvider,
        credentialKind: ProviderUsageCredentialKind,
        secret: ProviderUsageTransientSecret,
        providerAccountID: String?,
        credentialExpiresAt: Date?
    ) async throws -> ProviderUsageSnapshot
}

struct RoutedProviderUsageClient: ProviderUsageFetching {
    private let openRouter: OpenRouterUsageAdapter
    private let codex: CodexUsageAdapter

    init(
        openRouter: OpenRouterUsageAdapter = OpenRouterUsageAdapter(),
        codex: CodexUsageAdapter = CodexUsageAdapter()
    ) {
        self.openRouter = openRouter
        self.codex = codex
    }

    func fetchUsage(
        provider: ProviderUsageProvider,
        credentialKind: ProviderUsageCredentialKind,
        secret: ProviderUsageTransientSecret,
        providerAccountID: String?,
        credentialExpiresAt: Date?
    ) async throws -> ProviderUsageSnapshot {
        switch (provider, credentialKind) {
        case (.openRouter, .apiKey):
            return try await openRouter.fetch(apiKey: secret.value)
        case (.codex, .oauthAccessToken):
            return try await codex.fetch(
                accessToken: secret.value,
                accountID: providerAccountID,
                credentialExpiresAt: credentialExpiresAt
            )
        default:
            throw ProviderUsageError.invalidCredential
        }
    }
}

@MainActor
struct ProviderUsageCoordinator {
    let store: ProviderUsageStore
    let importer: (any ProviderUsageCredentialImporter)?
    var renewalCandidate: ProviderUsageSetupCandidate? = nil
    let accounts: any ProviderUsageAccountRepository
    let providerClient: any ProviderUsageFetching

    func load() async {
        guard let loaded = try? await accounts.load(), !Task.isCancelled else { return }
        store.replaceAccounts(loaded)
    }

    func select(_ candidate: ProviderUsageSetupCandidate) {
        store.select(candidate)
    }

    func approveRead() async {
        guard let importer,
              case .selected(let candidate) = store.setupPhase,
              let generation = store.beginImport(for: candidate) else { return }
        do {
            let review = try await importer.importCredential(for: candidate)
            guard !Task.isCancelled, store.generation == generation else { return }
            store.present(review, generation: generation)
        } catch is CancellationError {
            return
        } catch let error as ProviderUsageCredentialImportError {
            guard !Task.isCancelled else { return }
            store.failImport(error, generation: generation)
        } catch {
            guard !Task.isCancelled else { return }
            store.failImport(.connectionFailed, generation: generation)
        }
    }

    func approveSave() async {
        guard case .reviewing(let review) = store.setupPhase,
              let generation = store.beginSave(review: review) else { return }
        let saved: ProviderUsageAccountSaveResult
        do {
            saved = try await accounts.save(review: review)
        } catch {
            guard !Task.isCancelled else { return }
            store.failSave(generation: generation)
            return
        }
        guard !Task.isCancelled,
              store.applySavedAccount(saved.account, generation: generation) else { return }

        guard let refresh = store.beginRefresh(accountID: saved.account.id) else { return }
        await performRefresh(refresh, secret: review.secret)
    }

    func refresh(accountID: UUID) async {
        guard let refresh = store.beginRefresh(accountID: accountID) else { return }
        do {
            let secret = try await accounts.readCredential(
                accountID: refresh.account.id,
                credentialRevision: refresh.account.credentialRevision
            )
            guard !Task.isCancelled, store.isRefreshActive(refresh) else {
                store.cancelRefresh(refresh)
                return
            }
            await performRefresh(refresh, secret: secret)
        } catch is CancellationError {
            store.cancelRefresh(refresh)
        } catch let error as ProviderUsageAccountRepositoryError {
            if !Task.isCancelled, error != .credentialRevisionMismatch, error != .accountMissing {
                _ = store.applyRefreshFailure(mapRepositoryError(error), handle: refresh)
            } else {
                store.cancelRefresh(refresh)
            }
        } catch {
            if Task.isCancelled { store.cancelRefresh(refresh) }
            else { _ = store.applyRefreshFailure(.credentialUnavailable, handle: refresh) }
        }
    }

    private func performRefresh(_ refresh: ProviderUsageStore.RefreshHandle, secret: ProviderUsageTransientSecret) async {
        guard !Task.isCancelled, store.isRefreshActive(refresh) else {
            store.cancelRefresh(refresh)
            return
        }
        do {
            let snapshot = try await providerClient.fetchUsage(
                provider: refresh.account.provider,
                credentialKind: refresh.account.credentialKind,
                secret: secret,
                providerAccountID: refresh.account.providerAccountID,
                credentialExpiresAt: refresh.account.credentialExpiresAt
            )
            if Task.isCancelled { store.cancelRefresh(refresh) }
            else { _ = store.applyRefresh(snapshot, handle: refresh) }
        } catch is CancellationError {
            store.cancelRefresh(refresh)
        } catch let error as ProviderUsageError {
            if Task.isCancelled {
                store.cancelRefresh(refresh)
            } else if shouldRenewCredential(after: error, account: refresh.account),
                      let importer,
                      let renewalCandidate {
                await renewCredentialAndRetry(
                    refresh,
                    currentSecret: secret,
                    importer: importer,
                    candidate: renewalCandidate
                )
            } else {
                _ = store.applyRefreshFailure(error, handle: refresh)
            }
        } catch {
            if Task.isCancelled { store.cancelRefresh(refresh) }
            else { _ = store.applyRefreshFailure(.network, handle: refresh) }
        }
    }

    private func renewCredentialAndRetry(
        _ refresh: ProviderUsageStore.RefreshHandle,
        currentSecret: ProviderUsageTransientSecret,
        importer: any ProviderUsageCredentialImporter,
        candidate: ProviderUsageSetupCandidate
    ) async {
        var activeRefresh = refresh
        do {
            guard let expectedAccountID = refresh.account.providerAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !expectedAccountID.isEmpty else {
                throw ProviderUsageError.accountMismatch
            }
            let rotated = try await importer.renewCredential(
                for: candidate,
                expectedAccountID: expectedAccountID,
                currentAccessToken: currentSecret.value
            )
            guard rotated.providerAccountID == expectedAccountID else {
                throw ProviderUsageError.accountMismatch
            }
            // Once the provider issues a token, persist it even if UI work was cancelled.
            let saved = try await accounts.rotateCredential(
                accountID: refresh.account.id,
                credentialRevision: refresh.account.credentialRevision,
                secret: rotated.secret,
                expiresAt: rotated.expiresAt,
                providerAccountID: expectedAccountID
            )
            guard let retry = store.reconcileCredentialRotation(
                saved.account,
                replacing: refresh.account,
                handle: refresh
            ) else {
                store.cancelRefresh(refresh)
                return
            }
            activeRefresh = retry
            try Task.checkCancellation()
            let snapshot = try await providerClient.fetchUsage(
                provider: saved.account.provider,
                credentialKind: saved.account.credentialKind,
                secret: rotated.secret,
                providerAccountID: saved.account.providerAccountID,
                credentialExpiresAt: saved.account.credentialExpiresAt
            )
            if Task.isCancelled { store.cancelRefresh(activeRefresh) }
            else { _ = store.applyRefresh(snapshot, handle: activeRefresh) }
        } catch is CancellationError {
            store.cancelRefresh(activeRefresh)
        } catch let error as ProviderUsageCredentialImportError {
            if Task.isCancelled { store.cancelRefresh(activeRefresh) }
            else { _ = store.applyRefreshFailure(mapRenewalError(error), handle: activeRefresh) }
        } catch let error as ProviderUsageError {
            if Task.isCancelled { store.cancelRefresh(activeRefresh) }
            else { _ = store.applyRefreshFailure(error, handle: activeRefresh) }
        } catch let error as ProviderUsageAccountRepositoryError {
            if Task.isCancelled { store.cancelRefresh(activeRefresh) }
            else { _ = store.applyRefreshFailure(mapRepositoryError(error), handle: activeRefresh) }
        } catch {
            if Task.isCancelled { store.cancelRefresh(activeRefresh) }
            else { _ = store.applyRefreshFailure(.network, handle: activeRefresh) }
        }
    }

    private func shouldRenewCredential(
        after error: ProviderUsageError,
        account: ProviderUsageAccount
    ) -> Bool {
        guard account.provider == .codex, account.credentialKind == .oauthAccessToken else { return false }
        return error == .credentialExpired || error == .unauthorized
    }

    private func mapRepositoryError(_ error: ProviderUsageAccountRepositoryError) -> ProviderUsageError {
        switch error {
        case .credential(.missing), .credential(.readBackFailed), .accountMissing, .credentialRevisionMismatch:
            return .invalidCredential
        case .credential(.unavailable), .credential(.writeFailed), .credential(.deleteFailed), .credential(.invalidConfiguration),
             .metadata, .removalRollbackFailed, .credentialCleanupFailed:
            return .credentialUnavailable
        }
    }

    private func mapRenewalError(_ error: ProviderUsageCredentialImportError) -> ProviderUsageError {
        switch error {
        case .sourceRefreshRejected:
            return .unauthorized
        case .accountMismatch:
            return .accountMismatch
        default:
            return .credentialUnavailable
        }
    }

    func cancelSetup() {
        store.cancelSetup()
    }

    func remove(accountID: UUID) async {
        guard let generation = store.beginRemoval(accountID: accountID) else { return }
        do {
            try await accounts.remove(accountID: accountID)
            guard !Task.isCancelled else { return }
            store.applyRemoval(accountID: accountID, generation: generation)
        } catch {
            guard !Task.isCancelled else { return }
            store.failRemoval(accountID: accountID, generation: generation)
        }
    }
}
