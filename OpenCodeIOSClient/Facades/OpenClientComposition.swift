import Combine
import Foundation

@MainActor
final class OpenClientComposition: ObservableObject {
    let viewModel: AppViewModel
    let whatsNew: OpenClientWhatsNewStore
    let bridgeStore: OpenClientBridgeStore
    private let bridgeCoordinator: OpenClientBridgeCoordinator
    private var observations: Set<AnyCancellable> = []
    let bridge: OpenClientBridgeFacade
    let imageContent: OpenClientImageContentCoordinator
    let videoStreams: OpenClientVideoStreamCoordinator
    let liveActivityBackgroundBridge: LiveActivityBackgroundBridge
    let dshConnection: DSHConnectionCoordinator?

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
        var resolvedFactory = backendFactory
#if DSH_CLIENT
        // A DSH app must never fall back to an OpenCode connection, including Release.
        let dsh = viewModel == nil && backendFactory == nil ? DSHConnectionCoordinator() : nil
        self.dshConnection = dsh
        if let dsh { resolvedFactory = dsh }
#elseif DEBUG
        self.dshConnection = nil
        let prototype = viewModel == nil && backendFactory == nil ? DSHPrototypeFactory.fromEnvironment() : nil
        if let prototype { resolvedFactory = prototype }
#else
        self.dshConnection = nil
#endif
        let viewModel = viewModel ?? AppViewModel(backendFactory: resolvedFactory)
        self.viewModel = viewModel
        dshConnection?.attach(viewModel.connectionFacade)
        viewModel.connectionFacade.dshConnection = dshConnection
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
             configProvider: { [weak viewModel] in viewModel?.compatibilityClient(for: .bridge)?.config },
            client: bridgeClient,
            notificationPairingRunner: OpenClientNotificationPairingRunner(
                clientProvider: { [weak viewModel] in viewModel?.compatibilityClient(for: .terminal) },
                directoryProvider: { [weak viewModel] in viewModel?.effectiveTerminalDirectory },
                apiProfileProvider: { [weak viewModel] in
                    viewModel?.backendConnection?.openCodeCompatibility?.profile
                },
                workspaceIDProvider: { [weak viewModel] in viewModel?.effectiveTerminalWorkspaceID }
            ),
            notificationContextProvider: { [weak viewModel] in
                guard let viewModel,
                      viewModel.connectionStore.isConnected,
                      let connection = viewModel.backendConnection,
                      !connection.isClosed,
                      let adapter = connection.openCodeCompatibility,
                      viewModel.connectionStore.recentServerConfigs.contains(where: {
                          $0.recentServerID == adapter.client.config.recentServerID
                      }) else { return nil }
                return try? OpenClientNotificationSetupContext(
                    connectionID: connection.id.uuidString,
                    config: adapter.client.config,
                    profile: adapter.profile,
                    savedServerID: adapter.client.config.recentServerID
                )
            }
        )
        self.bridgeCoordinator = bridgeCoordinator
        bridge = OpenClientBridgeFacade(
            store: bridgeStore,
            forceConnect: { [weak bridgeCoordinator, weak viewModel] in
                guard viewModel?.compatibilityClient(for: .bridge) != nil else { return }
                bridgeCoordinator?.forceConnect()
            },
            setupNotifications: { [weak bridgeCoordinator] in
                await bridgeCoordinator?.setupNotifications()
            },
            configureNotifications: { [weak viewModel] in
                guard let viewModel else { return false }
                return try await OpenClientNotificationConfigurationCoordinator.start(using: viewModel)
            },
            notificationOpenRequest: { [weak bridgeCoordinator] in
                bridgeCoordinator?.notificationOpenRequest()
            },
            notificationBrowserOpenFailed: { [weak bridgeCoordinator] request in
                bridgeCoordinator?.notificationBrowserOpenFailed(request: request)
            }
        )
        let backendContextPublisher: AnyPublisher<(UUID?, OpenCodeServerConfig?), Never> =
            viewModel.$backendConnection
            .map { connection -> (UUID?, OpenCodeServerConfig?) in
                let connectionID = connection?.id
                let config = connection?.openCodeCompatibility?.client.config
                return (connectionID, config)
            }
            .eraseToAnyPublisher()
        backendContextPublisher
            .removeDuplicates { $0.0 == $1.0 && $0.1 == $1.1 }
            .receive(on: DispatchQueue.main)
            .sink { [weak bridgeCoordinator] connectionID, config in
                bridgeCoordinator?.backendContextChanged(connectionID: connectionID, config: config)
            }
            .store(in: &observations)
        viewModel.chatFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.connectionFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.sessionListFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.activityFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        viewModel.liveActivityFacade.attachLiveActivityBackgroundBridge(liveActivityBackgroundBridge)
        // The OpenCode device bridge negotiates separately and must not contact a saved server
        // when composition was built around another harness.
        if viewModel.backendFactory == nil { bridgeCoordinator.start() }
#if DEBUG && !DSH_CLIENT
        if prototype != nil {
            Task { [weak viewModel] in await viewModel?.connectionFacade.connect() }
        }
#endif
    }
}
