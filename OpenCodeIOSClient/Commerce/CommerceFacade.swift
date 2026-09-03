import Combine
import Foundation

@MainActor
final class CommerceStore: ObservableObject {
    @Published var usageMeter: OpenClientUsageMeter
    @Published var paywallReason: OpenClientPaywallReason?
#if DEBUG
    @Published var debugEntitlementOverride: OpenClientDebugEntitlementOverride
#endif

#if DEBUG
    init(
        usageMeter: OpenClientUsageMeter = .empty,
        paywallReason: OpenClientPaywallReason? = nil,
        debugEntitlementOverride: OpenClientDebugEntitlementOverride = .unlocked
    ) {
        self.usageMeter = usageMeter
        self.paywallReason = paywallReason
        self.debugEntitlementOverride = debugEntitlementOverride
    }
#else
    init(
        usageMeter: OpenClientUsageMeter = .empty,
        paywallReason: OpenClientPaywallReason? = nil
    ) {
        self.usageMeter = usageMeter
        self.paywallReason = paywallReason
    }
#endif
}

@MainActor
final class CommerceFacade: ObservableObject {
    let store: CommerceStore
    let purchaseManager: OpenClientPurchaseManager

    private let usageStore: any OpenClientUsagePersisting
    private var observations: Set<AnyCancellable> = []

    init(
        store: CommerceStore = CommerceStore(),
        usageStore: any OpenClientUsagePersisting = OpenClientUsageStore(),
        purchaseManager: OpenClientPurchaseManager = OpenClientPurchaseManager()
    ) {
        self.store = store
        self.usageStore = usageStore
        self.purchaseManager = purchaseManager

        store.objectWillChange
            .merge(with: purchaseManager.objectWillChange)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)
    }

    var usageMeter: OpenClientUsageMeter {
        get { store.usageMeter }
        set { store.usageMeter = newValue }
    }

    var paywallReason: OpenClientPaywallReason? {
        get { store.paywallReason }
        set { store.paywallReason = newValue }
    }

    var storeKitHasProUnlock: Bool { purchaseManager.hasProUnlock }
    var storeKitHasProLifetimeUnlock: Bool { purchaseManager.hasProLifetimeUnlock }
    var storeKitHasProMonthlyUnlock: Bool { purchaseManager.hasProMonthlyUnlock }
    var isLoadingProducts: Bool { purchaseManager.isLoadingProducts }
    var isPurchasing: Bool { purchaseManager.purchasingProductID != nil }
    var isPurchaseOperationInProgress: Bool {
        !purchaseManager.hasRefreshedEntitlements
            || isLoadingProducts
            || isPurchasing
            || purchaseManager.isRestoringPurchases
    }
    var proLifetimeDisplayPrice: String? { purchaseManager.proLifetimeProduct?.displayPrice }
    var proMonthlyDisplayPrice: String? { purchaseManager.proMonthlyProduct?.displayPrice }
    var purchaseError: String? { purchaseManager.purchaseError }

#if DEBUG
    var debugEntitlementOverride: OpenClientDebugEntitlementOverride {
        get { store.debugEntitlementOverride }
        set { store.debugEntitlementOverride = newValue }
    }
#endif

    var hasProUnlock: Bool {
#if DEBUG
        switch store.debugEntitlementOverride {
        case .system:
            return purchaseManager.hasProUnlock
        case .free, .limitReached:
            return false
        case .monthly, .unlocked:
            return true
        }
#else
        return purchaseManager.hasProUnlock
#endif
    }

    var hasProLifetimeUnlock: Bool {
#if DEBUG
        switch store.debugEntitlementOverride {
        case .system:
            return purchaseManager.hasProLifetimeUnlock
        case .unlocked:
            return true
        case .free, .monthly, .limitReached:
            return false
        }
#else
        return purchaseManager.hasProLifetimeUnlock
#endif
    }

    var remainingFreePromptsToday: Int {
        normalizeUsageMeter()
#if DEBUG
        if store.debugEntitlementOverride == .limitReached { return 0 }
#endif
        return max(0, OpenClientCommerceLimits.dailyPromptLimit - store.usageMeter.dailyPromptCount)
    }

    var remainingFreeSessions: Int {
        max(0, OpenClientCommerceLimits.freeSessionLimit - store.usageMeter.createdSessionCount)
    }

    var canCreateFreeSession: Bool {
        hasProUnlock || store.usageMeter.createdSessionCount < OpenClientCommerceLimits.freeSessionLimit
    }

    func hydratePersistedState(debugEntitlementRawValue: String? = nil) {
        store.usageMeter = usageStore.load()
#if DEBUG
        if let debugEntitlementRawValue,
           let value = OpenClientDebugEntitlementOverride(rawValue: debugEntitlementRawValue) {
            store.debugEntitlementOverride = value
        }
#endif
    }

    func presentPaywall(reason: OpenClientPaywallReason = .manual) {
        store.paywallReason = reason
    }

    func dismissPaywall() {
        store.paywallReason = nil
    }

    func purchasePro(_ option: OpenClientProPurchaseOption) async {
        await purchaseManager.purchasePro(option)
    }

    func restorePurchases() async {
        await purchaseManager.restorePurchases()
    }

    func reserveUserPromptIfAllowed() -> Bool {
        normalizeUsageMeter()
        guard !hasProUnlock else { return true }

#if DEBUG
        if store.debugEntitlementOverride == .limitReached {
            store.paywallReason = .promptLimit
            return false
        }
#endif

        guard store.usageMeter.dailyPromptCount < OpenClientCommerceLimits.dailyPromptLimit else {
            store.paywallReason = .promptLimit
            return false
        }

        store.usageMeter.dailyPromptCount += 1
        usageStore.save(store.usageMeter)
        return true
    }

    func refundReservedUserPromptIfNeeded() {
        guard !hasProUnlock else { return }
        normalizeUsageMeter()
        guard store.usageMeter.dailyPromptCount > 0 else { return }
        store.usageMeter.dailyPromptCount -= 1
        usageStore.save(store.usageMeter)
    }

    func canCreateSessionOrPresentPaywall() -> Bool {
        guard canCreateFreeSession else {
            store.paywallReason = .sessionLimit
            return false
        }
        return true
    }

    func recordCreatedSessionForMetering() {
        guard !hasProUnlock else { return }
        store.usageMeter.createdSessionCount += 1
        usageStore.save(store.usageMeter)
    }

#if DEBUG
    func resetDebugUsageMeter() {
        store.usageMeter = .empty
        usageStore.save(store.usageMeter)
    }
#endif

    private func normalizeUsageMeter() {
        var meter = store.usageMeter
        meter.normalize()
        if meter != store.usageMeter {
            store.usageMeter = meter
            usageStore.save(meter)
        }
    }
}
