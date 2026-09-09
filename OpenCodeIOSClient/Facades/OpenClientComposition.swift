import Foundation

@MainActor
final class OpenClientComposition: ObservableObject {
    let viewModel: AppViewModel
    let whatsNew: OpenClientWhatsNewStore
    let bridgeStore: OpenClientBridgeStore
    private let bridgeCoordinator: OpenClientBridgeCoordinator
    let bridge: OpenClientBridgeFacade
    let imageContent: OpenClientImageContentCoordinator
    let videoStreams: OpenClientVideoStreamCoordinator
    let liveActivityBackgroundBridge: LiveActivityBackgroundBridge

    var connection: ConnectionFacade { viewModel.connectionFacade }
    var appShell: AppShellFacade { viewModel.appShellFacade }
    var projectFiles: ProjectFilesFacade { viewModel.projectFilesFacade }
    var mcp: MCPFacade { viewModel.mcpFacade }
    var terminal: TerminalFacade { viewModel.terminalFacade }
    var commerce: CommerceFacade { viewModel.commerceFacade }
    var projects: ProjectFacade { viewModel.projectFacade }
    var sessions: SessionListFacade { viewModel.sessionListFacade }
    var activity: ActivityFacade { viewModel.activityFacade }
    var chat: ChatFacade { viewModel.chatFacade }
    var configurations: ConfigurationsFacade { viewModel.configurationsFacade }
    var funAndGames: FunAndGamesFacade { viewModel.funAndGamesFacade }
    var liveActivities: LiveActivityFacade { viewModel.liveActivityFacade }

    init(
        viewModel: AppViewModel? = nil,
        whatsNew: OpenClientWhatsNewStore? = nil,
        backendFactory: (any BackendFactory)? = nil
    ) {
        precondition(viewModel == nil || backendFactory == nil, "Inject a view model or a backend factory, not both")
        let viewModel = viewModel ?? AppViewModel(backendFactory: backendFactory)
        self.viewModel = viewModel
        let liveActivityBackgroundBridge = LiveActivityBackgroundBridge()
        self.liveActivityBackgroundBridge = liveActivityBackgroundBridge
        self.whatsNew = whatsNew ?? OpenClientWhatsNewStore(
            hasExistingConnection: !viewModel.connectionFacade.recentServerConfigs.isEmpty,
            checksForUpdates: ProcessInfo.processInfo.environment["OPENCODE_UI_TEST_MODE"] != "1"
        )
        let bridgeStore = OpenClientBridgeStore()
        self.bridgeStore = bridgeStore
        imageContent = OpenClientImageContentCoordinator(bridgeStore: bridgeStore)
        videoStreams = OpenClientVideoStreamCoordinator(bridgeStore: bridgeStore)
        let browserStore = viewModel.appShellFacade.browser
        let bridgeClient = OpenClientBridgeClient(
            registry: OpenClientDeviceToolRegistry(browserStore: browserStore)
        )
        let bridgeCoordinator = OpenClientBridgeCoordinator(
            store: bridgeStore,
            connectionStore: viewModel.connectionStore,
            chatStore: viewModel.chatStore,
            configProvider: { [weak viewModel] in viewModel?.compatibilityClient(for: .bridge)?.config ?? OpenCodeServerConfig() },
            client: bridgeClient
        )
        self.bridgeCoordinator = bridgeCoordinator
        bridge = OpenClientBridgeFacade(store: bridgeStore) { [weak bridgeCoordinator, weak viewModel] in
            guard viewModel?.compatibilityClient(for: .bridge) != nil else { return }
            bridgeCoordinator?.forceConnect()
        }
        viewModel.chatFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.connectionFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.sessionListFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.activityFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.liveActivityFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        // The OpenCode device bridge negotiates separately and must not contact a saved server
        // when composition was built around another harness.
        if viewModel.backendFactory == nil { bridgeCoordinator.start() }
    }
}
