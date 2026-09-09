import Foundation
import Observation

@MainActor
@Observable
final class V2ProviderStore {
    var integrations: [OpenCodeV2Integration] = []
    var isLoading = false
    var isReady = false
    var discoveryErrorMessage: String?
    var isBusy = false
    var errorMessage: String?
    var attempt: OpenCodeV2OAuthAttempt?
    var attemptIntegrationID: String?
    var attemptStatus: OpenCodeV2OAuthStatus.Status?
    var didConnect = false
    @ObservationIgnored var generation = UUID()
    @ObservationIgnored var discoveryRequestID = UUID()
    @ObservationIgnored var context: V2ConfigurationContext?
    @ObservationIgnored var operationTask: Task<Void, Never>?
    @ObservationIgnored var pollingTask: Task<Void, Never>?

    func stopAttempt() {
        generation = UUID()
        discoveryRequestID = UUID()
        operationTask?.cancel()
        pollingTask?.cancel()
        operationTask = nil
        pollingTask = nil
        attempt = nil
        attemptIntegrationID = nil
        attemptStatus = nil
        isBusy = false
        isLoading = false
        didConnect = false
        errorMessage = nil
    }

    func reset() {
        stopAttempt()
        context = nil
        integrations = []
        isLoading = false
        isReady = false
        discoveryErrorMessage = nil
    }
}
