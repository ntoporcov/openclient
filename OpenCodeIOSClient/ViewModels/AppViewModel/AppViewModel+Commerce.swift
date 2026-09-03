import Foundation

extension AppViewModel {
    var hasProUnlock: Bool { commerceFacade.hasProUnlock }
    var remainingFreePromptsToday: Int { commerceFacade.remainingFreePromptsToday }
    var remainingFreeSessions: Int { commerceFacade.remainingFreeSessions }
    var canCreateFreeSession: Bool { commerceFacade.canCreateFreeSession }

    func presentPaywall(reason: OpenClientPaywallReason = .manual) {
        commerceFacade.presentPaywall(reason: reason)
    }

    func reserveUserPromptIfAllowed() -> Bool {
        commerceFacade.reserveUserPromptIfAllowed()
    }

    func refundReservedUserPromptIfNeeded() {
        commerceFacade.refundReservedUserPromptIfNeeded()
    }

    func canCreateSessionOrPresentPaywall() -> Bool {
        commerceFacade.canCreateSessionOrPresentPaywall()
    }

    func recordCreatedSessionForMetering() {
        commerceFacade.recordCreatedSessionForMetering()
    }

#if DEBUG
    func resetDebugUsageMeter() {
        commerceFacade.resetDebugUsageMeter()
    }
#endif
}
