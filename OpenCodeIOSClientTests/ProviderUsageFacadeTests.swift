import XCTest
@testable import OpenClient

@MainActor
final class ProviderUsageFacadeTests: XCTestCase {
    func testIdenticalDiscoveryPreservesSetupAndImporterIsCreatedOnlyForApprovedRead() async throws {
        let context = Self.context()
        let source = ProviderUsageLegacyProviderState(
            readiness: .ready,
            connectedProviders: [.init(id: "openrouter", label: "Synthetic", source: .api)]
        )
        let recorder = ProviderUsageImporterFactoryRecorder()
        let store = ProviderUsageStore()
        let facade = makeFacade(store: store, context: { context }, legacy: { source }) {
            candidate, allowsHTTP, _ in
            recorder.calls.append((candidate, allowsHTTP))
            return ImmediateProviderUsageImporter(candidate: candidate)
        }

        facade.synchronizeDiscovery()
        let candidate = try XCTUnwrap(store.candidates.first)
        XCTAssertTrue(facade.beginSetup(from: candidate))
        guard case .selected(let setup) = store.setupPhase else { return XCTFail("Expected selection") }
        let generation = store.generation
        facade.synchronizeDiscovery()

        XCTAssertEqual(store.generation, generation)
        XCTAssertEqual(store.setupPhase, .selected(setup))
        XCTAssertTrue(recorder.calls.isEmpty)

        await facade.approveRead(allowsInsecureHTTP: true)
        XCTAssertEqual(recorder.calls.count, 1)
        XCTAssertTrue(recorder.calls[0].1)
        XCTAssertEqual(recorder.calls[0].0.discoveryContext, context)

        facade.cancel()
        XCTAssertTrue(facade.beginSetup(from: candidate))
        await facade.approveRead()
        XCTAssertEqual(recorder.calls.map(\.1), [true, false])
    }

    func testExactTrackedSourceDefaultsToReplacementAndFlagsChangedProviderAccount() throws {
        let context = Self.context()
        let original = Self.account()
        let tracked = ProviderUsageAccount(
            id: original.id,
            provider: original.provider,
            sourceConnectionID: original.sourceConnectionID,
            apiProfile: original.apiProfile,
            sourceKind: original.sourceKind,
            credentialKind: original.credentialKind,
            providerAccountID: "provider-account-a",
            credentialReference: original.credentialReference,
            credentialRevision: original.credentialRevision,
            createdAt: original.createdAt,
            updatedAt: original.updatedAt
        )
        let store = ProviderUsageStore()
        store.replaceAccounts([tracked])
        let facade = makeFacade(store: store, context: { context })
        facade.synchronizeDiscovery()
        let candidate = try XCTUnwrap(store.candidates.first)

        XCTAssertTrue(facade.hasTrackedAccount(for: candidate))
        XCTAssertTrue(facade.beginSetup(from: candidate))
        guard case .selected(let setup) = store.setupPhase else { return XCTFail("Expected replacement selection") }
        XCTAssertEqual(setup.replacingAccountID, tracked.id)

        let changed = ProviderUsageCredentialReview(
            candidate: setup,
            secret: .init(value: "synthetic-secret"),
            providerAccountID: "provider-account-b",
            credentialExpiresAt: nil
        )
        XCTAssertTrue(facade.replacementChangesProviderAccount(changed))

        let unchanged = ProviderUsageCredentialReview(
            candidate: setup,
            secret: .init(value: "synthetic-secret"),
            providerAccountID: "provider-account-a",
            credentialExpiresAt: nil
        )
        XCTAssertFalse(facade.replacementChangesProviderAccount(unchanged))
    }

    func testContextSwitchAndBackgroundDropLateImportWhileRetainingAccounts() async throws {
        let first = Self.context(lifetime: Self.uuid("11111111-1111-1111-1111-111111111111"))
        let second = Self.context(lifetime: Self.uuid("22222222-2222-2222-2222-222222222222"))
        let contextBox = ProviderUsageContextBox(first)
        let importer = DeferredFacadeProviderUsageImporter()
        let account = Self.account()
        let repository = FacadeProviderUsageAccountRepository(accounts: [account])
        let store = ProviderUsageStore()
        let facade = makeFacade(
            store: store,
            accounts: repository,
            context: { contextBox.value },
            importerFactory: { _, _, _ in importer }
        )
        await facade.loadPersistedAccountsOnce()
        facade.synchronizeDiscovery()
        XCTAssertTrue(facade.beginSetup(from: try XCTUnwrap(store.candidates.first)))

        let operation = Task { await facade.approveRead() }
        await importer.waitUntilCalled()
        contextBox.value = second
        facade.backendContextChanged()
        await importer.resolve(candidate: Self.setupCandidate(context: first))
        await operation.value

        XCTAssertEqual(store.setupPhase, .idle)
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.candidateContext, second)

        facade.applicationActivityChanged(isActive: false)
        XCTAssertNil(store.candidateContext)
        XCTAssertEqual(store.accounts, [account])
    }

    func testBackgroundDropsLateImport() async throws {
        let context = Self.context()
        let importer = DeferredFacadeProviderUsageImporter()
        let store = ProviderUsageStore()
        let facade = makeFacade(
            store: store,
            context: { context },
            importerFactory: { _, _, _ in importer }
        )
        facade.synchronizeDiscovery()
        XCTAssertTrue(facade.beginSetup(from: try XCTUnwrap(store.candidates.first)))

        let operation = Task { await facade.approveRead() }
        await importer.waitUntilCalled()
        facade.applicationActivityChanged(isActive: false)
        await importer.resolve(candidate: Self.setupCandidate(context: context))
        await operation.value

        XCTAssertEqual(store.setupPhase, .idle)
        XCTAssertNil(store.candidateContext)
    }

    func testDisconnectedRefreshAndRemoveUseLocalRepositories() async {
        let account = Self.account()
        let repository = FacadeProviderUsageAccountRepository(accounts: [account])
        let provider = FacadeProviderUsageFetching()
        let store = ProviderUsageStore()
        let facade = makeFacade(
            store: store,
            accounts: repository,
            providerClient: provider,
            context: { nil }
        )

        await facade.loadPersistedAccountsOnce()
        await facade.refresh(accountID: account.id)
        let fetchCount = await provider.callCount
        XCTAssertEqual(store.statuses[account.id], .ready)
        XCTAssertEqual(fetchCount, 1)

        await facade.remove(accountID: account.id)
        let removeCount = await repository.removeCount
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(removeCount, 1)
    }

    func testVisibleScreenRefreshesOnlyStaleAccounts() async throws {
        let account = Self.account()
        let repository = FacadeProviderUsageAccountRepository(accounts: [account])
        let provider = FacadeProviderUsageFetching()
        let store = ProviderUsageStore()
        let fetchedAt = Date()
        store.replaceAccounts([account])
        let handle = try XCTUnwrap(store.beginRefresh(accountID: account.id))
        XCTAssertTrue(store.applyRefresh(.init(
            provider: account.provider,
            accountLabel: nil,
            fetchedAt: fetchedAt,
            credentialExpiresAt: nil,
            metrics: []
        ), handle: handle))
        let facade = makeFacade(
            store: store,
            accounts: repository,
            providerClient: provider,
            context: { nil }
        )

        await facade.appeared(provider: account.provider)
        var fetchCount = await provider.callCount
        XCTAssertEqual(fetchCount, 0)

        await facade.refreshStaleAccounts(provider: account.provider, referenceDate: fetchedAt.addingTimeInterval(301))
        fetchCount = await provider.callCount
        XCTAssertEqual(fetchCount, 1)

        facade.disappeared()
        await facade.refreshStaleAccounts(provider: account.provider, referenceDate: fetchedAt.addingTimeInterval(602))
        fetchCount = await provider.callCount
        XCTAssertEqual(fetchCount, 1)
    }

    func testRefreshAllAndStaleRefreshAreProviderScoped() async {
        let openRouter = Self.account()
        let codex = ProviderUsageAccount(
            id: Self.uuid("CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC"),
            provider: .codex,
            sourceConnectionID: openRouter.sourceConnectionID,
            apiProfile: .legacy,
            sourceKind: .openCodeAuth,
            credentialKind: .oauthAccessToken,
            credentialReference: Self.uuid("DDDDDDDD-DDDD-DDDD-DDDD-DDDDDDDDDDDD"),
            credentialRevision: 1,
            createdAt: openRouter.createdAt,
            updatedAt: openRouter.updatedAt
        )
        let repository = FacadeProviderUsageAccountRepository(accounts: [openRouter, codex])
        let provider = FacadeProviderUsageFetching()
        let store = ProviderUsageStore()
        let facade = makeFacade(store: store, accounts: repository, providerClient: provider, context: { nil })
        await facade.loadPersistedAccountsOnce()

        await facade.refreshAll(provider: .codex)
        var refreshedProviders = await provider.providers
        XCTAssertEqual(refreshedProviders, [.codex])

        await facade.appeared(provider: .openRouter)
        refreshedProviders = await provider.providers
        XCTAssertEqual(refreshedProviders, [.codex, .openRouter])
    }

    func testDiscoveryReadsHydratedSnapshotsWithoutMutatingProviderStores() {
        let modelStore = ModelConfigurationStore()
        modelStore.applyProviderState(.init(
            all: [.init(id: "openrouter", name: "Synthetic", models: [:], source: "api", env: nil, key: nil, options: nil)],
            connected: ["openrouter"],
            default: [:]
        ))
        let v2Store = V2ProviderStore()
        let facade = ProviderUsageFacade(
            store: ProviderUsageStore(),
            accounts: FacadeProviderUsageAccountRepository(),
            providerClient: FacadeProviderUsageFetching(),
            contextProvider: { Self.context() },
            legacyStateProvider: { ProviderUsageDiscovery.legacyState(from: modelStore) },
            v2StateProvider: { ProviderUsageDiscovery.v2State(from: v2Store) },
            importerFactory: { _, _, _ in throw ProviderUsageCredentialImportError.unsupportedSource }
        )

        facade.synchronizeDiscovery()

        XCTAssertTrue(modelStore.isProviderStateReady)
        XCTAssertFalse(modelStore.isLoadingProviders)
        XCTAssertFalse(v2Store.isReady)
        XCTAssertFalse(v2Store.isLoading)
        XCTAssertEqual(facade.store.candidates.count, 1)
    }

    func testImporterFactoryPreservesTypedFailureAndMapsUnknownFailure() async throws {
        let context = Self.context()
        let typedStore = ProviderUsageStore()
        let typedFacade = makeFacade(
            store: typedStore,
            context: { context },
            importerFactory: { _, _, _ in throw ProviderUsageCredentialImportError.malformedSource }
        )
        typedFacade.synchronizeDiscovery()
        XCTAssertTrue(typedFacade.beginSetup(from: try XCTUnwrap(typedStore.candidates.first)))

        await typedFacade.approveRead()
        XCTAssertEqual(typedStore.setupStatus, .importFailed)
        XCTAssertEqual(typedStore.setupImportError, .malformedSource)

        let unknownStore = ProviderUsageStore()
        let unknownFacade = makeFacade(
            store: unknownStore,
            context: { context },
            importerFactory: { _, _, _ in throw NSError(domain: "fixture", code: 2) }
        )
        unknownFacade.synchronizeDiscovery()
        XCTAssertTrue(unknownFacade.beginSetup(from: try XCTUnwrap(unknownStore.candidates.first)))

        await unknownFacade.approveRead()
        XCTAssertEqual(unknownStore.setupStatus, .importFailed)
        XCTAssertEqual(unknownStore.setupImportError, .connectionFailed)
    }

    func testUnavailableCredentialRepositoryStillLoadsMetadataAndReportsSanitizedConfigurationError() async throws {
        let account = Self.account()
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: UnavailableProviderUsageCredentialRepository(error: .invalidConfiguration),
            metadata: FacadeProviderUsageMetadataRepository(accounts: [account])
        )

        let accounts = try await repository.load()
        XCTAssertEqual(accounts, [account])
        do {
            _ = try await repository.readCredential(
                accountID: account.id,
                credentialRevision: account.credentialRevision
            )
            XCTFail("Expected unavailable credentials")
        } catch let error as ProviderUsageAccountRepositoryError {
            XCTAssertEqual(error, .credential(.invalidConfiguration))
        }
    }

    func testAppContextUsesActualAdapterDescriptorLifetimeProfileAndExactWorkspaceScope() throws {
        let accounts = FacadeProviderUsageAccountRepository()
        let model = AppViewModel(
            backendFactory: HomeTestBackend(),
            providerUsageAccountRepository: accounts,
            providerUsageClient: FacadeProviderUsageFetching()
        )
        let connection = Self.openCodeConnection(profile: .v2)
        let project = OpenCodeProject(
            id: "project", worktree: "/root", vcs: "git", name: "Synthetic",
            sandboxes: ["/workspace"], icon: nil, time: nil
        )
        model.isConnected = true
        model.backendConnection = connection
        model.projectStore.rememberProjectResolution(
            .init(
                project: project,
                scope: .init(projectID: project.id, directory: "/workspace", workspaceID: "workspace-id"),
                canonicalDirectory: "/root"
            ),
            connectionID: connection.id
        )
        model.currentProject = project
        model.selectedDirectory = "/workspace"

        let context = try XCTUnwrap(model.currentProviderUsageDiscoveryContext)
        XCTAssertEqual(context.backend, connection.descriptor)
        XCTAssertEqual(context.connectionLifetimeID, connection.id)
        XCTAssertEqual(context.apiProfile, .v2)
        XCTAssertEqual(context.scope, .init(projectID: "project", directory: "/workspace", workspaceID: "workspace-id"))

        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        model.projectStore.defaultServerDirectory = "/must-not-substitute"
        model.currentProject = global
        model.selectedDirectory = nil
        XCTAssertEqual(model.currentProviderUsageDiscoveryContext?.scope.directory, nil)
        XCTAssertTrue(model.providerUsageStore === model.providerUsageFacade.store)
    }

    func testProductionImporterCompositionFailsClosedForThirdPartyV2AndMissingTerminal() {
        let thirdPartyServices = HomeTestBackend()
        let thirdParty = BackendConnection(
            descriptor: .init(id: "injected", name: "Synthetic", version: "1"),
            capabilities: [.terminal],
            projects: thirdPartyServices,
            sessions: thirdPartyServices,
            chat: thirdPartyServices,
            models: thirdPartyServices,
            events: thirdPartyServices
        )
        assertImporterRejected(connection: thirdParty, profile: .legacy)

        let v2 = Self.openCodeConnection(profile: .v2)
        assertImporterRejected(connection: v2, profile: .v2)

        let legacy = Self.openCodeConnection(profile: .legacy)
        let noTerminal = BackendConnection(
            descriptor: legacy.descriptor,
            capabilities: legacy.capabilities.subtracting([.terminal]),
            projects: legacy.projects,
            sessions: legacy.sessions,
            chat: legacy.chat,
            models: legacy.models,
            events: legacy.events
        )
        assertImporterRejected(connection: noTerminal, profile: .legacy)
    }

    private func assertImporterRejected(connection: BackendConnection, profile: ProviderUsageAPIProfile) {
        let context = ProviderUsageDiscoveryContext(
            backend: connection.descriptor,
            connectionLifetimeID: connection.id,
            apiProfile: profile,
            scope: .init(projectID: "project", directory: "/workspace", workspaceID: "workspace")
        )
        XCTAssertThrowsError(try OpenCodeProviderUsageComposition.makeImporter(
            candidate: Self.setupCandidate(context: context),
            allowsInsecureHTTP: true,
            currentContext: { context },
            connection: connection
        ))
    }

    private func makeFacade(
        store: ProviderUsageStore,
        accounts: any ProviderUsageAccountRepository = FacadeProviderUsageAccountRepository(),
        providerClient: any ProviderUsageFetching = FacadeProviderUsageFetching(),
        context: @escaping ProviderUsageFacade.ContextProvider,
        legacy: @escaping ProviderUsageFacade.LegacyStateProvider = {
            .init(readiness: .ready, connectedProviders: [.init(id: "openrouter", label: "Synthetic", source: .api)])
        },
        importerFactory: @escaping ProviderUsageFacade.ImporterFactory = { _, _, _ in
            throw ProviderUsageCredentialImportError.unsupportedSource
        }
    ) -> ProviderUsageFacade {
        ProviderUsageFacade(
            store: store,
            accounts: accounts,
            providerClient: providerClient,
            contextProvider: context,
            legacyStateProvider: legacy,
            v2StateProvider: { .init(readiness: .ready, integrations: []) },
            importerFactory: importerFactory
        )
    }

    private static func openCodeConnection(profile: OpenCodeAPIProfile) -> BackendConnection {
        OpenCodeBackendFactory(
            client: OpenCodeAPIClient(config: .init(
                name: "Synthetic", baseURL: "https://example.invalid", username: "synthetic", password: "synthetic",
                apiPreference: profile == .legacy ? .legacy : .v2
            )),
            eventManager: OpenCodeEventManager()
        ).makeConnection(profile: profile, version: "synthetic", healthy: true)
    }

    private static func context(lifetime: UUID = uuid("11111111-1111-1111-1111-111111111111")) -> ProviderUsageDiscoveryContext {
        .init(
            backend: .init(id: "opencode:synthetic", name: "Synthetic", version: "1"),
            connectionLifetimeID: lifetime,
            apiProfile: .legacy,
            scope: .init(projectID: "project", directory: "/workspace", workspaceID: "workspace")
        )
    }

    private static func setupCandidate(context: ProviderUsageDiscoveryContext) -> ProviderUsageSetupCandidate {
        .init(
            id: uuid("33333333-3333-3333-3333-333333333333"),
            provider: .openRouter,
            discoveryContext: context,
            sourceIdentity: .legacyProvider(providerID: "openrouter"),
            sourceKind: .openCodeAuth,
            credentialKind: .apiKey,
            replacingAccountID: nil
        )
    }

    private static func account() -> ProviderUsageAccount {
        .init(
            id: uuid("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA"),
            provider: .openRouter,
            sourceConnectionID: "opencode:synthetic",
            apiProfile: .legacy,
            sourceKind: .openCodeAuth,
            credentialKind: .apiKey,
            credentialReference: uuid("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB"),
            credentialRevision: 1,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 1)
        )
    }

    private static func uuid(_ value: String) -> UUID { UUID(uuidString: value)! }

}

@MainActor
private final class ProviderUsageContextBox {
    var value: ProviderUsageDiscoveryContext?
    init(_ value: ProviderUsageDiscoveryContext?) { self.value = value }
}

@MainActor
private final class ProviderUsageImporterFactoryRecorder {
    var calls: [(ProviderUsageSetupCandidate, Bool)] = []
}

private actor ImmediateProviderUsageImporter: ProviderUsageCredentialImporter {
    let candidate: ProviderUsageSetupCandidate

    init(candidate: ProviderUsageSetupCandidate) {
        self.candidate = candidate
    }

    func importCredential(for candidate: ProviderUsageSetupCandidate) async throws -> ProviderUsageCredentialReview {
        ProviderUsageCredentialReview(
            candidate: candidate,
            secret: .init(value: "synthetic-secret"),
            providerAccountID: nil,
            credentialExpiresAt: nil
        )
    }
}

private actor DeferredFacadeProviderUsageImporter: ProviderUsageCredentialImporter {
    private var continuation: CheckedContinuation<ProviderUsageCredentialReview, Never>?
    private var calledContinuation: CheckedContinuation<Void, Never>?
    private var wasCalled = false

    func importCredential(for candidate: ProviderUsageSetupCandidate) async throws -> ProviderUsageCredentialReview {
        wasCalled = true
        calledContinuation?.resume()
        calledContinuation = nil
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilCalled() async {
        if wasCalled { return }
        await withCheckedContinuation { calledContinuation = $0 }
    }

    func resolve(candidate: ProviderUsageSetupCandidate) {
        continuation?.resume(returning: .init(
            candidate: candidate,
            secret: .init(value: "late-synthetic-secret"),
            providerAccountID: nil,
            credentialExpiresAt: nil
        ))
        continuation = nil
    }
}

private actor FacadeProviderUsageAccountRepository: ProviderUsageAccountRepository {
    private var storedAccounts: [ProviderUsageAccount]
    private(set) var removeCount = 0

    init(accounts: [ProviderUsageAccount] = []) { storedAccounts = accounts }

    func load() -> [ProviderUsageAccount] { storedAccounts }

    func readCredential(accountID: UUID, credentialRevision: Int) throws -> ProviderUsageTransientSecret {
        guard storedAccounts.contains(where: { $0.id == accountID && $0.credentialRevision == credentialRevision }) else {
            throw ProviderUsageAccountRepositoryError.accountMissing
        }
        return .init(value: "persisted-synthetic-secret")
    }

    func save(review: ProviderUsageCredentialReview) throws -> ProviderUsageAccountSaveResult {
        throw ProviderUsageAccountRepositoryError.credential(.unavailable)
    }

    func remove(accountID: UUID) throws {
        removeCount += 1
        storedAccounts.removeAll { $0.id == accountID }
    }
}

private actor FacadeProviderUsageFetching: ProviderUsageFetching {
    private(set) var callCount = 0
    private(set) var providers: [ProviderUsageProvider] = []

    func fetchUsage(
        provider: ProviderUsageProvider,
        credentialKind: ProviderUsageCredentialKind,
        secret: ProviderUsageTransientSecret,
        providerAccountID: String?,
        credentialExpiresAt: Date?
    ) async throws -> ProviderUsageSnapshot {
        callCount += 1
        providers.append(provider)
        return .init(
            provider: provider,
            accountLabel: nil,
            fetchedAt: Date(timeIntervalSince1970: 2),
            credentialExpiresAt: credentialExpiresAt,
            metrics: []
        )
    }
}

private actor FacadeProviderUsageMetadataRepository: ProviderUsageMetadataRepository {
    private var accounts: [ProviderUsageAccount]

    init(accounts: [ProviderUsageAccount]) { self.accounts = accounts }
    func load() -> [ProviderUsageAccount] { accounts }
    func save(_ accounts: [ProviderUsageAccount]) { self.accounts = accounts }
}
