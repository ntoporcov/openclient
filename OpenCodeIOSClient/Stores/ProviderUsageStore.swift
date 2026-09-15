import Foundation
import Observation

@MainActor
@Observable
final class ProviderUsageStore {
    struct RefreshHandle: Equatable, Sendable {
        let account: ProviderUsageAccount
        let token: UUID
        let previousStatus: ProviderUsageStatus
    }

    enum SetupPhase: Equatable {
        case idle
        case selected(ProviderUsageSetupCandidate)
        case importing(ProviderUsageSetupCandidate)
        case reviewing(ProviderUsageCredentialReview)
        case saving(ProviderUsageCredentialReview)
    }

    private(set) var accounts: [ProviderUsageAccount] = []
    private(set) var snapshots: [UUID: ProviderUsageSnapshot] = [:]
    private(set) var statuses: [UUID: ProviderUsageStatus] = [:]
    private(set) var setupPhase: SetupPhase = .idle
    private(set) var setupStatus: ProviderUsageStatus?
    private(set) var setupImportError: ProviderUsageCredentialImportError?
    private(set) var candidateReadiness: ProviderUsageDiscoveryReadiness = .notHydrated
    private(set) var candidates: [ProviderUsageDiscoveryCandidate] = []
    private(set) var candidateContext: ProviderUsageDiscoveryContext?
    private(set) var generation = UUID()
    private var refreshes: [UUID: RefreshHandle] = [:]

    func hasDiscoveryResult(_ result: ProviderUsageDiscoveryResult) -> Bool {
        candidateReadiness == result.readiness
            && candidateContext == result.context
            && candidates == (result.readiness == .ready ? result.candidates : [])
    }

    func replaceCandidates(with result: ProviderUsageDiscoveryResult) {
        generation = UUID()
        candidateReadiness = result.readiness
        candidateContext = result.context
        var seen: Set<ProviderUsageCandidateIdentity> = []
        candidates = result.readiness == .ready ? result.candidates.filter { candidate in
            guard candidate.context == result.context,
                  candidate.id.backendDescriptorID == result.context.backend.id,
                  candidate.id.apiProfile == result.context.apiProfile,
                  candidate.id.scope == result.context.scope,
                  seen.insert(candidate.id).inserted else { return false }
            if case .available(_, let credentialKind) = candidate.availability {
                return candidate.expectedCredentialKind == credentialKind
            }
            return true
        } : []
        setupPhase = .idle
        setupStatus = nil
        setupImportError = nil
    }

    func clearCandidates() {
        generation = UUID()
        candidateReadiness = .notHydrated
        candidateContext = nil
        candidates = []
        setupPhase = .idle
        setupStatus = nil
        setupImportError = nil
    }

    func isSelectable(_ candidate: ProviderUsageDiscoveryCandidate, in context: ProviderUsageDiscoveryContext) -> Bool {
        candidateReadiness == .ready
            && candidateContext == context
            && candidate.context == context
            && candidates.contains(candidate)
            && candidate.availability.isSelectable
    }

    func setupCandidate(
        from candidate: ProviderUsageDiscoveryCandidate,
        in context: ProviderUsageDiscoveryContext,
        replacingAccountID: UUID? = nil
    ) -> ProviderUsageSetupCandidate? {
        guard isSelectable(candidate, in: context),
              case .available(let sourceKind, let credentialKind) = candidate.availability,
              candidate.expectedCredentialKind == credentialKind else { return nil }
        return ProviderUsageSetupCandidate(
            id: UUID(),
            provider: candidate.provider,
            discoveryContext: context,
            sourceIdentity: candidate.id.source,
            sourceKind: sourceKind,
            credentialKind: credentialKind,
            replacingAccountID: replacingAccountID
        )
    }

    func select(_ candidate: ProviderUsageSetupCandidate) {
        generation = UUID()
        setupPhase = .selected(candidate)
        setupStatus = nil
        setupImportError = nil
    }

    func beginImport(for candidate: ProviderUsageSetupCandidate) -> UUID? {
        guard setupPhase == .selected(candidate) else { return nil }
        let operationGeneration = generation
        setupPhase = .importing(candidate)
        setupStatus = nil
        setupImportError = nil
        return operationGeneration
    }

    func present(_ review: ProviderUsageCredentialReview, generation expected: UUID) {
        guard generation == expected, case .importing(review.candidate) = setupPhase else { return }
        setupPhase = .reviewing(review)
    }

    func failImport(_ error: ProviderUsageCredentialImportError, generation expected: UUID) {
        guard generation == expected else { return }
        setupPhase = .idle
        setupStatus = .importFailed
        setupImportError = error
    }

    func beginSave(review: ProviderUsageCredentialReview) -> UUID? {
        guard setupPhase == .reviewing(review) else { return nil }
        let operationGeneration = generation
        setupPhase = .saving(review)
        setupStatus = nil
        setupImportError = nil
        return operationGeneration
    }

    func applySavedAccount(_ account: ProviderUsageAccount, generation expected: UUID) -> Bool {
        guard generation == expected else { return false }
        refreshes[account.id] = nil
        accounts.removeAll { $0.id == account.id }
        accounts.append(account)
        statuses[account.id] = .savedNotChecked
        snapshots[account.id] = nil
        setupPhase = .idle
        setupImportError = nil
        return true
    }

    func failSave(generation expected: UUID) {
        guard generation == expected else { return }
        setupPhase = .idle
        setupStatus = .saveFailed
        setupImportError = nil
    }

    func beginRefresh(accountID: UUID) -> RefreshHandle? {
        guard refreshes[accountID] == nil,
              let account = accounts.first(where: { $0.id == accountID }) else { return nil }
        let handle = RefreshHandle(
            account: account,
            token: UUID(),
            previousStatus: statuses[accountID] ?? (snapshots[accountID] == nil ? .savedNotChecked : .ready)
        )
        refreshes[accountID] = handle
        statuses[accountID] = .refreshing
        return handle
    }

    func applyRefresh(_ snapshot: ProviderUsageSnapshot, handle: RefreshHandle) -> Bool {
        guard takeRefresh(handle) else { return false }
        snapshots[handle.account.id] = snapshot
        statuses[handle.account.id] = .ready
        return true
    }

    func applyRefreshFailure(_ error: ProviderUsageError, handle: RefreshHandle) -> Bool {
        guard takeRefresh(handle) else { return false }
        statuses[handle.account.id] = .usageFailed(error)
        return true
    }

    func isRefreshActive(_ handle: RefreshHandle) -> Bool {
        refreshes[handle.account.id] == handle
            && accounts.contains(where: { $0 == handle.account })
    }

    func cancelRefresh(_ handle: RefreshHandle) {
        guard refreshes[handle.account.id]?.token == handle.token else { return }
        refreshes[handle.account.id] = nil
        statuses[handle.account.id] = handle.previousStatus
    }

    func replaceAccounts(_ accounts: [ProviderUsageAccount]) {
        let currentByID = Dictionary(uniqueKeysWithValues: self.accounts.map { ($0.id, $0) })
        let changedIDs = Set(self.accounts.compactMap { old in
            guard let current = accounts.first(where: { $0.id == old.id }) else { return old.id }
            return current == old ? nil : old.id
        })
        let invalidatedIDs = refreshes.values.compactMap { handle -> UUID? in
            guard let current = accounts.first(where: { $0.id == handle.account.id }),
                  current == handle.account,
                  currentByID[handle.account.id] == handle.account else {
                return handle.account.id
            }
            return nil
        }
        for id in invalidatedIDs {
            refreshes[id] = nil
        }
        generation = UUID()
        self.accounts = accounts
        snapshots = snapshots.filter { id, _ in
            accounts.contains { $0.id == id } && !changedIDs.contains(id)
        }
        statuses = Dictionary(uniqueKeysWithValues: accounts.map { account in
            (account.id, changedIDs.contains(account.id) ? .savedNotChecked : (statuses[account.id] ?? .savedNotChecked))
        })
        setupPhase = .idle
        setupStatus = nil
        setupImportError = nil
    }

    func cancelSetup() {
        generation = UUID()
        setupPhase = .idle
        setupStatus = nil
        setupImportError = nil
    }

    func beginRemoval(accountID: UUID) -> UUID? {
        guard accounts.contains(where: { $0.id == accountID }) else { return nil }
        if let refresh = refreshes[accountID] {
            refreshes[accountID] = nil
            statuses[accountID] = refresh.previousStatus
        }
        generation = UUID()
        return generation
    }

    func invalidateRefreshes() {
        let active = Array(refreshes.values)
        refreshes.removeAll()
        for refresh in active where accounts.contains(where: { $0.id == refresh.account.id }) {
            statuses[refresh.account.id] = refresh.previousStatus
        }
    }

    private func takeRefresh(_ handle: RefreshHandle) -> Bool {
        guard isRefreshActive(handle) else { return false }
        refreshes[handle.account.id] = nil
        return true
    }

    func applyRemoval(accountID: UUID, generation expected: UUID) {
        guard generation == expected else { return }
        accounts.removeAll { $0.id == accountID }
        snapshots[accountID] = nil
        statuses[accountID] = nil
    }

    func failRemoval(accountID: UUID, generation expected: UUID) {
        guard generation == expected, accounts.contains(where: { $0.id == accountID }) else { return }
        statuses[accountID] = .removalFailed
    }
}
