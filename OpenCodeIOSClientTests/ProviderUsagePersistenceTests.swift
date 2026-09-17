import Security
import XCTest
@testable import OpenClient

@MainActor
final class ProviderUsagePersistenceTests: XCTestCase {
    func testSelectionDoesNotReadAndPreviewDoesNotSaveOrUse() async {
        let importer = ProviderUsageImporterFake(review: Self.review())
        let accounts = ProviderUsageAccountRepositoryFake()
        let provider = ProviderUsageFetchingFake()
        let store = ProviderUsageStore()
        let coordinator = ProviderUsageCoordinator(store: store, importer: importer, accounts: accounts, providerClient: provider)

        coordinator.select(Self.candidate())
        let initialImportCount = await importer.callCount
        let initialSaveCount = await accounts.saveCount
        let initialFetchCount = await provider.callCount
        XCTAssertEqual(initialImportCount, 0)
        XCTAssertEqual(initialSaveCount, 0)
        XCTAssertEqual(initialFetchCount, 0)

        await coordinator.approveRead()
        guard case .reviewing = store.setupPhase else { return XCTFail("Expected review") }
        let reviewedImportCount = await importer.callCount
        let reviewedSaveCount = await accounts.saveCount
        let reviewedFetchCount = await provider.callCount
        XCTAssertEqual(reviewedImportCount, 1)
        XCTAssertEqual(reviewedSaveCount, 0)
        XCTAssertEqual(reviewedFetchCount, 0)
    }

    func testCredentialImportFailurePreservesSanitizedTypedErrorAndCancelClearsIt() async {
        let store = ProviderUsageStore()
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: ProviderUsageThrowingImporter(error: .sourceMissing),
            accounts: ProviderUsageAccountRepositoryFake(),
            providerClient: ProviderUsageFetchingFake()
        )
        coordinator.select(Self.candidate())

        await coordinator.approveRead()

        XCTAssertEqual(store.setupStatus, .importFailed)
        XCTAssertEqual(store.setupImportError, .sourceMissing)
        coordinator.cancelSetup()
        XCTAssertNil(store.setupImportError)

        coordinator.select(Self.candidate())
        await coordinator.approveRead()
        store.clearCandidates()
        XCTAssertNil(store.setupImportError)

        coordinator.select(Self.candidate())
        await coordinator.approveRead()
        store.replaceAccounts([])
        XCTAssertNil(store.setupImportError)
    }

    func testUnknownCredentialImportFailureMapsToConnectionFailed() async {
        let store = ProviderUsageStore()
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: ProviderUsageThrowingImporter(error: nil),
            accounts: ProviderUsageAccountRepositoryFake(),
            providerClient: ProviderUsageFetchingFake()
        )
        coordinator.select(Self.candidate())

        await coordinator.approveRead()

        XCTAssertEqual(store.setupStatus, .importFailed)
        XCTAssertEqual(store.setupImportError, .connectionFailed)
    }

    func testCancellationDropsLateImportAndLateSaveResults() async {
        let importer = DeferredProviderUsageImporter()
        let accounts = ProviderUsageAccountRepositoryFake()
        let provider = ProviderUsageFetchingFake()
        let store = ProviderUsageStore()
        let coordinator = ProviderUsageCoordinator(store: store, importer: importer, accounts: accounts, providerClient: provider)
        coordinator.select(Self.candidate())

        let importTask = Task { await coordinator.approveRead() }
        await importer.waitUntilCalled()
        coordinator.cancelSetup()
        await importer.resolve(Self.review())
        await importTask.value
        XCTAssertEqual(store.setupPhase, .idle)

        let delayedAccounts = DeferredProviderUsageAccountRepository()
        let secondStore = ProviderUsageStore()
        let secondCoordinator = ProviderUsageCoordinator(
            store: secondStore,
            importer: ProviderUsageImporterFake(review: Self.review()),
            accounts: delayedAccounts,
            providerClient: provider
        )
        secondCoordinator.select(Self.candidate())
        await secondCoordinator.approveRead()
        let saveTask = Task { await secondCoordinator.approveSave() }
        await delayedAccounts.waitUntilSaved()
        secondCoordinator.cancelSetup()
        await delayedAccounts.resolve(Self.savedResult())
        await saveTask.value
        XCTAssertTrue(secondStore.accounts.isEmpty)
        let fetchCount = await provider.callCount
        XCTAssertEqual(fetchCount, 0)
    }

    func testSaveFailureIsNotConfigured() async {
        let accounts = ProviderUsageAccountRepositoryFake(saveError: .credential(.writeFailed))
        let store = ProviderUsageStore()
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: ProviderUsageImporterFake(review: Self.review()),
            accounts: accounts,
            providerClient: ProviderUsageFetchingFake()
        )
        coordinator.select(Self.candidate())
        await coordinator.approveRead()
        await coordinator.approveSave()

        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertEqual(store.setupStatus, .saveFailed)
    }

    func testSuccessfulSaveFetchesUsageAndFetchFailureRemainsSaved() async {
        let events = ProviderUsageEventRecorder()
        let account = Self.account()
        let accounts = ProviderUsageAccountRepositoryFake(result: .init(account: account, supersededCredentialCleanupPending: false), events: events)
        let provider = ProviderUsageFetchingFake(snapshot: Self.snapshot(), events: events)
        let store = ProviderUsageStore()
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: ProviderUsageImporterFake(review: Self.review()),
            accounts: accounts,
            providerClient: provider
        )
        coordinator.select(Self.candidate())
        await coordinator.approveRead()
        await coordinator.approveSave()

        XCTAssertEqual(events.values, ["save", "fetch"])
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.statuses[account.id], .ready)
        XCTAssertEqual(store.snapshots[account.id], Self.snapshot())

        let failedAccount = Self.account(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!)
        let failedStore = ProviderUsageStore()
        let failedCoordinator = ProviderUsageCoordinator(
            store: failedStore,
            importer: ProviderUsageImporterFake(review: Self.review()),
            accounts: ProviderUsageAccountRepositoryFake(result: .init(account: failedAccount, supersededCredentialCleanupPending: false)),
            providerClient: ProviderUsageFetchingFake(error: .network)
        )
        failedCoordinator.select(Self.candidate())
        await failedCoordinator.approveRead()
        await failedCoordinator.approveSave()
        XCTAssertEqual(failedStore.accounts, [failedAccount])
        XCTAssertEqual(failedStore.statuses[failedAccount.id], .usageFailed(.network))
    }

    func testRelaunchRefreshLoadsCommittedCredentialAndRoutesPersistedMetadata() async throws {
        let account = Self.account()
        let credentials = ProviderUsageCredentialMemoryFake(values: [account.credentialReference: .init(value: "persisted-secret")])
        let metadata = ProviderUsageMetadataFake(accounts: [account])
        let repository = TransactionalProviderUsageAccountRepository(credentials: credentials, metadata: metadata)
        let provider = ProviderUsageFetchingFake()
        let store = ProviderUsageStore()
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: ProviderUsageImporterFake(review: Self.review()),
            accounts: repository,
            providerClient: provider
        )

        await coordinator.load()
        await coordinator.refresh(accountID: account.id)

        let request = await provider.lastRequest
        XCTAssertEqual(request?.provider, account.provider)
        XCTAssertEqual(request?.credentialKind, account.credentialKind)
        XCTAssertEqual(request?.providerAccountID, account.providerAccountID)
        XCTAssertEqual(request?.credentialExpiresAt, account.credentialExpiresAt)
        XCTAssertEqual(request?.secret, "persisted-secret")
        XCTAssertEqual(store.statuses[account.id], .ready)
    }

    func testConcurrentRefreshesForOneAccountDeduplicate() async {
        let account = Self.account()
        let accounts = ProviderUsageAccountRepositoryFake(initialAccounts: [account])
        let provider = ProviderUsageFetchingFake()
        let store = ProviderUsageStore()
        store.replaceAccounts([account])
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: ProviderUsageImporterFake(review: Self.review()),
            accounts: accounts,
            providerClient: provider
        )

        async let first: Void = coordinator.refresh(accountID: account.id)
        async let second: Void = coordinator.refresh(accountID: account.id)
        _ = await (first, second)

        let callCount = await provider.callCount
        XCTAssertEqual(callCount, 1)
        XCTAssertEqual(store.statuses[account.id], .ready)
    }

    func testRejectedCodexAccessRefreshesPersistsThenRetriesOnce() async throws {
        let old = Self.codexAccount()
        let newReference = UUID(uuidString: "EFEFEFEF-EFEF-EFEF-EFEF-EFEFEFEFEFEF")!
        let credentials = ProviderUsageCredentialMemoryFake(values: [
            old.credentialReference: .init(value: "old-access"),
        ])
        let metadata = ProviderUsageMetadataFake(accounts: [old])
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: credentials,
            metadata: metadata,
            now: { Date(timeIntervalSince1970: 200) },
            makeUUID: { newReference }
        )
        let provider = RefreshingProviderUsageFake()
        let source = RenewingProviderUsageImporterFake()
        let store = ProviderUsageStore()
        store.replaceAccounts([old])
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: source,
            renewalCandidate: Self.renewalCandidate(),
            accounts: repository,
            providerClient: provider
        )

        await coordinator.refresh(accountID: old.id)

        let fetchCount = await provider.fetchCount
        let refreshCount = await source.renewalCount
        XCTAssertEqual(fetchCount, 2)
        XCTAssertEqual(refreshCount, 1)
        let savedAccounts = await metadata.load()
        let committed = try XCTUnwrap(savedAccounts.first)
        XCTAssertEqual(committed.credentialRevision, 2)
        XCTAssertEqual(committed.providerAccountID, old.providerAccountID)
        XCTAssertEqual(store.accounts, [committed])
        XCTAssertEqual(store.statuses[old.id], .ready)
        XCTAssertEqual(
            try credentials.read(reference: newReference),
            .init(value: "new-access")
        )
        XCTAssertThrowsError(try credentials.read(reference: old.credentialReference))
    }

    func testRefreshFailureDoesNotRetryAndOpenRouterNeverUsesOAuthRefresh() async {
        let codex = Self.codexAccount()
        let codexRepository = ProviderUsageAccountRepositoryFake(
            initialAccounts: [codex],
            credentialSecret: .init(value: "old-access")
        )
        let failedProvider = RefreshingProviderUsageFake()
        let failedSource = RenewingProviderUsageImporterFake(error: .sourceRefreshRejected)
        let codexStore = ProviderUsageStore()
        codexStore.replaceAccounts([codex])
        await ProviderUsageCoordinator(
            store: codexStore,
            importer: failedSource,
            renewalCandidate: Self.renewalCandidate(),
            accounts: codexRepository,
            providerClient: failedProvider
        ).refresh(accountID: codex.id)
        let failedFetchCount = await failedProvider.fetchCount
        let failedRefreshCount = await failedSource.renewalCount
        XCTAssertEqual(failedFetchCount, 1)
        XCTAssertEqual(failedRefreshCount, 1)
        XCTAssertEqual(codexStore.statuses[codex.id], .usageFailed(.unauthorized))

        let router = Self.account()
        let routerRepository = ProviderUsageAccountRepositoryFake(
            initialAccounts: [router],
            credentialSecret: .init(value: "router-key")
        )
        let routerProvider = RefreshingProviderUsageFake()
        let routerSource = RenewingProviderUsageImporterFake()
        let routerStore = ProviderUsageStore()
        routerStore.replaceAccounts([router])
        await ProviderUsageCoordinator(
            store: routerStore,
            importer: routerSource,
            renewalCandidate: Self.renewalCandidate(),
            accounts: routerRepository,
            providerClient: routerProvider
        ).refresh(accountID: router.id)
        let routerFetchCount = await routerProvider.fetchCount
        let routerRefreshCount = await routerSource.renewalCount
        XCTAssertEqual(routerFetchCount, 1)
        XCTAssertEqual(routerRefreshCount, 0)
        XCTAssertEqual(routerStore.statuses[router.id], .usageFailed(.unauthorized))
    }

    func testRenewalAccountMismatchDoesNotRotateCredential() async throws {
        let account = Self.codexAccount()
        let credentials = ProviderUsageCredentialMemoryFake(values: [
            account.credentialReference: .init(value: "old-access"),
        ])
        let metadata = ProviderUsageMetadataFake(accounts: [account])
        let store = ProviderUsageStore()
        store.replaceAccounts([account])

        await ProviderUsageCoordinator(
            store: store,
            importer: RenewingProviderUsageImporterFake(returnedAccountID: "different-account"),
            renewalCandidate: Self.renewalCandidate(),
            accounts: TransactionalProviderUsageAccountRepository(
                credentials: credentials,
                metadata: metadata
            ),
            providerClient: RefreshingProviderUsageFake()
        ).refresh(accountID: account.id)

        XCTAssertEqual(store.statuses[account.id], .usageFailed(.accountMismatch))
        let persisted = await metadata.load()
        XCTAssertEqual(persisted, [account])
        XCTAssertEqual(try credentials.read(reference: account.credentialReference).value, "old-access")
    }

    func testCancellationAndRefreshInvalidationAfterTokenIssuanceStillCommitAndReconcile() async {
        let old = Self.codexAccount()
        let committed = Self.replacingCredential(
            old,
            reference: UUID(uuidString: "ABABABAB-ABAB-ABAB-ABAB-ABABABABABAB")!,
            revision: 2,
            providerAccountID: old.providerAccountID
        )
        let repository = DeferredRotationAccountRepository(original: old, committed: committed)
        let provider = RefreshingProviderUsageFake()
        let source = RenewingProviderUsageImporterFake()
        let store = ProviderUsageStore()
        store.replaceAccounts([old])
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: source,
            renewalCandidate: Self.renewalCandidate(),
            accounts: repository,
            providerClient: provider
        )

        let task = Task { await coordinator.refresh(accountID: old.id) }
        await repository.waitUntilRotationStarted()
        task.cancel()
        store.invalidateRefreshes()
        await repository.finishRotation()
        await task.value

        XCTAssertEqual(store.accounts, [committed])
        XCTAssertEqual(store.statuses[old.id], .savedNotChecked)
        let rotationCount = await repository.rotationCount
        let fetchCount = await provider.fetchCount
        XCTAssertEqual(rotationCount, 1)
        XCTAssertEqual(fetchCount, 1)
    }

    func testCancellationWhileRenewalResultIsPendingStillPersistsReturnedCredential() async throws {
        let old = Self.codexAccount()
        let newReference = UUID(uuidString: "ACACACAC-ACAC-ACAC-ACAC-ACACACACACAC")!
        let credentials = ProviderUsageCredentialMemoryFake(values: [
            old.credentialReference: .init(value: "old-access"),
        ])
        let metadata = ProviderUsageMetadataFake(accounts: [old])
        let source = DeferredRenewingProviderUsageImporterFake()
        let store = ProviderUsageStore()
        store.replaceAccounts([old])
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: source,
            renewalCandidate: Self.renewalCandidate(),
            accounts: TransactionalProviderUsageAccountRepository(
                credentials: credentials,
                metadata: metadata,
                makeUUID: { newReference }
            ),
            providerClient: RefreshingProviderUsageFake()
        )

        let task = Task { await coordinator.refresh(accountID: old.id) }
        await source.waitUntilRenewalRequested()
        task.cancel()
        await source.resolve()
        await task.value

        let persistedAccounts = await metadata.load()
        let persisted = try XCTUnwrap(persistedAccounts.first)
        XCTAssertEqual(persisted.credentialRevision, 2)
        XCTAssertEqual(persisted.providerAccountID, old.providerAccountID)
        XCTAssertEqual(try credentials.read(reference: newReference).value, "new-access")
        XCTAssertThrowsError(try credentials.read(reference: old.credentialReference))
    }

    func testRepositorySerializesRotateAndRemoveAcrossSuspendedMetadataSave() async throws {
        let first = Self.codexAccount()
        let second = Self.account(
            id: UUID(uuidString: "12121212-1212-1212-1212-121212121212")!,
            credentialReference: UUID(uuidString: "34343434-3434-3434-3434-343434343434")!,
            sourceConnectionID: "server-two"
        )
        let newReference = UUID(uuidString: "56565656-5656-5656-5656-565656565656")!
        let credentials = ProviderUsageCredentialMemoryFake(values: [
            first.credentialReference: .init(value: "old-access"),
            second.credentialReference: .init(value: "router-key"),
        ])
        let metadata = SuspendingProviderUsageMetadataFake(accounts: [first, second])
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: credentials,
            metadata: metadata,
            makeUUID: { newReference }
        )

        let rotate = Task {
            try await repository.rotateCredential(
                accountID: first.id,
                credentialRevision: first.credentialRevision,
                secret: .init(value: "new-access"),
                expiresAt: Date(timeIntervalSince1970: 500),
                providerAccountID: "rotated-provider-account"
            )
        }
        await metadata.waitUntilSaveStarted()
        let remove = Task { try await repository.remove(accountID: second.id) }
        await Task.yield()
        let blockedLoadCount = await metadata.loadCount
        XCTAssertEqual(blockedLoadCount, 1)
        await metadata.finishSave()
        let rotatedResult = try await rotate.value
        let rotated = rotatedResult.account
        try await remove.value

        let currentAccounts = await metadata.currentAccounts()
        XCTAssertEqual(currentAccounts, [rotated])
        XCTAssertEqual(rotated.providerAccountID, first.providerAccountID)
        XCTAssertEqual(try credentials.read(reference: newReference).value, "new-access")
        XCTAssertThrowsError(try credentials.read(reference: first.credentialReference))
        XCTAssertThrowsError(try credentials.read(reference: second.credentialReference))
    }

    func testCredentialReadWaitsUntilRemovalMetadataCommit() async throws {
        let account = Self.account()
        let credentials = ProviderUsageCredentialMemoryFake(values: [
            account.credentialReference: .init(value: "router-key"),
        ])
        let metadata = SuspendingProviderUsageMetadataFake(accounts: [account])
        let repository = TransactionalProviderUsageAccountRepository(credentials: credentials, metadata: metadata)

        let remove = Task { try await repository.remove(accountID: account.id) }
        await metadata.waitUntilSaveStarted()
        XCTAssertThrowsError(try credentials.read(reference: account.credentialReference))
        let read = Task {
            try await repository.readCredential(
                accountID: account.id,
                credentialRevision: account.credentialRevision
            )
        }
        await Task.yield()
        await metadata.finishSave()
        try await remove.value
        do {
            _ = try await read.value
            XCTFail("Expected removed account read to fail")
        } catch let error as ProviderUsageAccountRepositoryError {
            XCTAssertEqual(error, .credentialRevisionMismatch)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testStaleRevisionIsRejectedBeforeReadingCredential() async throws {
        let account = Self.account()
        let credentials = ProviderUsageCredentialMemoryFake(values: [account.credentialReference: .init(value: "persisted-secret")])
        let metadata = ProviderUsageMetadataFake(accounts: [Self.accountWithRevision(account, revision: 2)])
        let repository = TransactionalProviderUsageAccountRepository(credentials: credentials, metadata: metadata)

        do {
            _ = try await repository.readCredential(accountID: account.id, credentialRevision: account.credentialRevision)
            XCTFail("Expected stale revision")
        } catch let error as ProviderUsageAccountRepositoryError {
            XCTAssertEqual(error, .credentialRevisionMismatch)
        }
        XCTAssertEqual(credentials.readReferences, [])
    }

    func testRefreshFailurePreservesLastSuccessfulSnapshotAndCancellationAllowsRetry() async {
        let account = Self.account()
        let store = ProviderUsageStore()
        store.replaceAccounts([account])
        let first = store.beginRefresh(accountID: account.id)
        XCTAssertNotNil(first)
        _ = store.applyRefresh(Self.snapshot(), handle: first!)

        let failed = store.beginRefresh(accountID: account.id)
        XCTAssertNotNil(failed)
        XCTAssertEqual(store.statuses[account.id], .refreshing)
        XCTAssertTrue(store.applyRefreshFailure(.network, handle: failed!))
        XCTAssertEqual(store.snapshots[account.id], Self.snapshot())
        XCTAssertEqual(store.statuses[account.id], .usageFailed(.network))

        let cancelled = store.beginRefresh(accountID: account.id)
        XCTAssertNotNil(cancelled)
        store.cancelRefresh(cancelled!)
        XCTAssertNotNil(store.beginRefresh(accountID: account.id))
    }

    func testAccountReplacementDropsLateRefreshButCandidateReplacementDoesNot() {
        let account = Self.account()
        let replacement = Self.accountWithRevision(account, revision: 2)
        let store = ProviderUsageStore()
        store.replaceAccounts([account])
        let oldRefresh = store.beginRefresh(accountID: account.id)!
        store.replaceAccounts([replacement])
        XCTAssertFalse(store.applyRefresh(Self.snapshot(), handle: oldRefresh))

        let validRefresh = store.beginRefresh(accountID: replacement.id)!
        let context = Self.candidate().discoveryContext
        store.replaceCandidates(with: .init(readiness: .ready, context: context, candidates: []))
        XCTAssertTrue(store.applyRefresh(Self.snapshot(), handle: validRefresh))
    }

    func testReplacementDuringCredentialReadDoesNotSendStaleCredential() async {
        let account = Self.account()
        let replacement = Self.accountWithRevision(account, revision: 2)
        let accounts = DeferredProviderUsageCredentialReadRepository(account: account)
        let provider = ProviderUsageFetchingFake()
        let store = ProviderUsageStore()
        store.replaceAccounts([account])
        let coordinator = ProviderUsageCoordinator(
            store: store,
            importer: nil,
            accounts: accounts,
            providerClient: provider
        )

        let refresh = Task { await coordinator.refresh(accountID: account.id) }
        await accounts.waitUntilRead()
        store.replaceAccounts([replacement])
        await accounts.resolve(.init(value: "stale-synthetic-secret"))
        await refresh.value

        let providerCallCount = await provider.callCount
        XCTAssertEqual(providerCallCount, 0)
        XCTAssertEqual(store.accounts, [replacement])
        XCTAssertEqual(store.statuses[replacement.id], .savedNotChecked)
    }

    func testMetadataFailurePreservesOldAccountAndCredentialAndCleansNewItem() async throws {
        let old = Self.account()
        let newReference = UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!
        let credentials = ProviderUsageCredentialMemoryFake(values: [old.credentialReference: .init(value: "old-secret")])
        let metadata = ProviderUsageMetadataFake(accounts: [old], saveError: .writeFailed)
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: credentials,
            metadata: metadata,
            now: { Date(timeIntervalSince1970: 200) },
            makeUUID: { newReference }
        )

        do {
            _ = try await repository.save(review: Self.review(replacing: old.id))
            XCTFail("Expected metadata failure")
        } catch let error as ProviderUsageAccountRepositoryError {
            XCTAssertEqual(error, .metadata(.writeFailed))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        let preservedAccounts = await metadata.load()
        XCTAssertEqual(preservedAccounts, [old])
        XCTAssertEqual(try credentials.read(reference: old.credentialReference).value, "old-secret")
        XCTAssertThrowsError(try credentials.read(reference: newReference))
    }

    func testMetadataFailureSurfacesCredentialCleanupFailure() async throws {
        let old = Self.account()
        let newReference = UUID(uuidString: "BEBEBEBE-BEBE-BEBE-BEBE-BEBEBEBEBEBE")!
        let credentials = ProviderUsageCredentialMemoryFake(
            values: [old.credentialReference: .init(value: "old-secret")],
            deleteError: .deleteFailed
        )
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: credentials,
            metadata: ProviderUsageMetadataFake(accounts: [old], saveError: .writeFailed),
            makeUUID: { newReference }
        )

        do {
            _ = try await repository.save(review: Self.review(replacing: old.id))
            XCTFail("Expected cleanup failure")
        } catch let error as ProviderUsageAccountRepositoryError {
            XCTAssertEqual(
                error,
                .credentialCleanupFailed(metadata: .writeFailed, credential: .deleteFailed)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(try credentials.read(reference: old.credentialReference).value, "old-secret")
        XCTAssertEqual(try credentials.read(reference: newReference).value, "fixture-secret")
    }

    func testReplacementPublishesNewBeforeDeletingOldAndWriteFailureKeepsOld() async throws {
        let old = Self.account()
        let newReference = UUID(uuidString: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC")!
        let events = ProviderUsageEventRecorder()
        let credentials = ProviderUsageCredentialMemoryFake(values: [old.credentialReference: .init(value: "old")], events: events)
        let metadata = ProviderUsageMetadataFake(accounts: [old], events: events)
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: credentials,
            metadata: metadata,
            now: { Date(timeIntervalSince1970: 200) },
            makeUUID: { newReference }
        )
        let result = try await repository.save(review: Self.review(replacing: old.id))

        XCTAssertEqual(result.account.credentialRevision, 2)
        XCTAssertEqual(result.account.credentialReference, newReference)
        XCTAssertNil(result.account.sourceRenewalApprovedAt)
        XCTAssertEqual(events.values, ["write", "metadata", "delete:\(old.credentialReference.uuidString)"])
        XCTAssertThrowsError(try credentials.read(reference: old.credentialReference))
        XCTAssertEqual(try credentials.read(reference: newReference).value, "fixture-secret")

        let failingCredentials = ProviderUsageCredentialMemoryFake(
            values: [old.credentialReference: .init(value: "old")],
            writeError: .writeFailed
        )
        let untouchedMetadata = ProviderUsageMetadataFake(accounts: [old])
        let failingRepository = TransactionalProviderUsageAccountRepository(
            credentials: failingCredentials,
            metadata: untouchedMetadata,
            makeUUID: { newReference }
        )
        await XCTAssertThrowsErrorAsync { try await failingRepository.save(review: Self.review(replacing: old.id)) }
        let untouchedAccounts = await untouchedMetadata.load()
        XCTAssertEqual(untouchedAccounts, [old])
        XCTAssertEqual(try failingCredentials.read(reference: old.credentialReference).value, "old")
    }

    func testExplicitCodexSaveRecordsRenewalApprovalAndLegacyMetadataDefaultsToNil() async throws {
        let date = Date(timeIntervalSince1970: 200)
        let reference = UUID(uuidString: "ABCDABCD-ABCD-ABCD-ABCD-ABCDABCDABCD")!
        let candidate = Self.renewalCandidate()
        let review = ProviderUsageCredentialReview(
            candidate: .init(
                id: candidate.id,
                provider: candidate.provider,
                discoveryContext: candidate.discoveryContext,
                sourceIdentity: candidate.sourceIdentity,
                sourceKind: candidate.sourceKind,
                credentialKind: candidate.credentialKind,
                replacingAccountID: nil
            ),
            secret: .init(value: "access-only"),
            providerAccountID: "provider-account",
            credentialExpiresAt: Date(timeIntervalSince1970: 500)
        )
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: ProviderUsageCredentialMemoryFake(),
            metadata: ProviderUsageMetadataFake(),
            now: { date },
            makeUUID: { reference }
        )

        let saved = try await repository.save(review: review).account
        XCTAssertEqual(saved.sourceRenewalApprovedAt, date)

        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(saved)) as? [String: Any]
        )
        object.removeValue(forKey: "sourceRenewalApprovedAt")
        let legacy = try JSONDecoder().decode(
            ProviderUsageAccount.self,
            from: JSONSerialization.data(withJSONObject: object)
        )
        XCTAssertNil(legacy.sourceRenewalApprovedAt)
    }

    func testExactRemovalAndDeleteFailureDoesNotRemoveMetadata() async throws {
        let first = Self.account()
        let second = Self.account(
            id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
            credentialReference: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            sourceConnectionID: "server-two"
        )
        let credentials = ProviderUsageCredentialMemoryFake(values: [
            first.credentialReference: .init(value: "first"),
            second.credentialReference: .init(value: "second"),
        ])
        let metadata = ProviderUsageMetadataFake(accounts: [first, second])
        let repository = TransactionalProviderUsageAccountRepository(credentials: credentials, metadata: metadata)
        try await repository.remove(accountID: first.id)
        let remainingAccounts = await metadata.load()
        XCTAssertEqual(remainingAccounts, [second])
        XCTAssertEqual(try credentials.read(reference: second.credentialReference).value, "second")

        let blockedCredentials = ProviderUsageCredentialMemoryFake(
            values: [second.credentialReference: .init(value: "second")],
            deleteError: .deleteFailed
        )
        let blockedMetadata = ProviderUsageMetadataFake(accounts: [second])
        let blockedRepository = TransactionalProviderUsageAccountRepository(credentials: blockedCredentials, metadata: blockedMetadata)
        await XCTAssertThrowsErrorAsync { try await blockedRepository.remove(accountID: second.id) }
        let blockedAccounts = await blockedMetadata.load()
        XCTAssertEqual(blockedAccounts, [second])
    }

    func testRemovalMetadataFailureRestoresCredential() async throws {
        let account = Self.account()
        let credentials = ProviderUsageCredentialMemoryFake(values: [
            account.credentialReference: .init(value: "preserved-secret"),
        ])
        let metadata = ProviderUsageMetadataFake(accounts: [account], saveError: .writeFailed)
        let repository = TransactionalProviderUsageAccountRepository(credentials: credentials, metadata: metadata)

        await XCTAssertThrowsErrorAsync { try await repository.remove(accountID: account.id) }

        let retainedAccounts = await metadata.load()
        XCTAssertEqual(retainedAccounts, [account])
        XCTAssertEqual(try credentials.read(reference: account.credentialReference).value, "preserved-secret")
    }

    func testRemovalReportsCredentialRestoreFailure() async throws {
        let account = Self.account()
        let credentials = ProviderUsageCredentialMemoryFake(
            values: [account.credentialReference: .init(value: "preserved-secret")],
            writeError: .writeFailed
        )
        let metadata = ProviderUsageMetadataFake(accounts: [account], saveError: .writeFailed)
        let repository = TransactionalProviderUsageAccountRepository(credentials: credentials, metadata: metadata)

        do {
            try await repository.remove(accountID: account.id)
            XCTFail("Expected rollback failure")
        } catch let error as ProviderUsageAccountRepositoryError {
            XCTAssertEqual(
                error,
                .removalRollbackFailed(metadata: .writeFailed, credential: .writeFailed)
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testSeparateServersRemainSeparateAccountsAndSecretsAreRedacted() async throws {
        let credentials = ProviderUsageCredentialMemoryFake()
        let metadata = ProviderUsageMetadataFake()
        let ids = ProviderUsageUUIDSequence([
            UUID(uuidString: "10101010-1010-1010-1010-101010101010")!,
            UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
            UUID(uuidString: "20202020-2020-2020-2020-202020202020")!,
            UUID(uuidString: "22222222-2222-2222-2222-222222222222")!,
        ])
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: credentials,
            metadata: metadata,
            makeUUID: { ids.next() }
        )
        let first = try await repository.save(review: Self.review(sourceConnectionID: "server-one")).account
        let second = try await repository.save(review: Self.review(sourceConnectionID: "server-two")).account
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNotEqual(first.credentialReference, second.credentialReference)
        let storedAccounts = await metadata.load()
        XCTAssertEqual(Set(storedAccounts.map(\.sourceConnectionID)), ["server-one", "server-two"])

        let secret = ProviderUsageTransientSecret(value: "fixture-secret")
        XCTAssertFalse(String(describing: secret).contains("fixture-secret"))
        XCTAssertFalse(String(reflecting: Self.review()).contains("fixture-secret"))
        XCTAssertEqual(secret.maskedPreview, "****cret")
    }

    func testKeychainQueriesUsePrivateGroupServiceAccessibilityAndNoSynchronization() throws {
        let security = ProviderUsageSecurityFake()
        let repository = KeychainProviderUsageCredentialRepository(
            accessGroup: "TEAM.com.ntoporcov.openclient",
            security: security
        )
        let reference = UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
        try repository.write(.init(value: "fixture-secret"), reference: reference)
        try repository.delete(reference: reference)

        let add = try XCTUnwrap(security.addQueries.first)
        XCTAssertEqual(add[kSecClass as String] as? String, kSecClassGenericPassword as String)
        XCTAssertEqual(add[kSecAttrService as String] as? String, KeychainProviderUsageCredentialRepository.service)
        XCTAssertEqual(add[kSecAttrAccount as String] as? String, reference.uuidString)
        XCTAssertEqual(add[kSecAttrAccessGroup as String] as? String, "TEAM.com.ntoporcov.openclient")
        XCTAssertEqual(add[kSecAttrAccessible as String] as? String, kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        XCTAssertEqual(add[kSecAttrSynchronizable as String] as? Bool, false)

        let read = try XCTUnwrap(security.readQueries.first)
        XCTAssertEqual(read[kSecAttrAccessGroup as String] as? String, "TEAM.com.ntoporcov.openclient")
        XCTAssertEqual(read[kSecAttrSynchronizable as String] as? Bool, false)
        let delete = try XCTUnwrap(security.deleteQueries.last)
        XCTAssertEqual(delete[kSecAttrAccessGroup as String] as? String, "TEAM.com.ntoporcov.openclient")
        XCTAssertEqual(delete[kSecAttrService as String] as? String, KeychainProviderUsageCredentialRepository.service)
        XCTAssertEqual(delete[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testKeychainStoresOnlyAccessToken() throws {
        let security = ProviderUsageSecurityFake()
        let repository = KeychainProviderUsageCredentialRepository(accessGroup: "TEAM.private", security: security)
        let reference = UUID()
        let credential = ProviderUsageTransientSecret(value: "new-access")

        try repository.write(credential, reference: reference)

        XCTAssertEqual(try repository.read(reference: reference), credential)
        XCTAssertEqual(security.storedValue, Data("new-access".utf8))
    }

    func testCredentialRotationCommitsNewBundleBeforeDeletingOld() async throws {
        let old = Self.account()
        let newReference = UUID(uuidString: "EEEEEEEE-EEEE-EEEE-EEEE-EEEEEEEEEEEE")!
        let events = ProviderUsageEventRecorder()
        let credentials = ProviderUsageCredentialMemoryFake(
            values: [old.credentialReference: .init(value: "old-access")],
            events: events
        )
        let metadata = ProviderUsageMetadataFake(accounts: [old], events: events)
        let repository = TransactionalProviderUsageAccountRepository(
            credentials: credentials,
            metadata: metadata,
            now: { Date(timeIntervalSince1970: 250) },
            makeUUID: { newReference }
        )
        let rotated = ProviderUsageTransientSecret(value: "new-access")

        let result = try await repository.rotateCredential(
            accountID: old.id,
            credentialRevision: old.credentialRevision,
            secret: rotated,
            expiresAt: Date(timeIntervalSince1970: 500)
        )

        XCTAssertEqual(result.account.credentialRevision, 2)
        XCTAssertEqual(result.account.credentialExpiresAt, Date(timeIntervalSince1970: 500))
        XCTAssertEqual(result.account.providerAccountID, old.providerAccountID)
        XCTAssertEqual(try credentials.read(reference: newReference), rotated)
        XCTAssertThrowsError(try credentials.read(reference: old.credentialReference))
        XCTAssertEqual(events.values, ["write", "metadata", "delete:\(old.credentialReference.uuidString)"])
    }

    func testSignedHostStoresProviderCredentialOnlyInPrivateAccessGroup() throws {
        let bundle = Bundle.main
        let privateGroup = try XCTUnwrap(
            bundle.object(forInfoDictionaryKey: KeychainProviderUsageCredentialRepository.privateAccessGroupInfoKey) as? String
        )
        let sharedGroup = try XCTUnwrap(bundle.object(forInfoDictionaryKey: "OpenCodeSharedKeychainAccessGroup") as? String)
        XCTAssertNotEqual(privateGroup, sharedGroup)
        XCTAssertFalse(privateGroup.contains("$("))

        let repository = try KeychainProviderUsageCredentialRepository(bundle: bundle)
        let reference = UUID()
        defer { try? repository.delete(reference: reference) }
        try repository.write(.init(value: "synthetic-hosted-test-secret"), reference: reference)
        XCTAssertEqual(try repository.read(reference: reference).value, "synthetic-hosted-test-secret")

        let sharedQuery: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: KeychainProviderUsageCredentialRepository.service,
            kSecAttrAccount as String: reference.uuidString,
            kSecAttrAccessGroup as String: sharedGroup,
            kSecAttrSynchronizable as String: kCFBooleanFalse as Any,
            kSecReturnData as String: kCFBooleanTrue as Any,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var sharedResult: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(sharedQuery as CFDictionary, &sharedResult), errSecItemNotFound)
        XCTAssertNil(sharedResult)
    }

    nonisolated private static func candidate(
        sourceConnectionID: String = "server-one",
        replacing: UUID? = nil
    ) -> ProviderUsageSetupCandidate {
        let context = ProviderUsageDiscoveryContext(
            backend: .init(id: sourceConnectionID, name: "Synthetic Backend", version: "1"),
            connectionLifetimeID: UUID(uuidString: "88888888-8888-8888-8888-888888888888")!,
            apiProfile: .legacy,
            scope: .init(projectID: "project-one", directory: "/workspace/one", workspaceID: "workspace-one")
        )
        return .init(
            id: UUID(uuidString: "99999999-9999-9999-9999-999999999999")!,
            provider: .openRouter,
            discoveryContext: context,
            sourceIdentity: .legacyProvider(providerID: "openrouter"),
            sourceKind: .openCodeAuth,
            credentialKind: .apiKey,
            replacingAccountID: replacing
        )
    }

    nonisolated private static func review(
        sourceConnectionID: String = "server-one",
        replacing: UUID? = nil
    ) -> ProviderUsageCredentialReview {
        .init(
            candidate: candidate(sourceConnectionID: sourceConnectionID, replacing: replacing),
            secret: .init(value: "fixture-secret"),
            providerAccountID: "provider-account",
            credentialExpiresAt: Date(timeIntervalSince1970: 500)
        )
    }

    nonisolated fileprivate static func account(
        id: UUID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!,
        credentialReference: UUID = UUID(uuidString: "99999999-AAAA-BBBB-CCCC-DDDDDDDDDDDD")!,
        sourceConnectionID: String = "server-one"
    ) -> ProviderUsageAccount {
        .init(
            id: id,
            provider: .openRouter,
            sourceConnectionID: sourceConnectionID,
            apiProfile: .legacy,
            sourceKind: .openCodeAuth,
            sourceScope: ProviderUsageSourceScope(.init(projectID: "project-one", directory: "/workspace/one", workspaceID: "workspace-one")),
            credentialKind: .apiKey,
            providerAccountID: "provider-account",
            credentialReference: credentialReference,
            credentialRevision: 1,
            createdAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    }

    nonisolated private static func codexAccount() -> ProviderUsageAccount {
        .init(
            id: UUID(uuidString: "CDCDCDCD-CDCD-CDCD-CDCD-CDCDCDCDCDCD")!,
            provider: .codex,
            sourceConnectionID: "server-one",
            apiProfile: .legacy,
            sourceKind: .openCodeAuth,
            sourceScope: ProviderUsageSourceScope(.init(projectID: "project-one", directory: "/workspace/one", workspaceID: "workspace-one")),
            credentialKind: .oauthAccessToken,
            providerAccountID: "provider-account",
            credentialReference: UUID(uuidString: "DCDCDCDC-DCDC-DCDC-DCDC-DCDCDCDCDCDC")!,
            credentialRevision: 1,
            credentialExpiresAt: Date(timeIntervalSince1970: 100),
            createdAt: Date(timeIntervalSince1970: 50),
            updatedAt: Date(timeIntervalSince1970: 50)
        )
    }

    nonisolated private static func accountWithRevision(_ account: ProviderUsageAccount, revision: Int) -> ProviderUsageAccount {
        .init(
            id: account.id,
            provider: account.provider,
            sourceConnectionID: account.sourceConnectionID,
            apiProfile: account.apiProfile,
            sourceKind: account.sourceKind,
            sourceScope: account.sourceScope,
            credentialKind: account.credentialKind,
            providerAccountID: account.providerAccountID,
            credentialReference: account.credentialReference,
            credentialRevision: revision,
            credentialExpiresAt: account.credentialExpiresAt,
            createdAt: account.createdAt,
            updatedAt: account.updatedAt
        )
    }

    nonisolated private static func replacingCredential(
        _ account: ProviderUsageAccount,
        reference: UUID,
        revision: Int,
        providerAccountID: String?
    ) -> ProviderUsageAccount {
        .init(
            id: account.id,
            provider: account.provider,
            sourceConnectionID: account.sourceConnectionID,
            apiProfile: account.apiProfile,
            sourceKind: account.sourceKind,
            sourceScope: account.sourceScope,
            credentialKind: account.credentialKind,
            providerAccountID: providerAccountID ?? account.providerAccountID,
            credentialReference: reference,
            credentialRevision: revision,
            credentialExpiresAt: Date(timeIntervalSince1970: 500),
            createdAt: account.createdAt,
            updatedAt: Date(timeIntervalSince1970: 200)
        )
    }

    nonisolated private static func savedResult() -> ProviderUsageAccountSaveResult {
        .init(account: account(), supersededCredentialCleanupPending: false)
    }

    nonisolated private static func renewalCandidate() -> ProviderUsageSetupCandidate {
        .init(
            id: UUID(uuidString: "78787878-7878-7878-7878-787878787878")!,
            provider: .codex,
            discoveryContext: .init(
                backend: .init(id: "server-one", name: "Synthetic Backend", version: "1"),
                connectionLifetimeID: UUID(uuidString: "89898989-8989-8989-8989-898989898989")!,
                apiProfile: .legacy,
                scope: .init(projectID: "project-one", directory: "/workspace/one", workspaceID: "workspace-one")
            ),
            sourceIdentity: .legacyProvider(providerID: "openai"),
            sourceKind: .openCodeAuth,
            credentialKind: .oauthAccessToken,
            replacingAccountID: codexAccount().id
        )
    }

    nonisolated fileprivate static func snapshot() -> ProviderUsageSnapshot {
        .init(provider: .openRouter, accountLabel: nil, fetchedAt: Date(timeIntervalSince1970: 300), credentialExpiresAt: nil, metrics: [])
    }
}

private actor ProviderUsageImporterFake: ProviderUsageCredentialImporter {
    private let review: ProviderUsageCredentialReview
    private(set) var callCount = 0
    init(review: ProviderUsageCredentialReview) { self.review = review }
    func importCredential(for candidate: ProviderUsageSetupCandidate) async throws -> ProviderUsageCredentialReview {
        callCount += 1
        return review
    }
}

private struct ProviderUsageThrowingImporter: ProviderUsageCredentialImporter {
    let error: ProviderUsageCredentialImportError?

    func importCredential(for candidate: ProviderUsageSetupCandidate) async throws -> ProviderUsageCredentialReview {
        if let error { throw error }
        throw NSError(domain: "fixture", code: 1)
    }
}

private actor DeferredProviderUsageImporter: ProviderUsageCredentialImporter {
    private var continuation: CheckedContinuation<ProviderUsageCredentialReview, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func importCredential(for candidate: ProviderUsageSetupCandidate) async throws -> ProviderUsageCredentialReview {
        waiters.forEach { $0.resume() }
        waiters = []
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func waitUntilCalled() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resolve(_ review: ProviderUsageCredentialReview) { continuation?.resume(returning: review); continuation = nil }
}

private actor ProviderUsageAccountRepositoryFake: ProviderUsageAccountRepository {
    private(set) var saveCount = 0
    private var stored: [ProviderUsageAccount] = []
    private let result: ProviderUsageAccountSaveResult
    private let saveError: ProviderUsageAccountRepositoryError?
    private let events: ProviderUsageEventRecorder?
    private let credentialSecret: ProviderUsageTransientSecret
    init(
        result: ProviderUsageAccountSaveResult = .init(account: ProviderUsagePersistenceTests.account(), supersededCredentialCleanupPending: false),
        saveError: ProviderUsageAccountRepositoryError? = nil,
        events: ProviderUsageEventRecorder? = nil,
        initialAccounts: [ProviderUsageAccount] = [],
        credentialSecret: ProviderUsageTransientSecret = .init(value: "fixture-secret")
    ) { self.result = result; self.saveError = saveError; self.events = events; self.stored = initialAccounts; self.credentialSecret = credentialSecret }
    func load() -> [ProviderUsageAccount] { stored }
    func readCredential(accountID: UUID, credentialRevision: Int) throws -> ProviderUsageTransientSecret {
        guard let account = stored.first(where: { $0.id == accountID }), account.credentialRevision == credentialRevision else {
            throw ProviderUsageAccountRepositoryError.credentialRevisionMismatch
        }
        return credentialSecret
    }
    func save(review: ProviderUsageCredentialReview) async throws -> ProviderUsageAccountSaveResult {
        saveCount += 1
        events?.append("save")
        if let saveError { throw saveError }
        stored = [result.account]
        return result
    }
    func remove(accountID: UUID) { stored.removeAll { $0.id == accountID } }
}

private actor DeferredProviderUsageAccountRepository: ProviderUsageAccountRepository {
    private var continuation: CheckedContinuation<ProviderUsageAccountSaveResult, Error>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func load() -> [ProviderUsageAccount] { [] }
    func readCredential(accountID: UUID, credentialRevision: Int) throws -> ProviderUsageTransientSecret {
        throw ProviderUsageAccountRepositoryError.accountMissing
    }
    func save(review: ProviderUsageCredentialReview) async throws -> ProviderUsageAccountSaveResult {
        waiters.forEach { $0.resume() }; waiters = []
        return try await withCheckedThrowingContinuation { continuation = $0 }
    }
    func remove(accountID: UUID) {}
    func waitUntilSaved() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func resolve(_ result: ProviderUsageAccountSaveResult) { continuation?.resume(returning: result); continuation = nil }
}

private actor DeferredProviderUsageCredentialReadRepository: ProviderUsageAccountRepository {
    private let account: ProviderUsageAccount
    private var continuation: CheckedContinuation<ProviderUsageTransientSecret, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(account: ProviderUsageAccount) {
        self.account = account
    }

    func load() -> [ProviderUsageAccount] { [account] }

    func readCredential(accountID: UUID, credentialRevision: Int) async throws -> ProviderUsageTransientSecret {
        waiters.forEach { $0.resume() }
        waiters = []
        return await withCheckedContinuation { continuation = $0 }
    }

    func save(review: ProviderUsageCredentialReview) async throws -> ProviderUsageAccountSaveResult {
        throw ProviderUsageAccountRepositoryError.accountMissing
    }

    func remove(accountID: UUID) async throws {
        throw ProviderUsageAccountRepositoryError.accountMissing
    }

    func waitUntilRead() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resolve(_ secret: ProviderUsageTransientSecret) {
        continuation?.resume(returning: secret)
        continuation = nil
    }
}

private actor DeferredRotationAccountRepository: ProviderUsageAccountRepository {
    private let original: ProviderUsageAccount
    private let committed: ProviderUsageAccount
    private var rotationContinuation: CheckedContinuation<Void, Never>?
    private var rotationWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var rotationCount = 0

    init(original: ProviderUsageAccount, committed: ProviderUsageAccount) {
        self.original = original
        self.committed = committed
    }

    func load() -> [ProviderUsageAccount] { [original] }

    func readCredential(accountID: UUID, credentialRevision: Int) throws -> ProviderUsageTransientSecret {
        .init(value: "old-access")
    }

    func save(review: ProviderUsageCredentialReview) throws -> ProviderUsageAccountSaveResult {
        throw ProviderUsageAccountRepositoryError.accountMissing
    }

    func rotateCredential(
        accountID: UUID,
        credentialRevision: Int,
        secret: ProviderUsageTransientSecret,
        expiresAt: Date,
        providerAccountID: String?
    ) async throws -> ProviderUsageAccountSaveResult {
        rotationCount += 1
        rotationWaiters.forEach { $0.resume() }
        rotationWaiters = []
        await withCheckedContinuation { rotationContinuation = $0 }
        return .init(account: committed, supersededCredentialCleanupPending: false)
    }

    func remove(accountID: UUID) throws {}

    func waitUntilRotationStarted() async {
        if rotationContinuation != nil { return }
        await withCheckedContinuation { rotationWaiters.append($0) }
    }

    func finishRotation() {
        rotationContinuation?.resume()
        rotationContinuation = nil
    }
}

private actor ProviderUsageFetchingFake: ProviderUsageFetching {
    struct Request: Equatable, Sendable {
        let provider: ProviderUsageProvider
        let credentialKind: ProviderUsageCredentialKind
        let secret: String
        let providerAccountID: String?
        let credentialExpiresAt: Date?
    }
    private(set) var callCount = 0
    private(set) var lastRequest: Request?
    private let snapshot: ProviderUsageSnapshot
    private let error: ProviderUsageError?
    private let events: ProviderUsageEventRecorder?
    init(
        snapshot: ProviderUsageSnapshot = ProviderUsagePersistenceTests.snapshot(),
        error: ProviderUsageError? = nil,
        events: ProviderUsageEventRecorder? = nil
    ) { self.snapshot = snapshot; self.error = error; self.events = events }
    func fetchUsage(
        provider: ProviderUsageProvider,
        credentialKind: ProviderUsageCredentialKind,
        secret: ProviderUsageTransientSecret,
        providerAccountID: String?,
        credentialExpiresAt: Date?
    ) async throws -> ProviderUsageSnapshot {
        callCount += 1
        lastRequest = Request(
            provider: provider,
            credentialKind: credentialKind,
            secret: secret.value,
            providerAccountID: providerAccountID,
            credentialExpiresAt: credentialExpiresAt
        )
        events?.append("fetch")
        if let error { throw error }
        return snapshot
    }
}

private actor RefreshingProviderUsageFake: ProviderUsageFetching {
    private(set) var fetchCount = 0

    func fetchUsage(
        provider: ProviderUsageProvider,
        credentialKind: ProviderUsageCredentialKind,
        secret: ProviderUsageTransientSecret,
        providerAccountID: String?,
        credentialExpiresAt: Date?
    ) async throws -> ProviderUsageSnapshot {
        fetchCount += 1
        if provider == .openRouter || fetchCount == 1 { throw ProviderUsageError.unauthorized }
        return .init(
            provider: provider,
            accountLabel: nil,
            fetchedAt: Date(timeIntervalSince1970: 300),
            credentialExpiresAt: credentialExpiresAt,
            metrics: []
        )
    }

}

private actor RenewingProviderUsageImporterFake: ProviderUsageCredentialImporter {
    private(set) var renewalCount = 0
    private let error: ProviderUsageCredentialImportError?
    private let returnedAccountID: String?

    init(
        error: ProviderUsageCredentialImportError? = nil,
        returnedAccountID: String? = nil
    ) {
        self.error = error
        self.returnedAccountID = returnedAccountID
    }

    func importCredential(for candidate: ProviderUsageSetupCandidate) throws -> ProviderUsageCredentialReview {
        throw ProviderUsageCredentialImportError.unsupportedSource
    }

    func renewCredential(
        for candidate: ProviderUsageSetupCandidate,
        expectedAccountID: String,
        currentAccessToken: String
    ) throws -> ProviderUsageCredentialRenewal {
        renewalCount += 1
        if let error { throw error }
        return .init(
            secret: .init(value: "new-access"),
            expiresAt: Date(timeIntervalSince1970: 500),
            providerAccountID: returnedAccountID ?? expectedAccountID
        )
    }
}

private actor DeferredRenewingProviderUsageImporterFake: ProviderUsageCredentialImporter {
    private var continuation: CheckedContinuation<ProviderUsageCredentialRenewal, Never>?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var expectedAccountID: String?

    func importCredential(for candidate: ProviderUsageSetupCandidate) throws -> ProviderUsageCredentialReview {
        throw ProviderUsageCredentialImportError.unsupportedSource
    }

    func renewCredential(
        for candidate: ProviderUsageSetupCandidate,
        expectedAccountID: String,
        currentAccessToken: String
    ) async -> ProviderUsageCredentialRenewal {
        self.expectedAccountID = expectedAccountID
        waiters.forEach { $0.resume() }
        waiters.removeAll()
        return await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilRenewalRequested() async {
        if continuation != nil { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func resolve() {
        continuation?.resume(returning: .init(
            secret: .init(value: "new-access"),
            expiresAt: Date(timeIntervalSince1970: 500),
            providerAccountID: expectedAccountID
        ))
        continuation = nil
    }
}

private actor ProviderUsageMetadataFake: ProviderUsageMetadataRepository {
    private var accounts: [ProviderUsageAccount]
    private let saveError: ProviderUsageMetadataRepositoryError?
    private let events: ProviderUsageEventRecorder?
    init(
        accounts: [ProviderUsageAccount] = [],
        saveError: ProviderUsageMetadataRepositoryError? = nil,
        events: ProviderUsageEventRecorder? = nil
    ) { self.accounts = accounts; self.saveError = saveError; self.events = events }
    func load() -> [ProviderUsageAccount] { accounts }
    func save(_ accounts: [ProviderUsageAccount]) async throws {
        events?.append("metadata")
        if let saveError { throw saveError }
        self.accounts = accounts
    }
}

private actor SuspendingProviderUsageMetadataFake: ProviderUsageMetadataRepository {
    private var accounts: [ProviderUsageAccount]
    private var shouldSuspendSave = true
    private var saveContinuation: CheckedContinuation<Void, Never>?
    private var saveWaiters: [CheckedContinuation<Void, Never>] = []
    private(set) var loadCount = 0

    init(accounts: [ProviderUsageAccount]) {
        self.accounts = accounts
    }

    func load() -> [ProviderUsageAccount] {
        loadCount += 1
        return accounts
    }

    func save(_ accounts: [ProviderUsageAccount]) async {
        if shouldSuspendSave {
            shouldSuspendSave = false
            saveWaiters.forEach { $0.resume() }
            saveWaiters = []
            await withCheckedContinuation { saveContinuation = $0 }
        }
        self.accounts = accounts
    }

    func waitUntilSaveStarted() async {
        if saveContinuation != nil { return }
        await withCheckedContinuation { saveWaiters.append($0) }
    }

    func finishSave() {
        saveContinuation?.resume()
        saveContinuation = nil
    }

    func currentAccounts() -> [ProviderUsageAccount] { accounts }
}

private final class ProviderUsageCredentialMemoryFake: ProviderUsageCredentialRepository, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID: ProviderUsageTransientSecret]
    private(set) var readReferences: [UUID] = []
    private let writeError: ProviderUsageCredentialRepositoryError?
    private let deleteError: ProviderUsageCredentialRepositoryError?
    private let events: ProviderUsageEventRecorder?
    init(
        values: [UUID: ProviderUsageTransientSecret] = [:],
        writeError: ProviderUsageCredentialRepositoryError? = nil,
        deleteError: ProviderUsageCredentialRepositoryError? = nil,
        events: ProviderUsageEventRecorder? = nil
    ) { self.values = values; self.writeError = writeError; self.deleteError = deleteError; self.events = events }
    func write(_ secret: ProviderUsageTransientSecret, reference: UUID) throws {
        if let writeError { throw writeError }
        lock.withLock { values[reference] = secret }
        events?.append("write")
    }
    func read(reference: UUID) throws -> ProviderUsageTransientSecret {
        lock.withLock { readReferences.append(reference) }
        guard let value = lock.withLock({ values[reference] }) else { throw ProviderUsageCredentialRepositoryError.missing }
        return value
    }
    func delete(reference: UUID) throws {
        if let deleteError { throw deleteError }
        guard lock.withLock({ values.removeValue(forKey: reference) }) != nil else { throw ProviderUsageCredentialRepositoryError.missing }
        events?.append("delete:\(reference.uuidString)")
    }
}

private final class ProviderUsageEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [String] = []
    var values: [String] { lock.withLock { storedValues } }
    func append(_ value: String) { lock.withLock { storedValues.append(value) } }
}

private final class ProviderUsageUUIDSequence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [UUID]
    init(_ values: [UUID]) { self.values = values }
    func next() -> UUID { lock.withLock { values.removeFirst() } }
}

private final class ProviderUsageSecurityFake: ProviderUsageSecurityClient {
    private(set) var addQueries: [[String: Any]] = []
    private(set) var readQueries: [[String: Any]] = []
    private(set) var deleteQueries: [[String: Any]] = []
    private var value: Data?
    var storedValue: Data? { value }
    func add(_ attributes: [String: Any]) -> OSStatus {
        addQueries.append(attributes)
        value = attributes[kSecValueData as String] as? Data
        return errSecSuccess
    }
    func copyMatching(_ query: [String: Any], result: inout CFTypeRef?) -> OSStatus {
        readQueries.append(query)
        guard let value else { return errSecItemNotFound }
        result = value as CFData
        return errSecSuccess
    }
    func delete(_ query: [String: Any]) -> OSStatus {
        deleteQueries.append(query)
        value = nil
        return errSecSuccess
    }
}

@MainActor
private func XCTAssertThrowsErrorAsync<T>(
    _ expression: () async throws -> T,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        _ = try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
