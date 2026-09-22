import Foundation
import XCTest
@testable import OpenClient

@MainActor
final class ProviderUsageDisplayStoreTests: XCTestCase {
    func testWidgetMetricIdentityResolutionOrderingAndLimits() {
        let accountID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let metrics = (1...9).map { displayMetric(accountID: accountID, id: "metric-\($0)", percent: Double($0 * 10)) }
        let configured = [metrics[3], metrics[0], metrics[7]].map {
            OpenCodeProviderUsageWidgetMetrics.stableID(for: $0.identity)
        }

        XCTAssertEqual(
            OpenCodeProviderUsageWidgetMetrics.stableID(for: metrics[0].identity),
            OpenCodeProviderUsageWidgetMetrics.stableID(for: metrics[0].identity)
        )
        XCTAssertFalse(OpenCodeProviderUsageWidgetMetrics.stableID(for: metrics[0].identity).contains(accountID.uuidString))
        XCTAssertNotEqual(
            OpenCodeProviderUsageWidgetMetrics.stableID(for: metrics[0].identity),
            OpenCodeProviderUsageWidgetMetrics.stableID(for: .init(accountID: accountID, metricID: "METRIC-1"))
        )
        XCTAssertEqual(
            OpenCodeProviderUsageWidgetMetrics.resolve(
                metrics: metrics,
                configuredIDs: [configured[0], "stale", configured[1], configured[0], configured[2]],
                limit: 2
            ).map(\.identity.metricID),
            ["metric-4", "metric-1"]
        )
        XCTAssertEqual(
            OpenCodeProviderUsageWidgetMetrics.resolve(metrics: metrics, configuredIDs: [], limit: 4).map(\.identity.metricID),
            ["metric-1", "metric-2", "metric-3", "metric-4"]
        )
        XCTAssertEqual(
            OpenCodeProviderUsageWidgetMetrics.resolve(metrics: metrics, configuredIDs: ["stale"], limit: 1).map(\.identity.metricID),
            ["metric-1"]
        )
        XCTAssertEqual(OpenCodeProviderUsageWidgetMetrics.limit(for: .bars, size: .large), 6)
        XCTAssertEqual(OpenCodeProviderUsageWidgetMetrics.limit(for: .rings, size: .large), 8)
        XCTAssertEqual(OpenCodeProviderUsageWidgetMetrics.limit(for: .rings, size: .medium), 4)
        XCTAssertEqual(OpenCodeProviderUsageWidgetMetrics.limit(for: .bars, size: .small), 1)
    }

    func testWidgetPayloadPublicationReloadsBothUsageWidgetsThroughBoundary() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let reloader = ProviderUsageWidgetTimelineReloaderSpy()
        let store = ProviderUsageDisplayStore(
            persistence: .init(defaults: defaults),
            widgetTimelineReloader: reloader
        )
        let account = makeAccount(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", provider: .openRouter)

        store.reconcile(accounts: [account], snapshots: [account.id: snapshot(
            provider: .openRouter,
            metrics: [metric(id: "spend", value: 12)]
        )])

        XCTAssertEqual(reloader.reloadCount, 1)
        store.setVisible(false, identity: store.availableMetrics[0].identity, destination: .home)
        XCTAssertEqual(reloader.reloadCount, 1, "Visibility does not alter the visibility-independent widget payload")
    }

    func testDisplayModeDefaultsPersistsAndRejectsFutureVersion() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = OpenCodeProviderUsageDisplayPersistence(defaults: defaults)

        XCTAssertEqual(persistence.loadDisplayMode(), .progressBar)
        persistence.saveDisplayMode(.progressRing)
        XCTAssertEqual(persistence.loadDisplayMode(), .progressRing)

        let future = OpenCodeProviderUsageDisplayModeRecord(version: 99, mode: .progressRing)
        defaults.set(try JSONEncoder().encode(future), forKey: "OpenCodeProviderUsageDisplayMode")
        XCTAssertEqual(persistence.loadDisplayMode(), .progressBar)
    }

    func testVersionedPersistenceRoundTripsOrderAndDestinationFlags() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = OpenCodeProviderUsageDisplayPersistence(defaults: defaults)
        let first = identity("AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", "first")
        let second = identity("BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", "second")
        persistence.saveSelections([
            .init(identity: second, showsOnHome: true, showsInActivity: false),
            .init(identity: first, showsOnHome: false, showsInActivity: true),
        ])

        let loaded = persistence.loadSelections()
        XCTAssertEqual(loaded.version, OpenCodeProviderUsageSelectionRecord.currentVersion)
        XCTAssertEqual(loaded.selections.map(\.identity), [second, first])
        XCTAssertTrue(loaded.selections[0].showsOnHome)
        XCTAssertTrue(loaded.selections[1].showsInActivity)

        let future = OpenCodeProviderUsageSelectionRecord(version: 99, selections: loaded.selections)
        defaults.set(try JSONEncoder().encode(future), forKey: "OpenCodeProviderUsageMetricSelections")
        XCTAssertTrue(persistence.loadSelections().selections.isEmpty)
    }

    func testOrderingDestinationTogglesAndUnavailableReconciliation() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = OpenCodeProviderUsageDisplayPersistence(defaults: defaults)
        let store = ProviderUsageDisplayStore(persistence: persistence)
        let account = makeAccount(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", provider: .openRouter)
        store.reconcile(accounts: [account], snapshots: [account.id: snapshot(provider: .openRouter, metrics: [
            metric(id: "one", percent: 25, period: .rolling(seconds: 18_000)),
            metric(id: "two", value: 12),
        ])])
        let first = store.orderedAvailableMetrics[0].identity
        let second = store.orderedAvailableMetrics[1].identity

        store.setVisible(false, identity: second, destination: .home)
        store.setVisible(false, identity: first, destination: .activity)
        store.setVisible(true, identity: first, destination: .home)
        store.setVisible(true, identity: second, destination: .activity)
        store.moveAvailableMetrics(fromOffsets: IndexSet(integer: 1), toOffset: 0)

        XCTAssertEqual(store.orderedAvailableMetrics.map(\.identity), [second, first])
        XCTAssertEqual(store.orderedAvailableMetrics.first?.value, 12)
        XCTAssertNil(store.orderedAvailableMetrics.first?.percentUsed)
        XCTAssertEqual(store.orderedAvailableMetrics.last?.period, .rolling(seconds: 18_000))
        XCTAssertEqual(store.metrics(for: .home).map(\.identity), [first])
        XCTAssertEqual(store.metrics(for: .activity).map(\.identity), [second])

        store.reconcile(accounts: [account], snapshots: [:])
        XCTAssertTrue(store.availableMetrics.isEmpty)
        XCTAssertEqual(store.selections.map(\.identity), [second, first], "Temporary metric absence must preserve preferences")

        let restored = ProviderUsageDisplayStore(persistence: persistence)
        restored.reconcile(accounts: [account], snapshots: [account.id: snapshot(provider: .openRouter, metrics: [
            metric(id: "one", percent: 30),
            metric(id: "two", value: 11),
        ])])
        XCTAssertEqual(restored.orderedAvailableMetrics.map(\.identity), [second, first])
        XCTAssertEqual(restored.metrics(for: .home).first?.percentUsed, 30)
    }

    func testPreviewUsesSelectedMetricsThenFallsBackToAvailableMetrics() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderUsageDisplayStore(persistence: .init(defaults: defaults))
        let account = makeAccount(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", provider: .openRouter)
        store.reconcile(accounts: [account], snapshots: [account.id: snapshot(provider: .openRouter, metrics: [
            metric(id: "one", percent: 25), metric(id: "two", percent: 50),
        ])])

        XCTAssertEqual(store.previewMetrics.map(\.identity.metricID), ["one", "two"])
        store.setVisible(false, identity: store.availableMetrics[0].identity, destination: .activity)
        store.setVisible(false, identity: store.availableMetrics[0].identity, destination: .home)
        store.setVisible(true, identity: store.availableMetrics[1].identity, destination: .activity)
        XCTAssertEqual(store.previewMetrics.map(\.identity.metricID), ["two"])
    }

    func testNewMetricsDefaultToBothDestinationsAndPreserveExistingOffFlags() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = OpenCodeProviderUsageDisplayPersistence(defaults: defaults)
        let store = ProviderUsageDisplayStore(persistence: persistence)
        let account = makeAccount(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", provider: .openRouter)

        store.reconcile(accounts: [account], snapshots: [account.id: snapshot(provider: .openRouter, metrics: [
            metric(id: "existing", value: 12)
        ])])
        let existing = identity(account.id.uuidString, "existing")
        XCTAssertTrue(store.isVisible(existing, in: .home))
        XCTAssertTrue(store.isVisible(existing, in: .activity))

        store.setVisible(false, identity: existing, destination: .home)
        store.setVisible(false, identity: existing, destination: .activity)
        store.reconcile(accounts: [account], snapshots: [account.id: snapshot(provider: .openRouter, metrics: [
            metric(id: "existing", value: 11),
            metric(id: "new", value: 8)
        ])])

        let newMetric = identity(account.id.uuidString, "new")
        XCTAssertFalse(store.isVisible(existing, in: .home))
        XCTAssertFalse(store.isVisible(existing, in: .activity))
        XCTAssertTrue(store.isVisible(newMetric, in: .home))
        XCTAssertTrue(store.isVisible(newMetric, in: .activity))

        let restored = ProviderUsageDisplayStore(persistence: persistence)
        XCTAssertFalse(restored.isVisible(existing, in: .home))
        XCTAssertFalse(restored.isVisible(existing, in: .activity))
        XCTAssertTrue(restored.isVisible(newMetric, in: .home))
        XCTAssertTrue(restored.isVisible(newMetric, in: .activity))
    }

    func testProviderMetricsAreFilteredWithoutSharingVisibilityFlags() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ProviderUsageDisplayStore(persistence: .init(defaults: defaults))
        let openAI = makeAccount(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", provider: .codex)
        let openRouter = makeAccount(id: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB", provider: .openRouter)
        store.reconcile(
            accounts: [openAI, openRouter],
            snapshots: [
                openAI.id: snapshot(provider: .codex, metrics: [
                    metric(id: "quota", percent: 25),
                    metric(id: "daily", percent: 10),
                ]),
                openRouter.id: snapshot(provider: .openRouter, metrics: [
                    metric(id: "spend", value: 12),
                    metric(id: "balance", value: 8),
                ]),
            ]
        )

        let openAIMetric = try XCTUnwrap(store.orderedAvailableMetrics(for: .codex).first)
        let openRouterMetric = try XCTUnwrap(store.orderedAvailableMetrics(for: .openRouter).first)
        for metric in store.orderedAvailableMetrics {
            store.setVisible(false, identity: metric.identity, destination: .home)
            store.setVisible(false, identity: metric.identity, destination: .activity)
        }
        store.setVisible(true, identity: openAIMetric.identity, destination: .home)
        store.setVisible(true, identity: openRouterMetric.identity, destination: .activity)

        XCTAssertEqual(store.orderedAvailableMetrics(for: .codex).map(\.identity.accountID), [openAI.id, openAI.id])
        XCTAssertEqual(store.orderedAvailableMetrics(for: .codex).map(\.identity.metricID), ["quota", "daily"])
        XCTAssertEqual(store.orderedAvailableMetrics(for: .openRouter).map(\.identity.accountID), [openRouter.id, openRouter.id])
        XCTAssertEqual(store.orderedAvailableMetrics(for: .openRouter).map(\.identity.metricID), ["spend", "balance"])
        XCTAssertEqual(store.metrics(for: .home).map(\.identity), [openAIMetric.identity])
        XCTAssertEqual(store.metrics(for: .activity).map(\.identity), [openRouterMetric.identity])
        store.setDisplayMode(.progressRing)
        XCTAssertEqual(store.displayMode, .progressRing)

        let restored = ProviderUsageDisplayStore(persistence: .init(defaults: defaults))
        XCTAssertEqual(restored.displayMode, .progressRing)
        XCTAssertEqual(restored.selections.map(\.identity), store.selections.map(\.identity))
    }

    func testRingRenderStatesAreSafe() {
        let accountID = UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!
        let metrics = [
            displayMetric(accountID: accountID, id: "over", percent: 150),
            displayMetric(accountID: accountID, id: "value", value: 12),
            displayMetric(accountID: accountID, id: "missing"),
            displayMetric(accountID: accountID, id: "unlimited", unlimited: true),
        ]
        XCTAssertEqual(metrics[0].renderState, .progress(fraction: 1, isOverLimit: true))
        XCTAssertEqual(metrics[1].renderState, .valueOnly)
        XCTAssertEqual(metrics[2].renderState, .unavailable)
        XCTAssertEqual(metrics[3].renderState, .unlimited)
    }

    func testWidgetPayloadIsSanitizedAndContainsAllAvailableRenderSnapshots() throws {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = OpenCodeProviderUsageDisplayPersistence(defaults: defaults)
        let store = ProviderUsageDisplayStore(persistence: persistence)
        let account = ProviderUsageAccount(
            id: UUID(uuidString: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA")!,
            provider: .openRouter,
            sourceConnectionID: "SECRET-SOURCE-CONNECTION",
            apiProfile: .legacy,
            sourceKind: .openCodeAuth,
            credentialKind: .apiKey,
            credentialReference: UUID(uuidString: "BBBBBBBB-BBBB-BBBB-BBBB-BBBBBBBBBBBB")!,
            credentialRevision: 42,
            createdAt: .distantPast,
            updatedAt: .distantPast
        )
        store.reconcile(accounts: [account], snapshots: [account.id: .init(
            provider: .openRouter,
            accountLabel: "Example\nAccount",
            accountID: "SECRET-PROVIDER-ACCOUNT",
            plan: "SECRET-RAW-PLAN",
            fetchedAt: Date(timeIntervalSince1970: 100),
            credentialExpiresAt: Date(timeIntervalSince1970: 200),
            metrics: [
                metric(id: "spend", value: 9),
                metric(id: "limit", percent: 30),
            ]
        )])
        store.setVisible(false, identity: store.availableMetrics[0].identity, destination: .home)

        let payload = persistence.loadWidgetPayload()
        XCTAssertEqual(payload.metrics.count, 2, "Widgets can choose metrics independently of in-app visibility")
        XCTAssertEqual(payload.metrics[0].accountLabel, "ExampleAccount")
        let encoded = String(decoding: try JSONEncoder().encode(payload), as: UTF8.self)
        for forbidden in ["SECRET-SOURCE-CONNECTION", "SECRET-PROVIDER-ACCOUNT", "SECRET-RAW-PLAN", "credentialReference", "credentialRevision"] {
            XCTAssertFalse(encoded.contains(forbidden))
        }
    }

    func testPrepareDisplayRefreshesOnlySelectedStaleAccount() async {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = OpenCodeProviderUsageDisplayPersistence(defaults: defaults)
        let displayStore = ProviderUsageDisplayStore(persistence: persistence)
        let usageStore = ProviderUsageStore()
        let selected = makeAccount(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", provider: .openRouter)
        let unselected = makeAccount(id: "CCCCCCCC-CCCC-CCCC-CCCC-CCCCCCCCCCCC", provider: .codex)
        let repository = ProviderUsageDisplayAccountRepository(accounts: [selected, unselected])
        let client = ProviderUsageDisplayFetching()
        let facade = ProviderUsageFacade(
            store: usageStore,
            displayStore: displayStore,
            accounts: repository,
            providerClient: client,
            contextProvider: { nil },
            legacyStateProvider: { .init(readiness: .notHydrated, connectedProviders: []) },
            v2StateProvider: { .init(readiness: .notHydrated, integrations: []) },
            importerFactory: { _, _, _ in throw ProviderUsageCredentialImportError.unsupportedSource }
        )
        await facade.loadPersistedAccountsOnce()
        usageStore.replaceAccounts([selected, unselected])
        apply(snapshot(provider: .openRouter, metrics: [metric(id: "selected", percent: 10)]), to: selected.id, store: usageStore)
        apply(snapshot(provider: .codex, metrics: [metric(id: "unselected", percent: 20)]), to: unselected.id, store: usageStore)
        displayStore.reconcile(accounts: usageStore.accounts, snapshots: usageStore.snapshots)
        let identity = OpenCodeProviderUsageMetricIdentity(accountID: selected.id, metricID: "selected")
        let unselectedIdentity = OpenCodeProviderUsageMetricIdentity(accountID: unselected.id, metricID: "unselected")
        displayStore.setVisible(false, identity: unselectedIdentity, destination: .home)
        displayStore.setVisible(true, identity: identity, destination: .home)

        await facade.prepareDisplay(.home, referenceDate: Date(timeIntervalSince1970: 1_000), maxAge: 1)

        let refreshedProviders = await client.providers
        XCTAssertEqual(refreshedProviders, [.openRouter])
    }

    func testExplicitAccountRemovalClearsItsSelectionsAndWidgetMetrics() {
        let (defaults, suiteName) = makeDefaults()
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let persistence = OpenCodeProviderUsageDisplayPersistence(defaults: defaults)
        let store = ProviderUsageDisplayStore(persistence: persistence)
        let account = makeAccount(id: "AAAAAAAA-AAAA-AAAA-AAAA-AAAAAAAAAAAA", provider: .openRouter)
        store.reconcile(accounts: [account], snapshots: [account.id: snapshot(
            provider: .openRouter,
            metrics: [metric(id: "spend", value: 12)]
        )])

        store.removeSelections(accountID: account.id)

        XCTAssertTrue(store.selections.isEmpty)
        XCTAssertTrue(store.availableMetrics.isEmpty)
        XCTAssertTrue(persistence.loadWidgetPayload().metrics.isEmpty)
    }

    private func apply(_ snapshot: ProviderUsageSnapshot, to id: UUID, store: ProviderUsageStore) {
        let handle = store.beginRefresh(accountID: id)!
        XCTAssertTrue(store.applyRefresh(snapshot, handle: handle))
    }

    private func identity(_ account: String, _ metric: String) -> OpenCodeProviderUsageMetricIdentity {
        .init(accountID: UUID(uuidString: account)!, metricID: metric)
    }

    private func makeDefaults() -> (UserDefaults, String) {
        let suiteName = "ProviderUsageDisplayStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeAccount(id: String, provider: ProviderUsageProvider) -> ProviderUsageAccount {
        .init(
            id: UUID(uuidString: id)!, provider: provider, sourceConnectionID: "source", apiProfile: .legacy,
            sourceKind: .openCodeAuth, credentialKind: provider.legacyCredentialKind,
            credentialReference: UUID(), credentialRevision: 1, createdAt: .distantPast, updatedAt: .distantPast
        )
    }

    private func snapshot(provider: ProviderUsageProvider, metrics: [ProviderUsageMetric]) -> ProviderUsageSnapshot {
        .init(provider: provider, accountLabel: "Test", fetchedAt: Date(timeIntervalSince1970: 10), credentialExpiresAt: nil, metrics: metrics)
    }

    private func metric(
        id: String,
        percent: Double? = nil,
        value: Decimal? = nil,
        period: ProviderUsagePeriod? = nil
    ) -> ProviderUsageMetric {
        .init(
            id: id, kind: value == nil ? .quota : .spend, period: period, used: value, remaining: nil,
            limit: nil, percentUsed: percent, unit: value == nil ? .percentage : .currency("USD"), resetAt: nil
        )
    }

    private func displayMetric(
        accountID: UUID,
        id: String,
        percent: Double? = nil,
        value: Decimal? = nil,
        unlimited: Bool = false
    ) -> OpenCodeProviderUsageDisplayMetric {
        .init(
            identity: .init(accountID: accountID, metricID: id), providerID: "openai", providerName: "OpenAI",
            accountLabel: "Account", metricLabel: id, value: value, percentUsed: percent, unit: .count,
            period: nil, resetAt: nil, isUnlimited: unlimited, fetchedAt: Date()
        )
    }
}

private final class ProviderUsageWidgetTimelineReloaderSpy: ProviderUsageWidgetTimelineReloading {
    private(set) var reloadCount = 0
    func reloadProviderUsageTimelines() { reloadCount += 1 }
}

private actor ProviderUsageDisplayAccountRepository: ProviderUsageAccountRepository {
    private var accounts: [ProviderUsageAccount]
    init(accounts: [ProviderUsageAccount]) { self.accounts = accounts }
    func load() -> [ProviderUsageAccount] { accounts }
    func readCredential(accountID: UUID, credentialRevision: Int) throws -> ProviderUsageTransientSecret {
        .init(value: "test-secret")
    }
    func save(review: ProviderUsageCredentialReview) throws -> ProviderUsageAccountSaveResult {
        throw ProviderUsageAccountRepositoryError.accountMissing
    }
    func remove(accountID: UUID) throws { accounts.removeAll { $0.id == accountID } }
}

private actor ProviderUsageDisplayFetching: ProviderUsageFetching {
    private(set) var providers: [ProviderUsageProvider] = []
    func fetchUsage(
        provider: ProviderUsageProvider,
        credentialKind: ProviderUsageCredentialKind,
        secret: ProviderUsageTransientSecret,
        providerAccountID: String?,
        credentialExpiresAt: Date?
    ) async throws -> ProviderUsageSnapshot {
        providers.append(provider)
        return .init(provider: provider, accountLabel: "Updated", fetchedAt: Date(), credentialExpiresAt: nil, metrics: [])
    }
}
