import Combine
import XCTest
@testable import OpenClient

private final class ManagedMCPUnexpectedRequestProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("MCP requests require a current writable server context and known API profile")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}

@MainActor
private final class ManagedMCPTestService: BackendMCPService {
    @Published var state = BackendMCPState()
    var statePublisher: AnyPublisher<BackendMCPState, Never> { $state.eraseToAnyPublisher() }
    var refreshCount = 0
    var writes: [(String, Bool)] = []
    func refresh() async { refreshCount += 1 }
    func setEnabled(id: String, enabled: Bool) async { writes.append((id, enabled)) }
}

@MainActor
private final class ManagedMCPTestContext {
    var connection: BackendConnection?
    var isCurrent = true
    var directory = "/project-a"
    var workspaceID = "workspace-a"
    var contextID = "navigation-1"
    let changes = PassthroughSubject<Void, Never>()
    init(connection: BackendConnection) { self.connection = connection }
    func facade(store: MCPStore = MCPStore()) -> MCPFacade {
        MCPFacade(store: store, clientProvider: { nil }, directoryProvider: { [weak self] in self?.directory },
                  workspaceIDProvider: { [weak self] in self?.workspaceID }, contextIDProvider: { [weak self] in self?.contextID },
                  connectionProvider: { [weak self] in self?.isCurrent == true ? self?.connection : nil },
                  contextChanges: changes.eraseToAnyPublisher())
    }
}

@MainActor
final class ManagedMCPFacadeTests: XCTestCase {
    func testUnchangedManagedContextDoesNotRelayUnrelatedRootNotifications() async {
        let service = makeService()
        let context = ManagedMCPTestContext(connection: connection(service))
        let facade = context.facade()
        _ = facade.snapshot
        await drainMainQueue() // consume the initial shared-service publisher value
        var notifications = 0
        let observation = facade.objectWillChange.sink { notifications += 1 }
        context.changes.send()
        context.changes.send()
        await drainMainQueue()
        XCTAssertEqual(notifications, 0)
        service.state.notice = "Restart required"
        await drainMainQueue()
        XCTAssertGreaterThan(notifications, 0, "Canonical service updates still reach presentation")
        withExtendedLifetime(observation) {}
    }

    func testPureLegacyContextDoesNotAddDeferredObservationRelays() async {
        let context = ManagedMCPTestContext(connection: connection(makeService()))
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig())
        let facade = MCPFacade(store: MCPStore(), clientProvider: { client },
                               directoryProvider: { context.directory }, contextIDProvider: { context.contextID },
                               connectionProvider: { nil }, contextChanges: context.changes.eraseToAnyPublisher())
        var notifications = 0
        let observation = facade.objectWillChange.sink { notifications += 1 }
        context.changes.send()
        context.directory = "/legacy-other"
        context.contextID = "legacy-navigation-2"
        context.changes.send()
        await drainMainQueue()
        XCTAssertEqual(notifications, 0, "Legacy stores/parent facades retain their existing observation timing")
        XCTAssertTrue(facade.isAvailable)
        withExtendedLifetime(observation) {}
    }

    func testManagedContextInvalidationPublishesWithoutParentViewRead() async {
        let context = ManagedMCPTestContext(connection: connection(makeService()))
        let facade = context.facade()
        _ = facade.snapshot
        await drainMainQueue()
        var notifications = 0
        let observation = facade.objectWillChange.sink { notifications += 1 }
        context.isCurrent = false
        context.changes.send()
        await drainMainQueue()
        XCTAssertGreaterThan(notifications, 0)
        XCTAssertFalse(facade.isAvailable)
        XCTAssertEqual(facade.snapshot.managed?.servers, [])
        withExtendedLifetime(observation) {}
    }

    private func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    func testLegacyPresentationSurvivesUnknownProfileWithoutDispatchingRequests() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagedMCPUnexpectedRequestProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(), session: session)
        for hasConnectionProvider in [false, true] {
            let store = MCPStore(statuses: ["legacy": .init(status: "connected", error: nil)], isReady: true)
            let facade = MCPFacade(store: store, clientProvider: { client }, directoryProvider: { "/legacy" },
                                   apiProfileProvider: { nil },
                                   connectionProvider: hasConnectionProvider ? { nil } : nil)
            XCTAssertTrue(facade.isAvailable)
            XCTAssertNil(facade.snapshot.managed)
            XCTAssertEqual(facade.snapshot.connectedServerCount, 1)
            await facade.reload()
            await facade.toggleServer(name: "legacy")
            XCTAssertEqual(facade.snapshot.connectedServerCount, 1)
            XCTAssertFalse(facade.snapshot.isLoading)
            XCTAssertNil(facade.snapshot.errorMessage)
        }
    }

    func testRootAndWindowLegacyFacadesRejectReadonlyModesWithRetainedProfile() async {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ManagedMCPUnexpectedRequestProtocol.self]
        let transport = URLSession(configuration: configuration)
        defer { transport.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig(), session: transport)
        for mode in [AppBackendMode.cachedServer, .appleIntelligence] {
            let model = AppViewModel(backendFactory: HomeTestBackend())
            let connection = OpenCodeBackendFactory(client: client, eventManager: model.eventManager)
                .makeConnection(profile: .legacy, version: "test", healthy: true)
            model.backendConnection = connection
            model.isConnected = true
            model.connectionStore.apiProfile = .legacy
            model.connectionStore.backendMode = .server
            let session = OpenCodeSession(id: "readonly-mcp", title: "MCP", workspaceID: nil,
                                          directory: "/project-a", projectID: "project-a", parentID: nil)
            let owner = model.directoryStoreRegistry.store(for: session.directory)
            owner.upsertSessions([session])
            let window = ChatWindowContext(model: model, connection: connection, session: session, owner: owner)
            let facades = [model.mcpFacade, window.mcpFacade]
            XCTAssertTrue(facades.allSatisfy { $0.isAvailable })
            model.connectionStore.backendMode = mode
            XCTAssertEqual(model.connectionStore.apiProfile, .legacy)
            for facade in facades {
                XCTAssertFalse(facade.isAvailable)
                await facade.reload()
                await facade.toggleServer(name: "legacy")
                XCTAssertTrue(facade.snapshot.servers.isEmpty)
                XCTAssertNil(facade.snapshot.errorMessage)
            }
            window.close()
        }
    }

    func testEffectiveEnabledAndLifecycleRemainIndependentOfOCConnectivity() {
        let service = makeService()
        let context = ManagedMCPTestContext(connection: connection(service))
        let facade = context.facade()
        for phase in [BackendMCPPluginPhase.pending, .failed, .active] {
            service.state.servers = [row(phase: phase)]
            XCTAssertEqual(facade.snapshot.managed?.servers.first?.enabled, true)
            XCTAssertEqual(facade.snapshot.managed?.servers.first?.phase, phase)
            XCTAssertEqual(facade.snapshot.connectedServerCount, 0)
            XCTAssertTrue(facade.snapshot.servers.isEmpty)
        }
    }

    func testEveryManagedEntryRefreshesEvenWhenLegacyStoreIsReady() async {
        let service = makeService()
        let context = ManagedMCPTestContext(connection: connection(service))
        let facade = context.facade(store: MCPStore(isReady: true))
        await facade.loadIfNeeded()
        await facade.loadIfNeeded()
        XCTAssertEqual(service.refreshCount, 2)
        await facade.toggleServer(name: "stock-mcp")
        XCTAssertTrue(service.writes.isEmpty, "Legacy toggle route must not bypass profile confirmation")
    }

    func testConfirmationCapturesExplicitGlobalScopeAndDesiredValue() async throws {
        let service = makeService()
        let connection = connection(service)
        let context = ManagedMCPTestContext(connection: connection)
        let facade = context.facade()
        let request = try XCTUnwrap(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
        XCTAssertEqual(request.connectionID, connection.id)
        XCTAssertEqual(request.contextID, "navigation-1")
        XCTAssertEqual(request.directory, "/project-a")
        XCTAssertEqual(request.workspaceID, "workspace-a")
        XCTAssertEqual(request.scope, .profile)
        XCTAssertFalse(request.enabled)
        XCTAssertTrue(String(localized: request.confirmationMessage).contains("all projects, chats, and users"))
        XCTAssertTrue(service.writes.isEmpty, "Preparing/canceling confirmation has no side effect")
        await facade.confirmManagedToggle(request)
        XCTAssertEqual(service.writes.count, 1)
        XCTAssertEqual(service.writes.first?.0, "profile:mcp")
        XCTAssertEqual(service.writes.first?.1, false)
        await facade.confirmManagedToggle(request)
        XCTAssertEqual(service.writes.count, 1, "A consumed confirmation cannot replay")
    }

    func testNavigationAndWorkspaceChangesInvalidateConfirmation() async throws {
        for change in 0..<3 {
            let service = makeService()
            let context = ManagedMCPTestContext(connection: connection(service))
            let facade = context.facade()
            let request = try XCTUnwrap(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
            switch change {
            case 0: context.contextID = "navigation-2"
            case 1: context.directory = "/project-b"
            default: context.workspaceID = "workspace-b"
            }
            await facade.confirmManagedToggle(request)
            XCTAssertTrue(service.writes.isEmpty)
        }
    }

    func testReconnectionCannotRetargetCapturedRequestEvenWithSameDescriptor() async throws {
        let oldService = makeService(), newService = makeService()
        let context = ManagedMCPTestContext(connection: connection(oldService))
        let facade = context.facade()
        let request = try XCTUnwrap(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
        context.connection = connection(newService)
        await facade.confirmManagedToggle(request)
        XCTAssertTrue(oldService.writes.isEmpty)
        XCTAssertTrue(newService.writes.isEmpty)
    }

    func testReadonlyOrClosedContextDoesNotReadWriteOrExposeOldServers() async throws {
        for close in [false, true] {
            let service = makeService()
            let connection = connection(service)
            let context = ManagedMCPTestContext(connection: connection)
            let facade = context.facade()
            let request = try XCTUnwrap(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
            if close { connection.close() } else { context.isCurrent = false }
            XCTAssertFalse(facade.isAvailable)
            XCTAssertEqual(facade.snapshot.managed?.isCurrent, false)
            XCTAssertEqual(facade.snapshot.managed?.servers, [])
            await facade.reload()
            await facade.confirmManagedToggle(request)
            XCTAssertEqual(service.refreshCount, 0)
            XCTAssertTrue(service.writes.isEmpty)
        }
    }

    func testCapabilityRequiredEvenWhenServicePresent() async {
        let service = makeService()
        let context = ManagedMCPTestContext(connection: connection(service, capabilities: []))
        let facade = context.facade()
        XCTAssertFalse(facade.isAvailable)
        XCTAssertNil(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
        await facade.reload()
        XCTAssertEqual(service.refreshCount, 0)
    }

    func testRestrictionsAndConditionalPresetsNeverOfferConfirmation() {
        let service = makeService()
        let context = ManagedMCPTestContext(connection: connection(service))
        let facade = context.facade()
        for restriction in [BackendMCPRestriction.managementUnavailable, .unaddressable, .preset] {
            service.state.servers = [row(restriction: restriction)]
            XCTAssertNil(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
        }
        service.state.servers = [.init(id: "preset:mcp", name: "stock-mcp", enabled: nil, phase: nil,
                                     scope: .agentPreset(id: "plan", name: "Plan"), canToggle: false, restriction: .preset)]
        XCTAssertNil(facade.captureManagedToggle(id: "preset:mcp", enabled: true))
        XCTAssertNil(facade.snapshot.managed?.servers.first?.enabled)
    }

    func testUnknownAndChangedStateRejectStaleConfirmation() async throws {
        let service = makeService()
        let context = ManagedMCPTestContext(connection: connection(service))
        let facade = context.facade()
        let request = try XCTUnwrap(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
        service.state.isCurrent = false
        XCTAssertEqual(facade.snapshot.managed?.servers, [])
        await facade.confirmManagedToggle(request)
        service.state.isCurrent = true
        service.state.servers = [row(enabled: false)]
        await facade.confirmManagedToggle(request)
        XCTAssertTrue(service.writes.isEmpty)
    }

    func testSameProfileWindowsObserveSharedServiceWithoutSharedOCStore() async {
        let service = makeService()
        let connection = connection(service)
        let first = ManagedMCPTestContext(connection: connection)
        let second = ManagedMCPTestContext(connection: connection)
        second.contextID = "other-window"; second.directory = "/other-project"
        let a = first.facade(), b = second.facade()
        XCTAssertEqual(a.snapshot.managed, b.snapshot.managed)
        var subscriptions: Set<AnyCancellable> = []
        let ready = expectation(description: "Initial publisher values delivered")
        ready.expectedFulfillmentCount = 2
        a.objectWillChange.first().sink { ready.fulfill() }.store(in: &subscriptions)
        b.objectWillChange.first().sink { ready.fulfill() }.store(in: &subscriptions)
        await fulfillment(of: [ready], timeout: 2)
        let changed = expectation(description: "Shared profile publisher reaches both facades")
        changed.expectedFulfillmentCount = 2
        a.objectWillChange.first().sink { changed.fulfill() }.store(in: &subscriptions)
        b.objectWillChange.first().sink { changed.fulfill() }.store(in: &subscriptions)
        service.state.servers = [row(enabled: false, phase: .unloading)]
        await fulfillment(of: [changed], timeout: 2)
        XCTAssertEqual(a.snapshot.managed?.servers.first?.enabled, false)
        XCTAssertEqual(a.snapshot.managed, b.snapshot.managed)
    }

    func testConnectionRebindAndLateOldServiceCannotLeakAcrossServers() async {
        let old = makeService(), new = makeService()
        new.state.servers = [row(name: "other-profile", enabled: false)]
        let context = ManagedMCPTestContext(connection: connection(old))
        let facade = context.facade()
        XCTAssertEqual(facade.snapshot.managed?.servers.first?.name, "stock-mcp")
        let changed = expectation(description: "Connection change triggers rebind")
        let subscription = facade.objectWillChange.first().sink { changed.fulfill() }
        context.connection = connection(new)
        context.changes.send()
        await fulfillment(of: [changed], timeout: 2)
        old.state.errorMessage = "Old server error"
        XCTAssertEqual(facade.snapshot.managed?.servers.first?.name, "other-profile")
        XCTAssertNil(facade.snapshot.errorMessage)
        withExtendedLifetime(subscription) {}
    }

    func testErrorNoticeAndResetRetainConnectionOwnedTruth() async throws {
        let service = makeService()
        let context = ManagedMCPTestContext(connection: connection(service))
        let facade = context.facade()
        let request = try XCTUnwrap(facade.captureManagedToggle(id: "profile:mcp", enabled: false))
        service.state.errorMessage = "Refresh failed"
        service.state.notice = "Restart required"
        facade.reset()
        XCTAssertEqual(facade.snapshot.errorMessage, "Refresh failed")
        XCTAssertEqual(facade.snapshot.managed?.notice, "Restart required")
        XCTAssertEqual(facade.snapshot.managed?.servers.count, 1)
        await facade.confirmManagedToggle(request)
        XCTAssertTrue(service.writes.isEmpty)
    }

    func testDefaultInitializerKeepsLegacyOCSnapshotAndReadiness() async {
        let store = MCPStore(statuses: ["legacy": .init(status: "connected", error: nil)], isReady: true)
        let client = OpenCodeAPIClient(config: OpenCodeServerConfig())
        let facade = MCPFacade(store: store, clientProvider: { client }, directoryProvider: { "/legacy" })
        XCTAssertTrue(facade.isAvailable)
        XCTAssertNil(facade.snapshot.managed)
        XCTAssertEqual(facade.snapshot.connectedServerCount, 1)
        XCTAssertEqual(facade.snapshot.servers.first?.name, "legacy")
        await facade.loadIfNeeded() // ready store: no network request
        XCTAssertEqual(facade.snapshot.connectedServerCount, 1)
    }

    func testWindowFacadeInvalidationAndProjectCapabilityUseManagedService() async throws {
        let backend = HomeTestBackend()
        let service = makeService()
        let connection = connection(service)
        let model = AppViewModel(backendFactory: backend)
        model.backendConnection = connection
        model.isConnected = true
        let shell = AppShellFacade(viewModel: model)
        XCTAssertTrue(shell.projectContentSnapshot.availableTabs.contains(.mcp))
        let session = OpenCodeSession(id: "mcp-window", title: "MCP", workspaceID: nil,
                                      directory: "/project-a", projectID: "project-a", parentID: nil)
        let owner = model.directoryStoreRegistry.store(for: session.directory)
        owner.upsertSessions([session])
        let window = ChatWindowContext(model: model, connection: connection, session: session, owner: owner)
        defer { window.close() }
        let chat = ChatFacade(viewModel: model, windowContext: window)
        XCTAssertTrue(chat.isMCPAvailable)
        let request = try XCTUnwrap(chat.mcpFacade.captureManagedToggle(id: "profile:mcp", enabled: false))
        window.close()
        XCTAssertFalse(chat.isMCPAvailable)
        await chat.mcpFacade.reload()
        await chat.mcpFacade.confirmManagedToggle(request)
        XCTAssertEqual(service.refreshCount, 0)
        XCTAssertTrue(service.writes.isEmpty)
        XCTAssertEqual(chat.mcpFacade.snapshot.managed?.servers, [])
        let rootRequest = try XCTUnwrap(model.mcpFacade.captureManagedToggle(id: "profile:mcp", enabled: false))
        model.connectionStore.backendMode = .cachedServer
        XCTAssertFalse(shell.projectContentSnapshot.availableTabs.contains(.mcp))
        await model.mcpFacade.reload()
        await model.mcpFacade.confirmManagedToggle(rootRequest)
        XCTAssertEqual(service.refreshCount, 0)
        XCTAssertTrue(service.writes.isEmpty, "Header/project direct facade cannot bypass readonly mode")
    }

    private func connection(_ service: ManagedMCPTestService, capabilities: Set<BackendCapability> = [.mcp]) -> BackendConnection {
        let backend = HomeTestBackend()
        return BackendConnection(descriptor: .init(id: "dsh:profile", name: "DSH", version: "test"),
                                 capabilities: capabilities, projects: backend, sessions: backend, chat: backend,
                                 models: backend, events: backend, mcp: service)
    }

    private func makeService() -> ManagedMCPTestService {
        let service = ManagedMCPTestService()
        service.state = .init(servers: [row()], isCurrent: true)
        return service
    }

    private func row(name: String = "stock-mcp", enabled: Bool = true, phase: BackendMCPPluginPhase = .pending,
                     restriction: BackendMCPRestriction? = nil) -> BackendMCPServer {
        .init(id: "profile:mcp", name: name, enabled: enabled, phase: phase, scope: .profile, canToggle: true, restriction: restriction)
    }
}
