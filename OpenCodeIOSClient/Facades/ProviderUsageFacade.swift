import Foundation

@MainActor
final class ProviderUsageFacade {
    typealias ContextProvider = @MainActor @Sendable () -> ProviderUsageDiscoveryContext?
    typealias LegacyStateProvider = @MainActor () -> ProviderUsageLegacyProviderState
    typealias V2StateProvider = @MainActor () -> ProviderUsageV2ProviderState
    typealias ImporterFactory = @MainActor (
        _ candidate: ProviderUsageSetupCandidate,
        _ allowsInsecureHTTP: Bool,
        _ currentContext: @escaping PTYProviderUsageCredentialImporter.ContextProvider
    ) throws -> any ProviderUsageCredentialImporter

    let store: ProviderUsageStore
    let displayStore: ProviderUsageDisplayStore

    private let accounts: any ProviderUsageAccountRepository
    private let providerClient: any ProviderUsageFetching
    private let contextProvider: ContextProvider
    private let legacyStateProvider: LegacyStateProvider
    private let v2StateProvider: V2StateProvider
    private let importerFactory: ImporterFactory
    private var didRequestAccountLoad = false
    private var isActive = true
    private var visibleProvider: ProviderUsageProvider?
    private var visibleDisplayDestinations: Set<OpenCodeProviderUsageDestination> = []
    private var synchronizedContext: ProviderUsageDiscoveryContext?
    private var loadTask: Task<Void, Never>?
    private var setupTask: Task<Void, Never>?
    private var setupTaskID: UUID?
    private var refreshTasks: [UUID: Task<Void, Never>] = [:]
    private var refreshTaskIDs: [UUID: UUID] = [:]

    init(
        store: ProviderUsageStore,
        displayStore: ProviderUsageDisplayStore = ProviderUsageDisplayStore(),
        accounts: any ProviderUsageAccountRepository,
        providerClient: any ProviderUsageFetching,
        contextProvider: @escaping ContextProvider,
        legacyStateProvider: @escaping LegacyStateProvider,
        v2StateProvider: @escaping V2StateProvider,
        importerFactory: @escaping ImporterFactory
    ) {
        self.store = store
        self.displayStore = displayStore
        self.accounts = accounts
        self.providerClient = providerClient
        self.contextProvider = contextProvider
        self.legacyStateProvider = legacyStateProvider
        self.v2StateProvider = v2StateProvider
        self.importerFactory = importerFactory
    }

    func loadPersistedAccountsOnce() async {
        guard !didRequestAccountLoad else {
            await loadTask?.value
            return
        }
        didRequestAccountLoad = true
        let task = Task { [store, accounts, providerClient] in
            await ProviderUsageCoordinator(
                store: store, importer: nil, accounts: accounts, providerClient: providerClient
            ).load()
        }
        loadTask = task
        await task.value
        loadTask = nil
        synchronizeDisplayStore()
    }

    func appeared(provider: ProviderUsageProvider) async {
        visibleProvider = provider
        await loadPersistedAccountsOnce()
        synchronizeDiscovery()
        guard isActive else { return }
        await refreshStaleAccounts(provider: provider)
    }

    func synchronizeDiscovery() {
        guard isActive, let context = contextProvider() else {
            clearDiscovery()
            return
        }
        let result = ProviderUsageDiscovery.discover(
            context: context,
            legacy: legacyStateProvider(),
            v2: v2StateProvider()
        )
        synchronizedContext = context
        guard !store.hasDiscoveryResult(result) else { return }
        cancelTransientWork()
        store.replaceCandidates(with: result)
    }

    func clearDiscovery() {
        synchronizedContext = nil
        cancelTransientWork()
        if store.candidateContext != nil || store.candidateReadiness != .notHydrated || !store.candidates.isEmpty {
            store.clearCandidates()
        } else {
            store.cancelSetup()
        }
    }

    @discardableResult
    func beginSetup(
        from candidate: ProviderUsageDiscoveryCandidate,
        replacingAccountID: UUID? = nil
    ) -> Bool {
        guard isActive, let context = contextProvider(), context == synchronizedContext,
              let setup = store.setupCandidate(
                from: candidate,
                in: context,
                replacingAccountID: replacingAccountID ?? trackedAccount(for: candidate)?.id
              ) else { return false }
        cancelSetupTask()
        store.select(setup)
        return true
    }

    func hasTrackedAccount(for candidate: ProviderUsageDiscoveryCandidate) -> Bool {
        trackedAccount(for: candidate) != nil
    }

    func approveRead(allowsInsecureHTTP: Bool = false) async {
        guard isActive, case .selected(let candidate) = store.setupPhase,
              contextProvider() == candidate.discoveryContext else {
            cancel()
            return
        }

        let currentContext: PTYProviderUsageCredentialImporter.ContextProvider = { [weak self] in
            await self?.contextProvider()
        }
        let importer: any ProviderUsageCredentialImporter
        do {
            importer = try importerFactory(candidate, allowsInsecureHTTP, currentContext)
        } catch let error as ProviderUsageCredentialImportError {
            guard let generation = store.beginImport(for: candidate) else { return }
            store.failImport(error, generation: generation)
            return
        } catch {
            guard let generation = store.beginImport(for: candidate) else { return }
            store.failImport(.connectionFailed, generation: generation)
            return
        }

        cancelSetupTask()
        let taskID = UUID()
        let task = Task { [store, accounts, providerClient] in
            await ProviderUsageCoordinator(
                store: store, importer: importer, accounts: accounts, providerClient: providerClient
            ).approveRead()
        }
        setupTask = task
        setupTaskID = taskID
        await task.value
        guard setupTaskID == taskID else { return }
        setupTask = nil
        setupTaskID = nil
        guard case .reviewing = store.setupPhase else { return }
        await saveImportedCredential()
    }

    private func saveImportedCredential() async {
        guard isActive, case .reviewing(let review) = store.setupPhase,
              contextProvider() == review.candidate.discoveryContext else {
            cancel()
            return
        }
        cancelSetupTask()
        let taskID = UUID()
        let task = Task { [store, accounts, providerClient] in
            await ProviderUsageCoordinator(
                store: store, importer: nil, accounts: accounts, providerClient: providerClient
            ).approveSave()
        }
        setupTask = task
        setupTaskID = taskID
        await task.value
        if setupTaskID == taskID {
            setupTask = nil
            setupTaskID = nil
        }
        synchronizeDisplayStore()
    }

    func cancel() {
        cancelSetupTask()
        store.cancelSetup()
    }

    func refresh(accountID: UUID) async {
        guard refreshTasks[accountID] == nil else {
            await refreshTasks[accountID]?.value
            return
        }
        let renewal = sourceRenewal(for: accountID)
        let task = Task { [store, accounts, providerClient] in
            await ProviderUsageCoordinator(
                store: store,
                importer: renewal?.importer,
                renewalCandidate: renewal?.candidate,
                accounts: accounts,
                providerClient: providerClient
            ).refresh(accountID: accountID)
        }
        let taskID = UUID()
        refreshTasks[accountID] = task
        refreshTaskIDs[accountID] = taskID
        await task.value
        if refreshTaskIDs[accountID] == taskID {
            refreshTasks[accountID] = nil
            refreshTaskIDs[accountID] = nil
        }
        synchronizeDisplayStore()
    }

    func refreshAccounts(ids: [UUID]) async {
        var seen: Set<UUID> = []
        for accountID in ids where seen.insert(accountID).inserted {
            guard isActive, !Task.isCancelled else { return }
            await refresh(accountID: accountID)
        }
    }

    func prepareDisplay(
        _ destination: OpenCodeProviderUsageDestination,
        referenceDate: Date = Date(),
        maxAge: TimeInterval = 5 * 60
    ) async {
        await loadPersistedAccountsOnce()
        synchronizeDisplayStore()
        let selectedIDs = Set(displayStore.selectedAccountIDs(for: destination))
        let staleIDs = store.accounts.compactMap { account -> UUID? in
            guard selectedIDs.contains(account.id) else { return nil }
            guard let fetchedAt = store.snapshots[account.id]?.fetchedAt else { return account.id }
            return referenceDate.timeIntervalSince(fetchedAt) >= maxAge ? account.id : nil
        }
        await refreshAccounts(ids: staleIDs)
    }

    func displayAppeared(_ destination: OpenCodeProviderUsageDestination) async {
        visibleDisplayDestinations.insert(destination)
        await prepareDisplay(destination)
    }

    func displayDisappeared(_ destination: OpenCodeProviderUsageDestination) {
        visibleDisplayDestinations.remove(destination)
    }

    func prepareDisplayConfiguration(
        referenceDate: Date = Date(),
        maxAge: TimeInterval = 5 * 60
    ) async {
        await loadPersistedAccountsOnce()
        synchronizeDisplayStore()
        let staleIDs = store.accounts.compactMap { account -> UUID? in
            guard let fetchedAt = store.snapshots[account.id]?.fetchedAt else { return account.id }
            return referenceDate.timeIntervalSince(fetchedAt) >= maxAge ? account.id : nil
        }
        await refreshAccounts(ids: staleIDs)
    }

    func refreshAll(provider: ProviderUsageProvider) async {
        for accountID in store.accounts.filter({ $0.provider == provider }).map(\.id) {
            await refresh(accountID: accountID)
        }
    }

    func refreshStaleAccounts(
        provider: ProviderUsageProvider,
        referenceDate: Date = Date(),
        maxAge: TimeInterval = 5 * 60
    ) async {
        let accountIDs = store.accounts.compactMap { account -> UUID? in
            guard account.provider == provider else { return nil }
            guard let fetchedAt = store.snapshots[account.id]?.fetchedAt else { return account.id }
            return referenceDate.timeIntervalSince(fetchedAt) >= maxAge ? account.id : nil
        }
        for accountID in accountIDs {
            guard isActive, visibleProvider == provider, !Task.isCancelled else { return }
            await refresh(accountID: accountID)
        }
    }

    func remove(accountID: UUID) async {
        refreshTasks.removeValue(forKey: accountID)?.cancel()
        refreshTaskIDs[accountID] = nil
        await ProviderUsageCoordinator(
            store: store, importer: nil, accounts: accounts, providerClient: providerClient
        ).remove(accountID: accountID)
        if !store.accounts.contains(where: { $0.id == accountID }) {
            displayStore.removeSelections(accountID: accountID)
        }
        synchronizeDisplayStore()
    }

    func applicationActivityChanged(isActive: Bool) {
        self.isActive = isActive
        if isActive {
            synchronizeDiscovery()
            if let visibleProvider { Task { await refreshStaleAccounts(provider: visibleProvider) } }
            for destination in visibleDisplayDestinations {
                Task { await prepareDisplay(destination) }
            }
        } else {
            clearDiscovery()
            invalidateRefreshes()
        }
    }

    func backendContextChanged() {
        let context = isActive ? contextProvider() : nil
        guard context != synchronizedContext else {
            if context != nil { synchronizeDiscovery() }
            return
        }
        clearDiscovery()
        invalidateRefreshes()
        if context != nil { synchronizeDiscovery() }
    }

    func disappeared() {
        visibleProvider = nil
        clearDiscovery()
        invalidateRefreshes()
    }

    private func cancelTransientWork() {
        cancelSetupTask()
        store.cancelSetup()
    }

    private func trackedAccount(for candidate: ProviderUsageDiscoveryCandidate) -> ProviderUsageAccount? {
        guard case .available(let sourceKind, let credentialKind) = candidate.availability else { return nil }
        return store.accounts
            .filter {
                $0.provider == candidate.provider
                    && $0.sourceConnectionID == candidate.context.backend.id
                    && $0.apiProfile == candidate.context.apiProfile
                    && $0.sourceKind == sourceKind
                    && $0.credentialKind == credentialKind
            }
            .max { $0.updatedAt < $1.updatedAt }
    }

    private func sourceRenewal(
        for accountID: UUID
    ) -> (importer: any ProviderUsageCredentialImporter, candidate: ProviderUsageSetupCandidate)? {
        guard isActive,
              let account = store.accounts.first(where: { $0.id == accountID }),
              account.provider == .codex,
              account.sourceKind == .openCodeAuth,
              account.apiProfile == .legacy,
              account.sourceRenewalApprovedAt != nil,
              let providerAccountID = account.providerAccountID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerAccountID.isEmpty,
              let sourceScope = account.sourceScope,
              let context = contextProvider(),
              context.backend.id == account.sourceConnectionID,
              context.apiProfile == account.apiProfile,
              sourceScope.matches(context.scope) else { return nil }
        let candidate = ProviderUsageSetupCandidate(
            id: UUID(),
            provider: .codex,
            discoveryContext: context,
            sourceIdentity: .legacyProvider(providerID: "openai"),
            sourceKind: .openCodeAuth,
            credentialKind: .oauthAccessToken,
            replacingAccountID: account.id
        )
        let currentContext: PTYProviderUsageCredentialImporter.ContextProvider = { [weak self] in
            await self?.contextProvider()
        }
        guard let importer = try? importerFactory(candidate, false, currentContext) else { return nil }
        return (importer, candidate)
    }

    private func cancelSetupTask() {
        setupTask?.cancel()
        setupTask = nil
        setupTaskID = nil
    }

    private func invalidateRefreshes() {
        let tasks = refreshTasks.values
        refreshTasks.removeAll()
        refreshTaskIDs.removeAll()
        for task in tasks { task.cancel() }
        store.invalidateRefreshes()
    }

    private func synchronizeDisplayStore() {
        displayStore.reconcile(accounts: store.accounts, snapshots: store.snapshots)
    }
}

@MainActor
enum OpenCodeProviderUsageComposition {
    static func makeImporter(
        candidate: ProviderUsageSetupCandidate,
        allowsInsecureHTTP: Bool,
        currentContext: @escaping PTYProviderUsageCredentialImporter.ContextProvider,
        connection: BackendConnection?
    ) throws -> any ProviderUsageCredentialImporter {
        guard let connection, !connection.isClosed,
              connection.id == candidate.discoveryContext.connectionLifetimeID,
              connection.descriptor == candidate.discoveryContext.backend,
              connection.capabilities.contains(.terminal),
              let adapter = connection.openCodeCompatibility,
              adapter.profile == .legacy,
              candidate.apiProfile == .legacy else {
            throw ProviderUsageCredentialImportError.contextChanged
        }
        let transport = try OpenCodeCredentialImportLegacyPTYTransport(client: adapter.client)
        return PTYProviderUsageCredentialImporter(
            transport: transport,
            currentContext: currentContext,
            allowsInsecureTransport: allowsInsecureHTTP
        )
    }
}
