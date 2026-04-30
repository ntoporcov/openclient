import Foundation

extension AppViewModel {
    var hasProUnlock: Bool {
#if DEBUG
        switch debugEntitlementOverride {
        case .system:
            return purchaseManager.hasProUnlock
        case .free, .limitReached:
            return false
        case .unlocked:
            return true
        }
#else
        return purchaseManager.hasProUnlock
#endif
    }

    var remainingFreePromptsToday: Int {
        normalizedUsageMeter()
#if DEBUG
        if debugEntitlementOverride == .limitReached { return 0 }
#endif
        return max(0, OpenClientCommerceLimits.dailyPromptLimit - usageMeter.dailyPromptCount)
    }

    var remainingFreeSessions: Int {
        max(0, OpenClientCommerceLimits.freeSessionLimit - usageMeter.createdSessionCount)
    }

    var canCreateFreeSession: Bool {
        hasProUnlock || usageMeter.createdSessionCount < OpenClientCommerceLimits.freeSessionLimit
    }

    func presentPaywall(reason: OpenClientPaywallReason = .manual) {
        paywallReason = reason
    }

    func purchaseProUnlock() async {
        await purchaseManager.purchaseProUnlock()
        objectWillChange.send()
    }

    func restoreProUnlock() async {
        await purchaseManager.restorePurchases()
        objectWillChange.send()
    }

    func reserveUserPromptIfAllowed() -> Bool {
        normalizedUsageMeter()
        guard !hasProUnlock else { return true }

#if DEBUG
        if debugEntitlementOverride == .limitReached {
            paywallReason = .promptLimit
            return false
        }
#endif

        guard usageMeter.dailyPromptCount < OpenClientCommerceLimits.dailyPromptLimit else {
            paywallReason = .promptLimit
            return false
        }

        usageMeter.dailyPromptCount += 1
        usageStore.save(usageMeter)
        return true
    }

    func refundReservedUserPromptIfNeeded() {
        guard !hasProUnlock else { return }
        normalizedUsageMeter()
        guard usageMeter.dailyPromptCount > 0 else { return }
        usageMeter.dailyPromptCount -= 1
        usageStore.save(usageMeter)
    }

    func canCreateSessionOrPresentPaywall() -> Bool {
        guard canCreateFreeSession else {
            paywallReason = .sessionLimit
            return false
        }
        return true
    }

    func recordCreatedSessionForMetering() {
        guard !hasProUnlock else { return }
        usageMeter.createdSessionCount += 1
        usageStore.save(usageMeter)
    }

#if DEBUG
    func resetDebugUsageMeter() {
        usageMeter = .empty
        usageStore.save(usageMeter)
    }
#endif

    private func normalizedUsageMeter() {
        var meter = usageMeter
        meter.normalize()
        if meter != usageMeter {
            usageMeter = meter
            usageStore.save(meter)
        }
    }
}
