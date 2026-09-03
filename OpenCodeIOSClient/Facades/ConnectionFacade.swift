import Combine
import Foundation

@MainActor
final class ConnectionFacade: ObservableObject {
    private unowned let viewModel: AppViewModel
    private weak var liveActivityBackgroundBridge: LiveActivityBackgroundBridge?
    private var observations: Set<AnyCancellable> = []
    private var activeDirectoryObservation: AnyCancellable?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        Publishers.MergeMany([
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.appCustomizationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.appIconStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.commerceFacade.objectWillChange.eraseToAnyPublisher(),
            viewModel.speechVoiceStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.funAndGamesStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.$config.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingConnectionOverlay.map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)

        bindActiveDirectoryStore(viewModel.directoryStoreRegistry.activeStore)
        viewModel.directoryStoreRegistry.$activeStore
            .dropFirst()
            .sink { [weak self] store in
                self?.bindActiveDirectoryStore(store)
                self?.objectWillChange.send()
            }
            .store(in: &observations)

        Publishers.CombineLatest(
            viewModel.commerceFacade.purchaseManager.$hasProLifetimeUnlock,
            viewModel.commerceFacade.purchaseManager.$hasRefreshedEntitlements
        )
        .filter { _, hasRefreshedEntitlements in hasRefreshedEntitlements }
        .map { hasProLifetimeUnlock, _ in hasProLifetimeUnlock }
        .removeDuplicates()
        .sink { [weak self] allowsProLifetimeIcons in
            Task { @MainActor [weak self] in
                await self?.viewModel.appIconStore.enforceLifetimeEligibility(
                    allowsProLifetimeIcons: allowsProLifetimeIcons
                )
            }
        }
        .store(in: &observations)
    }

    func attachLiveActivityBackgroundBridge(_ bridge: LiveActivityBackgroundBridge) {
        liveActivityBackgroundBridge = bridge
    }

    var config: OpenCodeServerConfig {
        get { viewModel.config }
        set { viewModel.config = newValue }
    }

    var isConnected: Bool { viewModel.isConnected }
    var isShowingConnectionOverlay: Bool { viewModel.isShowingConnectionOverlay }
    var connectionPhase: OpenClientConnectionPhase { viewModel.connectionPhase }
    var isUsingAppleIntelligence: Bool { viewModel.isUsingAppleIntelligence }
    var recentServerConfigs: [OpenCodeServerConfig] { viewModel.recentServerConfigs }
    var appIconStore: AppIconStore { viewModel.appIconStore }
    var appIcons: [OpenClientAppIcon] { viewModel.appIconStore.icons }
    var selectedAppIcon: OpenClientAppIcon { viewModel.appIconStore.selectedIcon }
    var speechVoiceStore: SpeechVoiceStore { viewModel.speechVoiceStore }
    var showsChatActivityShimmer: Bool { viewModel.appCustomizationStore.showsChatActivityShimmer }
    var showsToolCalls: Bool { viewModel.appCustomizationStore.showsToolCalls }
    var showsReasoningBlocks: Bool { viewModel.appCustomizationStore.showsReasoningBlocks }
    var showsFunAndGamesSection: Bool { viewModel.funAndGamesPreferences.showsSection }
    var autoConnectServerID: String? { viewModel.appCustomizationStore.autoConnectServerID }
    var autoConnectLandingDestination: AutoConnectLandingDestination {
        viewModel.appCustomizationStore.autoConnectLandingDestination
    }
    var isBrowsingLocalCache: Bool { viewModel.backendMode == .cachedServer }
    var isOfferingCachedServerConnection: Bool { viewModel.connectionStore.isOfferingCachedServerConnection }
    var errorMessage: String? { viewModel.errorMessage }
    var isLoading: Bool { viewModel.isLoading }
    var isEditingSavedServer: Bool { viewModel.isEditingSavedServer }
    var canSaveEditedServer: Bool { viewModel.canSaveEditedServer }

    func startConnection() {
        viewModel.startConnection()
    }

    func retryCachedServerConnection() {
        viewModel.retryCachedServerConnection()
    }

    func retryOfferedServerConnection() {
        viewModel.retryOfferedServerConnection()
    }

    func browseDownloadedServerData() {
        viewModel.browseDownloadedServerData()
    }

    func dismissCachedServerConnectionOffer() {
        viewModel.dismissCachedServerConnectionOffer()
    }

    func startConnection(to serverConfig: OpenCodeServerConfig) {
        viewModel.startConnection(to: serverConfig)
    }

    func startConnectionFromEditor() {
        viewModel.startConnectionFromEditor()
    }

    @discardableResult
    func startAutomaticConnectionIfConfigured() -> Bool {
        viewModel.startAutomaticConnectionIfConfigured()
    }

    func setShowsChatActivityShimmer(_ shows: Bool) {
        viewModel.appCustomizationStore.setShowsChatActivityShimmer(shows)
    }

    func isAppIconEnabled(_ icon: OpenClientAppIcon) -> Bool {
        !icon.requiresProLifetime || viewModel.commerceFacade.hasProLifetimeUnlock
    }

    func selectAppIcon(_ icon: OpenClientAppIcon) async {
        await viewModel.appIconStore.select(
            icon,
            allowsProLifetimeIcons: viewModel.commerceFacade.hasProLifetimeUnlock
        )
    }

    func presentProLifetimePaywall() {
        viewModel.commerceFacade.presentPaywall(reason: .manual)
    }

    func setShowsToolCalls(_ shows: Bool) {
        viewModel.appCustomizationStore.setShowsToolCalls(shows)
    }

    func setShowsReasoningBlocks(_ shows: Bool) {
        viewModel.appCustomizationStore.setShowsReasoningBlocks(shows)
    }

    func setShowsFunAndGamesSection(_ shows: Bool) {
        viewModel.setShowsFunAndGamesSection(shows)
    }

    func setAutoConnectServerID(_ serverID: String?) {
        viewModel.appCustomizationStore.setAutoConnectServerID(serverID)
    }

    func setAutoConnectLandingDestination(_ destination: AutoConnectLandingDestination) {
        viewModel.appCustomizationStore.setAutoConnectLandingDestination(destination)
    }

    func cancelConnectionAttempt() {
        viewModel.cancelConnectionAttempt()
    }

    func presentAddServerSheet() {
        viewModel.presentAddServerSheet()
    }

    func prepareToEditRecentServer(_ serverConfig: OpenCodeServerConfig) {
        viewModel.prepareToEditRecentServer(serverConfig)
    }

    func removeRecentServer(_ serverConfig: OpenCodeServerConfig) {
        viewModel.removeRecentServer(serverConfig)
    }

    func saveEditedServer() {
        viewModel.saveEditedServer()
    }

    func disconnect() {
        liveActivityBackgroundBridge?.cancelAll(reason: "Disconnected")
        viewModel.disconnect()
    }

    private func bindActiveDirectoryStore(_ store: DirectoryStore) {
        activeDirectoryObservation = store.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
    }
}
