import XCTest
@testable import OpenClient

@MainActor
final class CommerceStoreTests: XCTestCase {
    func testLifetimeAndMonthlyProductsBothGrantProAccess() {
        XCTAssertTrue(OpenClientProductID.grantsProAccess("com.ntoporcov.openclient.pro"))
        XCTAssertTrue(OpenClientProductID.grantsProAccess("com.ntoporcov.openclient.pro.monthly.v1"))
        XCTAssertFalse(OpenClientProductID.grantsProAccess("com.ntoporcov.openclient.unknown"))
    }

    func testOnlyLifetimeProductGrantsLifetimeAccess() {
        XCTAssertTrue(OpenClientProductID.grantsProLifetimeAccess("com.ntoporcov.openclient.pro"))
        XCTAssertFalse(OpenClientProductID.grantsProLifetimeAccess("com.ntoporcov.openclient.pro.monthly.v1"))
    }

    func testLifetimeLaunchPriceEndsAtLocalMidnightOnSeptember30() throws {
        let easternTimeZone = try XCTUnwrap(TimeZone(secondsFromGMT: -4 * 60 * 60))
        let formatter = ISO8601DateFormatter()
        let justBeforeLocalMidnight = try XCTUnwrap(formatter.date(from: "2026-09-30T03:59:59Z"))
        let localMidnight = try XCTUnwrap(formatter.date(from: "2026-09-30T04:00:00Z"))

        XCTAssertTrue(OpenClientCommercePricing.isLifetimeLaunchPriceActive(
            at: justBeforeLocalMidnight,
            timeZone: easternTimeZone
        ))
        XCTAssertFalse(OpenClientCommercePricing.isLifetimeLaunchPriceActive(
            at: localMidnight,
            timeZone: easternTimeZone
        ))
    }

    func testDebugMonthlyUnlocksProButNotLifetimeBenefits() {
        let facade = makeFacade(persistence: MemoryUsageStore())

        facade.debugEntitlementOverride = .monthly

        XCTAssertTrue(facade.hasProUnlock)
        XCTAssertFalse(facade.hasProLifetimeUnlock)
    }

    func testFreePromptLimitAndRefund() {
        let persistence = MemoryUsageStore()
        let facade = makeFacade(persistence: persistence)

        for _ in 0..<OpenClientCommerceLimits.dailyPromptLimit {
            XCTAssertTrue(facade.reserveUserPromptIfAllowed())
        }
        XCTAssertFalse(facade.reserveUserPromptIfAllowed())
        XCTAssertEqual(facade.paywallReason, .promptLimit)

        facade.refundReservedUserPromptIfNeeded()

        XCTAssertEqual(facade.usageMeter.dailyPromptCount, OpenClientCommerceLimits.dailyPromptLimit - 1)
        XCTAssertEqual(persistence.meter.dailyPromptCount, OpenClientCommerceLimits.dailyPromptLimit - 1)
    }

    func testFreeSessionGateRecordsOnlySuccessfulCreation() {
        let persistence = MemoryUsageStore()
        let facade = makeFacade(persistence: persistence)

        XCTAssertTrue(facade.canCreateSessionOrPresentPaywall())
        facade.recordCreatedSessionForMetering()
        XCTAssertFalse(facade.canCreateSessionOrPresentPaywall())
        XCTAssertEqual(facade.paywallReason, .sessionLimit)
        XCTAssertEqual(persistence.meter.createdSessionCount, 1)
    }

    func testDailyNormalizationPreservesCreatedSessionCount() {
        let persistence = MemoryUsageStore(
            meter: OpenClientUsageMeter(
                promptDay: "2000-01-01",
                dailyPromptCount: 4,
                createdSessionCount: 1
            )
        )
        let store = CommerceStore(debugEntitlementOverride: .free)
        let facade = CommerceFacade(
            store: store,
            usageStore: persistence,
            purchaseManager: OpenClientPurchaseManager()
        )

        facade.hydratePersistedState()

        XCTAssertEqual(facade.remainingFreePromptsToday, OpenClientCommerceLimits.dailyPromptLimit)
        XCTAssertEqual(facade.usageMeter.createdSessionCount, 1)
    }

    func testDebugLimitReachedForcesPromptPaywallWithoutChangingSessionAllowance() {
        let facade = makeFacade(persistence: MemoryUsageStore())
        facade.debugEntitlementOverride = .limitReached

        XCTAssertEqual(facade.remainingFreePromptsToday, 0)
        XCTAssertEqual(facade.remainingFreeSessions, OpenClientCommerceLimits.freeSessionLimit)
        XCTAssertFalse(facade.reserveUserPromptIfAllowed())
        XCTAssertEqual(facade.paywallReason, .promptLimit)
    }

    private func makeFacade(persistence: MemoryUsageStore) -> CommerceFacade {
        CommerceFacade(
            store: CommerceStore(debugEntitlementOverride: .free),
            usageStore: persistence,
            purchaseManager: OpenClientPurchaseManager()
        )
    }
}

private final class MemoryUsageStore: OpenClientUsagePersisting {
    var meter: OpenClientUsageMeter

    init(meter: OpenClientUsageMeter = .empty) {
        self.meter = meter
    }

    func load() -> OpenClientUsageMeter {
        var loaded = meter
        loaded.normalize()
        return loaded
    }

    func save(_ meter: OpenClientUsageMeter) {
        self.meter = meter
    }
}
