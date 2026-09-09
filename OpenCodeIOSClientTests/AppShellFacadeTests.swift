import Combine
import XCTest
@testable import OpenClient

@MainActor
final class HomeTestBackend: BackendFactory, BackendProjectsService, BackendSessionsService, BackendChatService, BackendModelsService, BackendEventSource {
    var projectLoads = 0
    var listScopes: [BackendScope] = []
    var searchScopes: [BackendScope] = []
    var beforeSearch: (@MainActor () async -> Void)?
    var beforeSessionFetch: (@MainActor () async -> Void)?
    var beforeTranscript: (@MainActor () async -> Void)?
    var transcriptLoads = 0
    var catalog = BackendModelCatalog()
    var admissionResult: (@MainActor (BackendSubmission) throws -> BackendAdmission)?
    var submissions: [BackendSubmission] = []
    var receive: (@MainActor (BackendEvent) -> Void)?
    var storedSessions = [OpenCodeSession(id: "home-session", title: "Recent chat", workspaceID: nil,
        directory: "/home-project", projectID: "home-project", parentID: nil)]

    func connect() async throws -> BackendConnection {
        BackendConnection(descriptor: .init(id: "home-test", name: "Home Test", version: "1"),
            projects: self, sessions: self, chat: self, models: self, events: self)
    }

    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        projectLoads += 1
        return .init(projects: [
            .init(id: "global", worktree: "/", vcs: nil, name: "Global", sandboxes: nil, icon: nil, time: nil),
            .init(id: "home-project", worktree: "/home-project", vcs: nil, name: "Home", sandboxes: ["/home-sandbox"], icon: nil, time: nil),
        ], defaultDirectory: "/execution-default")
    }

    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        listScopes.append(scope)
        return .init(sessions: Array(storedSessions.filter { $0.directory == scope.directory }.prefix(limit)))
    }

    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        await beforeSessionFetch?()
        return try XCTUnwrap(storedSessions.first { $0.id == id })
    }

    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        let session = OpenCodeSession(id: "created-home-session", title: request.title, workspaceID: request.scope.workspaceID,
            directory: request.scope.directory, projectID: request.scope.projectID, parentID: nil)
        storedSessions.append(session)
        return session
    }

    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession {
        let previous = try await session(id: id, scope: scope)
        let renamed = OpenCodeSession(id: id, title: title, workspaceID: previous.workspaceID,
            directory: previous.directory, projectID: previous.projectID, parentID: previous.parentID)
        storedSessions = storedSessions.map { $0.id == id ? renamed : $0 }
        return renamed
    }

    func deleteSession(id: String, scope: BackendScope) async throws { storedSessions.removeAll { $0.id == id } }

    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] {
        searchScopes.append(scope)
        await beforeSearch?()
        guard scope.directory == "/home-project" else { return [] }
        return [.init(id: "search-only", title: "Archived title search hit", workspaceID: nil,
            directory: scope.directory, projectID: scope.projectID, parentID: nil)]
    }

    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        transcriptLoads += 1
        await beforeTranscript?()
        return .init(messages: [.local(role: "assistant", text: "Backend preview", messageID: "home-answer", sessionID: sessionID)])
    }

    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        submissions.append(request)
        return try admissionResult?(request) ?? .accepted(sessionID: request.sessionID, messageID: request.messageID)
    }

    func interrupt(sessionID: String, scope: BackendScope) async throws {
        receive?(.mutation(directory: scope.directory, event: .sessionIdle(sessionID: sessionID)))
    }

    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog { catalog }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { self.receive = receive }
    func stop() { receive = nil }
}

private final class HomePromptUsageStore: OpenClientUsagePersisting {
    var meter = OpenClientUsageMeter(promptDay: OpenClientUsageMeter.dayString(for: Date()), dailyPromptCount: 3, createdSessionCount: 0)
    func load() -> OpenClientUsageMeter { meter }
    func save(_ meter: OpenClientUsageMeter) { self.meter = meter }
}

private final class HomeSelectionV2URLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body: String
        switch request.url?.path {
        case "/api/session/active": body = #"{"data":{}}"#
        case "/api/session/home-session/permission", "/api/session/home-session/form": body = #"{"data":[]}"#
        default:
            XCTFail("Unexpected request during home selection: \(request.url?.path ?? "")")
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor
final class AppShellFacadeTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: OpenClientStorageKey.messageDraftsByChat)
        super.tearDown()
    }

    func testPrimarySheetGivesNewProjectChatPrecedenceOverConnection() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let requestID = UUID()

        XCTAssertEqual(shell.primarySheet, .connection)

        viewModel.newProjectChatSheetRequest = NewProjectChatSheetRequest(
            id: requestID,
            projectID: nil,
            workspaceDirectory: nil,
            locksProject: false,
            composerSelection: nil
        )

        guard case let .newProjectChat(request)? = shell.primarySheet else {
            return XCTFail("Expected new-project chat to take precedence")
        }
        XCTAssertEqual(request.id, requestID)

        shell.dismissPrimarySheet()
        XCTAssertEqual(shell.primarySheet, .connection)
    }

    func testAppleIntelligenceCanPresentConnectionContentWithoutDisconnectedBackdrop() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade

        viewModel.isConnected = true
        viewModel.backendMode = .appleIntelligence

        XCTAssertEqual(shell.primarySheet, .connection)
        XCTAssertTrue(shell.showsConnectionSheetContent)
        XCTAssertFalse(shell.hidesShellForConnectionExperience)

        viewModel.backendMode = .none
        viewModel.isConnected = false

        XCTAssertEqual(shell.primarySheet, .connection)
        XCTAssertTrue(shell.hidesShellForConnectionExperience)
    }

    func testCachedRetryStartsVisibleConnectionAttempt() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        viewModel.backendMode = .cachedServer

        shell.retryCachedServerConnection()

        XCTAssertTrue(viewModel.isShowingConnectionOverlay)
        XCTAssertNotNil(viewModel.connectionAttemptTask)
        XCTAssertNotNil(viewModel.connectionAttemptID)
        viewModel.cancelConnectionAttempt()
    }

    func testCachedConnectionOfferKeepsShellGatedUntilUserAccepts() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        viewModel.connectionStore.applyConnectionFailure(OpenCodeAPIError.timedOut)
        viewModel.connectionStore.offerCachedServerConnection()

        XCTAssertTrue(shell.connection.isOfferingCachedServerConnection)
        XCTAssertFalse(shell.isBrowsingLocalCache)
        XCTAssertEqual(shell.primarySheet, .connection)
        XCTAssertTrue(shell.hidesShellForConnectionExperience)

        shell.connection.browseDownloadedServerData()

        XCTAssertFalse(shell.connection.isOfferingCachedServerConnection)
        XCTAssertTrue(shell.isBrowsingLocalCache)
        XCTAssertNil(shell.primarySheet)
        XCTAssertFalse(shell.hidesShellForConnectionExperience)
    }

    func testDismissingCachedConnectionOfferReturnsToServerSelection() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        viewModel.connectionStore.applyConnectionFailure(OpenCodeAPIError.timedOut)
        viewModel.connectionStore.offerCachedServerConnection()

        shell.connection.dismissCachedServerConnectionOffer()

        XCTAssertFalse(shell.connection.isOfferingCachedServerConnection)
        XCTAssertFalse(shell.isBrowsingLocalCache)
        XCTAssertEqual(shell.primarySheet, .connection)
        XCTAssertEqual(viewModel.errorMessage, OpenCodeAPIError.timedOut.localizedDescription)
    }

    func testConnectedV2UsesDedicatedShellState() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade

        viewModel.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17055", healthy: true)

        XCTAssertTrue(shell.isV2Connection)
        XCTAssertNil(shell.primarySheet)
        XCTAssertFalse(shell.hidesShellForConnectionExperience)
        XCTAssertEqual(shell.connection.serverVersion, "0.0.0-next-17055")
        XCTAssertEqual(shell.projectContentSnapshot.availableTabs, [.sessions, .mcp])
        XCTAssertFalse(shell.projectContentSnapshot.isReadOnly)
        XCTAssertTrue(shell.projectContentSnapshot.allowsSessionCreation)
        XCTAssertTrue(shell.projectContentSnapshot.showsToolbarAction(usesNativeComposeTab: false))

        let session = makeSession()
        viewModel.selectedSession = session
        XCTAssertEqual(shell.detailRoute(isCompact: true), .loadingChat(sessionID: session.id))
        XCTAssertFalse(shell.canPresentSelectedSessionDetail)
    }

    func testV2SessionSelectionRoutesFromLoadingToWritableChat() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let session = makeSession()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17055", healthy: true)
        _ = try? viewModel.requireBackendConnection()
        viewModel.allSessions = [session]

        let ticket = shell.sessions.beginSelection(session)
        XCTAssertEqual(viewModel.selectedSession, session)
        XCTAssertNil(viewModel.chatStore.preparedSessionID)
        XCTAssertEqual(shell.detailRoute(isCompact: true), .loadingChat(sessionID: session.id))

        viewModel.chatStore.applyInitialV2Transcript([], olderCursor: nil, sessionID: session.id)

        XCTAssertEqual(
            shell.detailRoute(isCompact: true),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: viewModel.chatDetailPresentationRequest))
        )
        XCTAssertFalse(viewModel.chatFacade.isReadOnly)
        withExtendedLifetime(ticket) {}
    }

    func testV2RecentOpenKeepsCanonicalHydrationReadyWhenSelectionCompletesConcurrently() async throws {
        for preparesInUI in [false, true] {
            for hydratesConcurrently in [false, true] {
                let backend = HomeTestBackend()
                backend.catalog = .init(
                    agents: [.init(name: "build", description: nil, mode: "primary", hidden: false, model: nil, variant: nil)],
                    providers: [.init(id: "recent-test", name: "Recent Test", models: ["model": .init(id: "model", providerID: "recent-test", name: "Model", capabilities: .init(reasoning: false))])],
                    defaults: ["recent-test": "model"]
                )
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [HomeSelectionV2URLProtocol.self]
                let transport = URLSession(configuration: configuration)
                let viewModel = AppViewModel(backendFactory: backend)
                viewModel.config = .init(baseURL: "https://recent-selection.invalid", password: "test")
                let adapter = OpenCodeBackendAdapter(client: .init(config: viewModel.config, session: transport), profile: .v2)
                viewModel.backendConnection = BackendConnection(descriptor: .init(id: "recent-selection", name: "OpenCode", version: "next"),
                    capabilities: [.interactions], projects: adapter, sessions: backend, chat: backend, models: backend, events: backend)
                viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
                viewModel.projects = try await backend.projectsSnapshot().projects
                let canonical = try XCTUnwrap(backend.storedSessions.first)
                let stale = OpenCodeSession(id: canonical.id, title: "Cached title", workspaceID: nil,
                    directory: canonical.directory, projectID: canonical.projectID, parentID: nil)
                let recent = RecentProjectSession(session: stale, projectTitle: "Home", preview: nil, isBusy: false)
                let cached = [OpenCodeMessageEnvelope.local(role: "assistant", text: "Cached preview", messageID: "cached", sessionID: canonical.id)]
                viewModel.chatStore.cacheMessages(cached, forSessionID: canonical.id)
                viewModel.saveMessageDraft("Target draft", forSessionID: canonical.id)
                let previous = makeSession()
                viewModel.selectedSession = previous
                viewModel.draftMessage = "Previous draft"

                let snapshotRequested = expectation(description: "Canonical session request suspended")
                let transcriptRequested = expectation(description: "Canonical transcript request suspended")
                var releaseSnapshot: CheckedContinuation<Void, Never>?
                var releaseTranscript: CheckedContinuation<Void, Never>?
                var pausedTranscript = false
                backend.beforeSessionFetch = {
                    await withCheckedContinuation { continuation in
                        releaseSnapshot = continuation
                        snapshotRequested.fulfill()
                    }
                }
                backend.beforeTranscript = {
                    guard !pausedTranscript else { return }
                    pausedTranscript = true
                    await withCheckedContinuation { continuation in
                        releaseTranscript = continuation
                        transcriptRequested.fulfill()
                    }
                }
                defer {
                    releaseSnapshot?.resume()
                    releaseTranscript?.resume()
                    backend.beforeSessionFetch = nil
                    backend.beforeTranscript = nil
                    viewModel.disconnect()
                    transport.invalidateAndCancel()
                }

                if preparesInUI { viewModel.projectFacade.prepareRecentSessionSelection(recent) }
                let opening = Task { await viewModel.projectFacade.openRecentSession(recent) }
                await fulfillment(of: [snapshotRequested], timeout: 2)
                let generation = viewModel.sessionNavigationGeneration
                XCTAssertEqual(viewModel.selectedSession?.id, canonical.id)
                XCTAssertTrue(viewModel.chatStore.isHydratingV2Transcript(sessionID: canonical.id))
                XCTAssertNil(viewModel.chatStore.preparedSessionID)
                XCTAssertTrue(viewModel.isLoadingSelectedSession)
                XCTAssertEqual(viewModel.chatStore.cachedMessagesBySessionID[canonical.id], cached)
                XCTAssertEqual(viewModel.draftMessage, "Target draft")
                XCTAssertEqual(viewModel.composerStore.draftsByChatKey[viewModel.messageDraftStorageKey(for: previous)]?.text, "Previous draft")

                var concurrentSelection: Task<Void, Never>?
                if hydratesConcurrently {
                    concurrentSelection = Task { await viewModel.selectSession(canonical) }
                } else {
                    releaseSnapshot?.resume()
                    releaseSnapshot = nil
                }
                await fulfillment(of: [transcriptRequested], timeout: 2)
                XCTAssertNil(viewModel.chatStore.preparedSessionID)
                XCTAssertTrue(viewModel.isLoadingSelectedSession)
                XCTAssertTrue(viewModel.chatFacade.toolbarSnapshot(for: canonical).isLoading)
                releaseTranscript?.resume()
                releaseTranscript = nil
                if let concurrentSelection {
                    await concurrentSelection.value
                    XCTAssertEqual(viewModel.chatStore.preparedSessionID, canonical.id)
                    XCTAssertFalse(viewModel.isLoadingSelectedSession)
                    viewModel.draftMessage = "Edited during opening"
                    releaseSnapshot?.resume()
                    releaseSnapshot = nil
                }
                await opening.value

                XCTAssertEqual(viewModel.sessionNavigationGeneration, generation)
                XCTAssertEqual(viewModel.selectedSession?.title, canonical.title)
                XCTAssertEqual(viewModel.chatStore.preparedSessionID, canonical.id)
                XCTAssertFalse(viewModel.chatStore.isHydratingV2Transcript(sessionID: canonical.id))
                XCTAssertFalse(viewModel.isLoadingSelectedSession)
                XCTAssertEqual(viewModel.messages.map(\.id), ["home-answer"])
                XCTAssertEqual(backend.transcriptLoads, 1)
                XCTAssertEqual(viewModel.draftMessage, hydratesConcurrently ? "Edited during opening" : "Target draft")
                let toolbar = viewModel.chatFacade.toolbarSnapshot(for: canonical)
                XCTAssertNil(toolbar.selectedAgentName)
                XCTAssertNil(toolbar.selectedModelReference)
                XCTAssertFalse(toolbar.isAgentLoading)
                XCTAssertFalse(toolbar.isModelLoading)
                XCTAssertEqual(toolbar.selectableAgents.map(\.name), ["build"])
                XCTAssertEqual(toolbar.providerGroups.map(\.id), ["recent-test"])
                XCTAssertNil(viewModel.errorMessage)
            }
        }
    }

    func testV2SessionCreationUsesTitleOnlyPrimarySheet() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        viewModel.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17055", healthy: true)

        shell.sessions.presentCreateSession()

        XCTAssertEqual(shell.primarySheet, .createSession)
        XCTAssertFalse(shell.sessions.createSessionSnapshot.showsWorkspacePicker)

        shell.dismissPrimarySheet()
        XCTAssertNil(shell.primarySheet)
    }

    func testCreateSessionPresentationInvalidatesAppShell() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let changed = expectation(description: "App shell observes create-session presentation")
        changed.assertForOverFulfill = false
        let observation = shell.objectWillChange.sink { changed.fulfill() }

        shell.sessions.presentCreateSession()

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(shell.primarySheet, .createSession)
        withExtendedLifetime(observation) {}
    }

    func testV2CurrentContextChatUsesRichSheetAndKeepsSupportedHomeFeatures() async {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: "git")
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        let updatedSnapshot = expectation(description: "Session capabilities reflect the negotiated v2 profile")
        let observation = shell.sessions.$snapshot
            .dropFirst()
            .filter { !$0.supportsLiveActivities }
            .prefix(1)
            .sink { _ in updatedSnapshot.fulfill() }
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        await fulfillment(of: [updatedSnapshot], timeout: 1)

        shell.presentNewChatForCurrentContext()

        guard case let .newProjectChat(request)? = shell.primarySheet else {
            return XCTFail("Expected the rich new-chat sheet")
        }
        XCTAssertEqual(request.projectID, project.id)
        XCTAssertEqual(request.workspaceDirectory, project.worktree)
        XCTAssertTrue(request.locksProject)
        XCTAssertTrue(shell.sessions.snapshot.canCreateSession)
        XCTAssertTrue(shell.chat.allowsV2TextPromptAdmission)
        XCTAssertTrue(shell.allowsProjectBrowser)

        shell.selectProjectContentTab(.terminal)
        shell.presentProjectSettings()
        shell.selectActivity()

        XCTAssertEqual(viewModel.selectedProjectContentTab, .terminal)
        XCTAssertEqual(shell.projectContentSnapshot.availableTabs, [.sessions, .git, .terminal, .mcp])
        XCTAssertTrue(shell.projectContentSnapshot.isTerminalAvailable)
        XCTAssertTrue(shell.projectContentSnapshot.isShowingSettings)
        XCTAssertFalse(shell.sessions.snapshot.supportsLiveActivities)
        XCTAssertFalse(shell.projects.allowsProjectCreation)
        XCTAssertTrue(shell.isActivitySelected)
        XCTAssertEqual(shell.contentRoute(isCompact: true), .activity)
        XCTAssertTrue(shell.projects.allowsSessionSearch)
        XCTAssertTrue(shell.projects.allowsNewChat)
        withExtendedLifetime(observation) {}
    }

    func testInjectedHomeNavigatesRefreshesAndSearchesEveryCatalogScopeWithoutHTTP() async throws {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel(backendFactory: backend)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        let shell = viewModel.appShellFacade

        XCTAssertTrue(shell.projects.allowsSessionSearch)
        XCTAssertTrue(shell.projects.allowsNewChat)
        XCTAssertFalse(shell.projects.allowsProjectCreation)
        XCTAssertFalse(shell.projects.allowsActivity)
        XCTAssertNil(viewModel.compatibilityClient(for: .interactions))
        XCTAssertNil(viewModel.connectionStore.apiProfile)

        let project = try XCTUnwrap(viewModel.projects.first { $0.id == "home-project" })
        let preparedTicket = await shell.projects.prepareSelectionForNavigation(project)
        let ticket = try XCTUnwrap(preparedTicket)
        await shell.projects.completeSelection(ticket)
        XCTAssertEqual(viewModel.selectedDirectory, "/home-project")
        XCTAssertEqual(viewModel.sessions.map(\.id), ["home-session"])
        XCTAssertGreaterThanOrEqual(backend.projectLoads, 2)
        XCTAssertNil(viewModel.errorMessage)

        await shell.projects.refreshList()
        let recentBeforeSearch = viewModel.sessionListStore.recentSessionsByDirectory
        shell.projects.projectSessionSearchQuery = "Archived title"
        await shell.projects.searchSessions()

        XCTAssertEqual(Set(backend.searchScopes.compactMap(\.projectID)), ["global", "home-project"])
        XCTAssertEqual(Set(backend.searchScopes.compactMap(\.directory)), ["/home-project", "/home-sandbox"])
        XCTAssertTrue(backend.searchScopes.contains(.init(projectID: "global", directory: nil)))
        XCTAssertEqual(shell.projects.listSnapshot.searchResults.map(\.session.id), ["search-only"])
        XCTAssertEqual(viewModel.sessionListStore.recentSessionsByDirectory, recentBeforeSearch)
        XCTAssertFalse(shell.projects.listSnapshot.isSearching)

        let global = try XCTUnwrap(viewModel.projects.first { $0.id == "global" })
        let globalTicket = shell.projects.beginSelection(global)
        await shell.projects.completeSelection(globalTicket)
        XCTAssertNil(viewModel.selectedDirectory)
        XCTAssertNil(viewModel.effectiveSelectedDirectory)
        XCTAssertEqual(viewModel.projectStore.defaultServerDirectory, "/execution-default")
        XCTAssertTrue(backend.listScopes.contains(.init(projectID: "global", directory: nil)))
        shell.presentNewChatForCurrentContext()
        XCTAssertEqual(viewModel.newProjectChatSheetRequest?.projectID, "global")
        XCTAssertNil(viewModel.newProjectChatSheetRequest?.workspaceDirectory)
    }

    func testNewProjectChatTransfersReservationAndRefundsOnlyDefinitiveRejectionOnce() async throws {
        for outcome in ["accepted", "rejected", "uncertain", "timeout"] {
            let backend = HomeTestBackend()
            let viewModel = AppViewModel(backendFactory: backend)
            await viewModel.connectionFacade.connect()
            defer { viewModel.disconnect() }
            let usage = HomePromptUsageStore()
            viewModel.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free),
                usageStore: usage, purchaseManager: OpenClientPurchaseManager())
            viewModel.commerceFacade.hydratePersistedState()
            let reservedDay = usage.meter.promptDay
            backend.admissionResult = { request in
                XCTAssertEqual(viewModel.usageMeter.dailyPromptCount, 4, "The home reservation must not be charged twice")
                switch outcome {
                case "accepted": return .accepted(sessionID: request.sessionID, messageID: request.messageID)
                case "rejected": return .rejected(sessionID: request.sessionID, messageID: request.messageID)
                case "uncertain": return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
                default: throw URLError(.timedOut)
                }
            }

            let messageID = "home-\(outcome)"
            let accepted = await viewModel.startNewProjectChat(prompt: "Hello", messageID: messageID, projectID: "home-project")

            XCTAssertEqual(accepted, outcome == "accepted", outcome)
            let expectedCount = outcome == "rejected" ? 3 : 4
            XCTAssertEqual(viewModel.usageMeter.dailyPromptCount, expectedCount, outcome)
            XCTAssertEqual(viewModel.usageMeter.createdSessionCount, 1)
            XCTAssertEqual(backend.submissions.map(\.messageID), [messageID])
            let session = try XCTUnwrap(backend.storedSessions.first { $0.id == "created-home-session" })
            let phase = viewModel.chatFacade.promptAdmissionPhase(messageID: messageID, sessionID: session.id)
            if outcome == "rejected" {
                XCTAssertEqual(phase, .rejected)
            } else if outcome != "accepted" {
                XCTAssertEqual(phase, .uncertain)
            }

            // Re-presenting the same identity must neither resubmit nor refund the reservation again.
            let repeated = await viewModel.sendMessage("Hello", in: session, userVisible: true,
                messageID: messageID, meterPrompt: false, reservedPromptDay: reservedDay)
            XCTAssertEqual(repeated, accepted)
            XCTAssertEqual(viewModel.usageMeter.dailyPromptCount, expectedCount, outcome)
            XCTAssertEqual(backend.submissions.count, 1)
            backend.admissionResult = nil
        }
    }

    func testHomeSearchDropsResultsFromReplacedConnection() async throws {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel(backendFactory: backend)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        viewModel.projects = viewModel.projects.filter { $0.id == "home-project" }.map {
            OpenCodeProject(id: $0.id, worktree: $0.worktree, vcs: nil, name: $0.name, sandboxes: nil, icon: nil, time: nil)
        }
        let requested = expectation(description: "Search suspended")
        var release: CheckedContinuation<Void, Never>?
        backend.beforeSearch = {
            await withCheckedContinuation { continuation in
                release = continuation
                requested.fulfill()
            }
        }
        viewModel.projectSessionSearchQuery = "Archived title"
        let search = Task { await viewModel.projectFacade.searchSessions() }
        await fulfillment(of: [requested], timeout: 1)
        viewModel.backendConnection?.close()
        viewModel.backendConnection = try await backend.connect()
        release?.resume()
        await search.value
        XCTAssertTrue(viewModel.projectSessionSearchResults.isEmpty)
    }

    func testV2FormsRemainNativeAndVisibleWithoutLegacyQuestionDuplicates() throws {
        let viewModel = AppViewModel()
        let session = makeSession()
        viewModel.allSessions = [session]
        viewModel.selectedSession = session
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        let simple = OpenCodeV2Form(id: "simple", sessionID: session.id, title: "Simple", metadata: nil,
            fields: [["key": .string("name"), "type": .string("string"), "required": .bool(true)]])
        let external = OpenCodeV2Form(id: "external", sessionID: session.id, title: "Authenticate", metadata: nil,
            fields: [["key": .string("auth"), "type": .string("external"), "url": .string("https://example.com/authorize")]])
        let conditional = OpenCodeV2Form(id: "conditional", sessionID: session.id, title: "Conditional", metadata: nil,
            fields: [
                ["key": .string("enabled"), "type": .string("boolean"), "default": .bool(false)],
                ["key": .string("detail"), "type": .string("string"), "required": .bool(true),
                 "when": .array([.object(["key": .string("enabled"), "op": .string("eq"), "value": .bool(true)])])]
            ])
        let unsupported = OpenCodeV2Form(id: "unsupported", sessionID: session.id, title: "Future field", metadata: nil,
            fields: [["key": .string("future"), "type": .string("future")]])
        let owner = viewModel.directoryStore
        owner.applyV2SessionInteractions(sessionID: session.id, permissions: [], forms: [simple, external, conditional, unsupported],
            permissionRevisionAtRequestStart: owner.permissionRevision, questionRevisionAtRequestStart: owner.questionRevision)

        XCTAssertEqual(viewModel.chatFacade.unsupportedV2Forms(forSessionID: session.id).map(\.id), ["unsupported"])
        let visible = viewModel.chatFacade.sessionForms(forSessionID: session.id)
        XCTAssertEqual(visible.map(\.id), ["conditional", "external", "simple", "unsupported"])
        XCTAssertEqual(owner.sessionFormStore.forms.count, 4)
        for dto in [simple, external, conditional, unsupported] {
            XCTAssertEqual(owner.sessionFormStore.forms[dto.backendForm.key]?.fields.map(\.raw), dto.fields)
        }
        XCTAssertTrue(visible.filter { $0.id != unsupported.id }.allSatisfy { $0.contract.isSupported() })
        XCTAssertTrue(owner.syncState.questionsBySessionID.isEmpty)
        XCTAssertTrue(viewModel.chatFacade.composerOverlaySnapshot(forSessionID: session.id).questions.isEmpty)
        let snapshot = viewModel.sessionListFacade.snapshot
        let row = try XCTUnwrap((snapshot.pinnedRows + snapshot.unpinnedRows).first { $0.id == session.id })
        XCTAssertEqual(row.pendingInteractionCount, 4)
        XCTAssertTrue(row.activityNeedsInput)
        XCTAssertTrue(row.hasPermissionRequest)
        XCTAssertEqual(row.activityRow.pendingInteractionCount, 4)
        XCTAssertEqual(row.activityStatusTitle, String(localized: "Needs input"))
    }

    func testSessionListCountsNativeChildFormsOnceAndClearsNeedsInputOnSettlement() async throws {
        let viewModel = AppViewModel()
        let root = makeSession()
        let child = OpenCodeSession(id: "child", title: "Child", workspaceID: nil, directory: root.directory,
            projectID: root.projectID, parentID: root.id)
        let other = OpenCodeSession(id: "other", title: "Other", workspaceID: nil, directory: root.directory,
            projectID: root.projectID, parentID: nil)
        viewModel.allSessions = [root, child, other]
        viewModel.selectedSession = root
        let owner = viewModel.directoryStore
        let form = BackendForm(id: "frm_child", sessionID: child.id, title: "Confirm",
            fields: [.init(raw: ["key": .string("confirm"), "type": .string("boolean"), "required": .bool(true)])])
        owner.applySessionFormCreated(form)
        let facade = viewModel.sessionListFacade
        let rows = facade.snapshot.pinnedRows + facade.snapshot.unpinnedRows
        let row = try XCTUnwrap(rows.first { $0.id == root.id })
        XCTAssertEqual(row.pendingInteractionCount, 1)
        XCTAssertTrue(row.activityNeedsInput)
        XCTAssertTrue(row.hasPermissionRequest)
        XCTAssertEqual(row.activityStatusTitle, String(localized: "Needs input"))
        XCTAssertEqual(rows.first { $0.id == other.id }?.pendingInteractionCount, 0)
        XCTAssertEqual(viewModel.chatFacade.sessionForms(forSessionID: root.id), [form])
        XCTAssertTrue(owner.syncState.questionsBySessionID.isEmpty)

        let settled = expectation(description: "Session row clears native-form Needs Input")
        let observation = facade.$snapshot.dropFirst().filter { snapshot in
            (snapshot.pinnedRows + snapshot.unpinnedRows).contains {
                $0.id == root.id && $0.pendingInteractionCount == 0 && !$0.activityNeedsInput && !$0.hasPermissionRequest
            }
        }.prefix(1).sink { _ in settled.fulfill() }
        owner.applySessionFormSettled(form.key)
        await fulfillment(of: [settled], timeout: 1)
        withExtendedLifetime(observation) {}
        XCTAssertTrue(viewModel.chatFacade.sessionForms(forSessionID: root.id).isEmpty)
    }

    func testSessionListDoesNotDoubleCountAnOldQuestionProjectionOfANativeForm() throws {
        let viewModel = AppViewModel()
        let session = makeSession()
        viewModel.allSessions = [session]
        let owner = viewModel.directoryStore
        let form = BackendForm(id: "frm_1", sessionID: session.id, title: "Confirm",
            fields: [.init(raw: ["key": .string("confirm"), "type": .string("boolean")])])
        owner.applySessionFormCreated(form)
        // Simulate an older in-memory projection during migration, not a legacy wire payload.
        owner.syncStore.state.questionsBySessionID[session.id] = [
            OpenCodeQuestionRequest(id: form.id, sessionID: session.id, questions: [], tool: nil)
        ]
        let snapshot = viewModel.sessionListFacade.snapshot
        let row = try XCTUnwrap((snapshot.pinnedRows + snapshot.unpinnedRows).first { $0.id == session.id })
        XCTAssertEqual(row.pendingInteractionCount, 1)
        XCTAssertEqual(row.activityRow.pendingInteractionCount, 1)
        XCTAssertTrue(row.activityNeedsInput)
    }

    func testV2GlobalTerminalUsesDefaultLocationAndRoutesSessionlessEvents() throws {
        let viewModel = AppViewModel()
        viewModel.config = OpenCodeServerConfig(baseURL: "http://v2.invalid", password: "test")
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        viewModel.currentProject = nil
        viewModel.selectedDirectory = nil
        viewModel.projectStore.defaultServerDirectory = "/tmp/v2-default"

        XCTAssertNil(viewModel.effectiveSelectedDirectory)
        XCTAssertEqual(viewModel.effectiveTerminalDirectory, "/tmp/v2-default")
        XCTAssertTrue(viewModel.appShellFacade.projectContentSnapshot.isTerminalAvailable)

        let event = try JSONDecoder().decode(OpenCodeV2ManagedEvent.self, from: Data(#"{"type":"pty.created","location":{"directory":"/tmp/v2-default"},"data":{"info":{"id":"pty_default","title":"Shell","command":"/bin/sh","args":[],"cwd":"/tmp/v2-default","status":"running","pid":1}}}"#.utf8))
        XCTAssertNil(event.sessionID)
        viewModel.handleV2Event(event)
        XCTAssertEqual(viewModel.terminalFacade.snapshot.terminals.map(\.id), ["pty_default"])
        XCTAssertNil(viewModel.selectedDirectory)

        viewModel.disconnect()
        XCTAssertNil(viewModel.projectStore.defaultServerDirectory)
        XCTAssertTrue(viewModel.terminalFacade.snapshot.terminals.isEmpty)
    }

    func testV2ProviderMutationFailsWithoutLegacyAuthenticationRequests() async {
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)

        let connected = await viewModel.connectProviderWithAPIKey(providerID: "openai", key: "not-a-real-key")

        XCTAssertFalse(connected)
        XCTAssertEqual(viewModel.errorMessage, String(localized: "Manage provider connections in the OpenCode web app for this v2 server."))
    }

    func testFailedV2ConfigurationIsRemovedAndCanBeRetried() async throws {
        struct ConfigurationError: Error {}
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        let facade = viewModel.chatFacade
        let sessionID = makeSession().id
        facade.queueV2Configuration(sessionID: sessionID, operation: { _ in throw ConfigurationError() },
            apply: { XCTFail("Failed configuration must not apply") })
        let failed = try XCTUnwrap(facade.v2ConfigurationTasks[sessionID]?.task)

        let firstResult = await failed.value

        XCTAssertFalse(firstResult)
        XCTAssertNil(facade.v2ConfigurationTasks[sessionID])
        var applied = false
        facade.queueV2Configuration(sessionID: sessionID, operation: { _ in }, apply: { applied = true })
        let retry = try XCTUnwrap(facade.v2ConfigurationTasks[sessionID]?.task)
        let retryResult = await retry.value
        XCTAssertTrue(retryResult)
        XCTAssertTrue(applied)
        XCTAssertNil(facade.v2ConfigurationTasks[sessionID])
    }

    func testOlderV2ConfigurationCompletionDoesNotRemoveReplacement() async throws {
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        let facade = viewModel.chatFacade
        let sessionID = makeSession().id
        let firstGate = AsyncStream<Void>.makeStream()
        let secondGate = AsyncStream<Void>.makeStream()
        facade.queueV2Configuration(sessionID: sessionID, operation: { _ in
            for await _ in firstGate.stream { break }
        }, apply: {})
        let first = try XCTUnwrap(facade.v2ConfigurationTasks[sessionID])
        facade.queueV2Configuration(sessionID: sessionID, operation: { _ in
            for await _ in secondGate.stream { break }
        }, apply: {})
        let second = try XCTUnwrap(facade.v2ConfigurationTasks[sessionID])

        firstGate.continuation.yield(())
        firstGate.continuation.finish()
        _ = await first.task.value
        XCTAssertEqual(facade.v2ConfigurationTasks[sessionID]?.id, second.id)

        secondGate.continuation.yield(())
        secondGate.continuation.finish()
        _ = await second.task.value
        XCTAssertNil(facade.v2ConfigurationTasks[sessionID])
    }

    func testV2SessionConfigurationIsAuthoritativeBeforeCatalogHydration() {
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        var session = makeSession()
        session.agent = "server-agent"
        session.model = OpenCodeMessageModelReference(providerID: "server-provider", modelID: "server-model", variant: "high")

        viewModel.applyV2SessionConfiguration(session)

        XCTAssertEqual(viewModel.modelConfigurationStore.selectedAgentName(for: session.id), "server-agent")
        XCTAssertEqual(viewModel.modelConfigurationStore.selectedModelReference(for: session.id),
            OpenCodeModelReference(providerID: "server-provider", modelID: "server-model"))
        XCTAssertEqual(viewModel.modelConfigurationStore.selectedVariant(for: session.id), "high")

        var partial = makeSession()
        partial.agent = "updated-agent"
        viewModel.applyV2SessionConfiguration(partial)
        XCTAssertEqual(viewModel.modelConfigurationStore.selectedAgentName(for: session.id), "updated-agent")
        XCTAssertEqual(viewModel.modelConfigurationStore.selectedVariant(for: session.id), "high")

        session.model = OpenCodeMessageModelReference(providerID: "server-provider", modelID: "server-model", variant: nil)
        viewModel.syncComposerSelections(for: session, sourceMessages: [])
        XCTAssertNil(viewModel.modelConfigurationStore.selectedVariant(for: session.id))
        XCTAssertEqual(viewModel.modelConfigurationStore.selectedAgentName(for: session.id), "server-agent")
    }

    func testV2GamesAreGatedInPresentationAndDirectActions() async {
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulServerConnection(version: "legacy", healthy: true)
        let factory = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: viewModel.config), eventManager: viewModel.eventManager)
        viewModel.backendConnection = factory.makeConnection(profile: .legacy, version: "legacy", healthy: true)
        viewModel.funAndGamesPreferences.showsSection = true
        XCTAssertTrue(viewModel.funAndGamesFacade.showsSection)
        viewModel.backendConnection?.close()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true)
        viewModel.backendConnection = factory.makeConnection(profile: .v2, version: "0.0.0-next-17155", healthy: true)
        let games = viewModel.funAndGamesFacade
        let model = OpenCodeModelReference(providerID: "test", modelID: "test")
        let language = FindBugGameLanguage(id: "swift", title: "Swift")

        games.presentFindPlaceModelSheet()
        games.presentFindBugLanguageSheet()
        games.selectFindBugLanguage(language)
        XCTAssertFalse(games.showsSection)
        XCTAssertFalse(games.isShowingFindPlaceModelSheet)
        XCTAssertFalse(games.isShowingFindBugLanguageSheet)
        XCTAssertFalse(games.isShowingFindBugModelSheet)
        XCTAssertNil(viewModel.pendingFindBugLanguage)

        viewModel.pendingFindBugLanguage = language
        await viewModel.startFindPlaceGame(model: model)
        await viewModel.startFindBugGame(model: model)
        XCTAssertNil(viewModel.currentProject)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertNil(viewModel.errorMessage)
        XCTAssertFalse(viewModel.isLoading)
    }

    func testV2RetryCleanupRequiresExactAdmissionAndUneditedComposer() {
        let mention = OpenCodeAgentMention(name: "build", content: "@build", start: 0, end: 6)
        let attachment = OpenCodeComposerAttachment(id: "file-original", kind: .file, filename: "notes.txt",
            mime: "text/plain", dataURL: "data:text/plain;base64,bm90ZXM=")
        let retry = OpenCodeV2RetryDraft(messageID: "msg_original", sessionID: "session", contextID: "connection:1:nav:2",
            revision: 4, resetToken: UUID(), text: "@build inspect", mentions: [mention], attachments: [attachment])

        XCTAssertTrue(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_other", sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: nil, sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: [attachment]))
        // Editing away and back produces identical text but a different draft revision.
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: retry.contextID,
            revision: 6, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: UUID(), text: retry.text, mentions: [mention], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "another-session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: "connection:1:nav:4",
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: "new draft", mentions: [mention], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [], attachments: [attachment]))
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: []))
        let replacement = OpenCodeComposerAttachment(id: "file-new", kind: attachment.kind, filename: attachment.filename,
            mime: attachment.mime, dataURL: attachment.dataURL)
        XCTAssertFalse(retry.canClear(admittedMessageID: "msg_original", sessionID: "session", contextID: retry.contextID,
            revision: 4, resetToken: retry.resetToken, text: retry.text, mentions: [mention], attachments: [replacement]))
    }

    func testV2DraftConfirmationUsesExactIDNotOptimisticTextOrLockRelease() {
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        let sessionID = makeSession().id
        let first = OpenCodeMessageEnvelope.local(role: "user", text: "same text", messageID: "msg_first", sessionID: sessionID)
        let second = OpenCodeMessageEnvelope.local(role: "user", text: "same text", messageID: "msg_second", sessionID: sessionID)
        let store = viewModel.chatStore
        let facade = viewModel.chatFacade

        XCTAssertTrue(store.beginV2Prompt(first, sessionID: sessionID))
        store.markSubmissionUncertain(messageID: first.id, sessionID: sessionID)
        XCTAssertFalse(facade.isV2PromptAdmitted(messageID: first.id, sessionID: sessionID))
        store.confirmSubmissionAdmission(messageID: first.id, sessionID: sessionID)
        XCTAssertTrue(facade.isV2PromptAdmitted(messageID: first.id, sessionID: sessionID))

        XCTAssertTrue(store.beginV2Prompt(second, sessionID: sessionID))
        store.markSubmissionUncertain(messageID: second.id, sessionID: sessionID)
        XCTAssertFalse(facade.isV2PromptAdmitted(messageID: second.id, sessionID: sessionID))
        store.applyV2EventProjection([first, second], olderCursor: nil, sessionID: sessionID)
        XCTAssertNotNil(store.submissionRecoveries[second.id])
        viewModel.directoryStore.applyV2Messages([first, second], forSessionID: sessionID)
        viewModel.finishTranscriptCommit(in: viewModel.directoryStore, sessionID: sessionID)
        XCTAssertNil(store.submissionRecoveries[second.id])
        XCTAssertTrue(facade.isV2PromptAdmitted(messageID: second.id, sessionID: sessionID),
            "Canonical projection retains exact-ID evidence after retiring recovery; cache contents alone are not evidence.")

        store.rollbackV2Prompt(messageID: second.id, sessionID: sessionID)
        XCTAssertTrue(facade.isV2PromptAdmitted(messageID: second.id, sessionID: sessionID))
        XCTAssertFalse(facade.isV2PromptAdmitted(messageID: first.id, sessionID: "another-session"))
    }

    func testV2DraftContextChangesWhenNavigationChanges() {
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        let firstContext = viewModel.chatFacade.v2DraftContextID

        viewModel.sessionNavigationGeneration &+= 1

        XCTAssertNotEqual(viewModel.chatFacade.v2DraftContextID, firstContext)
        let navigationContext = viewModel.chatFacade.v2DraftContextID
        viewModel.directoryStoreRegistry.reset()
        XCTAssertNotEqual(viewModel.chatFacade.v2DraftContextID, navigationContext)
    }

    func testV2PromptTrimmingKeepsMentionOffsetsAligned() {
        let result = OpenCodeAgentMention.trimmingTextAndMentions(
            text: " \n @build investigate \n",
            mentions: [OpenCodeAgentMention(name: "build", content: "@build", start: 3, end: 9)]
        )
        XCTAssertEqual(result.text, "@build investigate")
        XCTAssertEqual(result.mentions, [OpenCodeAgentMention(name: "build", content: "@build", start: 0, end: 6)])
    }

    func testProjectLoadingRouteAppliesOnlyToCompactEmptyDirectory() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject()
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.directoryStore.isLoadingSessions = true

        XCTAssertEqual(shell.contentRoute(isCompact: true), .loadingProject)
        XCTAssertEqual(shell.contentRoute(isCompact: false), .projectContent)

        viewModel.directoryStore.sessions = [makeSession()]
        XCTAssertEqual(shell.contentRoute(isCompact: true), .projectContent)
    }

    func testActivityUsesContentColumnWithoutReplacingPreparedChatDetail() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: "git")
        let session = makeSession()
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.selectedSession = session
        viewModel.backendMode = .server
        viewModel.selectedProjectContentTab = .git
        viewModel.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: [])

        shell.selectActivity()

        XCTAssertEqual(shell.contentRoute(isCompact: false), .activity)
        XCTAssertEqual(
            shell.detailRoute(isCompact: false),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: 0))
        )

        shell.selectProjectContent()

        XCTAssertEqual(shell.contentRoute(isCompact: false), .projectContent)
        XCTAssertEqual(shell.detailRoute(isCompact: false), .gitFile)
    }

    func testAutomaticConnectionLandingDestinationSelectsConfiguredContent() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade

        shell.selectAutomaticConnectionLandingDestination(.activity)
        XCTAssertTrue(shell.isActivitySelected)
        XCTAssertEqual(shell.contentRoute(isCompact: true), .activity)

        shell.selectAutomaticConnectionLandingDestination(.projects)
        XCTAssertFalse(shell.isActivitySelected)
        XCTAssertEqual(shell.contentRoute(isCompact: true), .selectProject)
    }

    func testProjectToolbarNewSessionPresentsCurrentContext() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject()
        viewModel.currentProject = project
        viewModel.selectedDirectory = "/tmp/workspace"
        viewModel.selectedProjectContentTab = .sessions

        shell.performProjectContentToolbarAction()

        let request = viewModel.newProjectChatSheetRequest
        XCTAssertEqual(request?.projectID, project.id)
        XCTAssertEqual(request?.workspaceDirectory, "/tmp/workspace")
        XCTAssertEqual(request?.locksProject, true)
        XCTAssertNil(request?.composerSelection)
    }

    func testProjectTalkPresentsLockedCurrentContext() async {
        let viewModel = AppViewModel(backendFactory: HomeTestBackend())
        await viewModel.connectionFacade.connect()
        defer { viewModel.talkSessionCoordinator.stop(); viewModel.disconnect() }
        let shell = viewModel.appShellFacade
        let project = makeProject()
        viewModel.currentProject = project
        viewModel.selectedDirectory = "/tmp/workspace"
        XCTAssertTrue(viewModel.projectFacade.allowsNewTalk)
        viewModel.talkSessionCoordinator.setHoldToTalkEnabled(true)

        shell.presentNewTalkForCurrentContext()

        XCTAssertEqual(viewModel.talkSessionCoordinator.phase, .listening)
        XCTAssertEqual(viewModel.talkSessionCoordinator.selectedProjectID, project.id)
        XCTAssertNil(viewModel.newProjectChatSheetRequest)
        XCTAssertNil(viewModel.selectedSession)
    }

    func testPluginSetupPresentsPrefilledGlobalChat() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade

        shell.presentPluginSetupChat()

        let request = viewModel.newProjectChatSheetRequest
        XCTAssertEqual(request?.projectID, "global")
        XCTAssertNil(request?.workspaceDirectory)
        XCTAssertEqual(request?.locksProject, true)
        XCTAssertEqual(request?.initialContent?.text, OpenClientPluginSetup.prompt)
        XCTAssertEqual(request?.initialContent?.attachments, [])
        XCTAssertEqual(request?.presentsAboveConnection, true)
    }

    func testDetailRoutePrioritizesGitThenMCPThenServerChat() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: "git")
        let session = makeSession()
        let path = "Sources/App.swift"
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.selectedSession = session
        viewModel.selectedProjectContentTab = .git
        viewModel.projectFilesStore.selectedFilePath = path
        viewModel.projectFilesStore.vcsFileStatuses = [
            OpenCodeVCSFileStatus(path: path, added: 1, removed: 0, status: "modified"),
        ]

        XCTAssertEqual(shell.detailRoute(isCompact: false), .gitDiff)

        viewModel.projectFilesStore.vcsFileStatuses = []
        XCTAssertEqual(shell.detailRoute(isCompact: false), .gitFile)

        viewModel.selectedProjectContentTab = .mcp
        XCTAssertEqual(shell.detailRoute(isCompact: false), .mcp)

        viewModel.selectedProjectContentTab = .sessions
        viewModel.backendMode = .server
        viewModel.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: [])
        XCTAssertEqual(
            shell.detailRoute(isCompact: false),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: 0))
        )
    }

    func testChatRouteWaitsForPreparedSessionAtEverySizeClass() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let session = makeSession()
        viewModel.backendMode = .server
        viewModel.selectedSession = session
        viewModel.chatDetailPresentationRequest = 7

        XCTAssertEqual(shell.detailRoute(isCompact: true), .loadingChat(sessionID: session.id))
        XCTAssertEqual(shell.detailRoute(isCompact: false), .loadingChat(sessionID: session.id))

        viewModel.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: [])
        XCTAssertEqual(
            shell.detailRoute(isCompact: true),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: 7))
        )
        XCTAssertEqual(
            shell.detailRoute(isCompact: false),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: 7))
        )
    }

    func testAppleIntelligenceSelectedSessionIsExcludedFromRootChatRoute() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        viewModel.backendMode = .appleIntelligence
        viewModel.selectedSession = makeSession()

        XCTAssertEqual(shell.detailRoute(isCompact: false), .selectSession)
    }

    func testGitTabAvailabilityAndInvalidSelectionReconciliation() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: nil)
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.selectedProjectContentTab = .git

        XCTAssertEqual(shell.projectContentSnapshot.availableTabs, [.sessions, .mcp])

        shell.reconcileInvalidGitSelection()
        XCTAssertEqual(shell.projectContentSnapshot.selectedTab, .sessions)

        viewModel.currentProject = makeProject(vcs: "git")
        XCTAssertEqual(shell.projectContentSnapshot.availableTabs, [.sessions, .git, .mcp])
    }

    func testSelectingGitPreservesDraftPreparesFilesAndClearsSession() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: "git")
        let session = makeSession()
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.selectedSession = session
        viewModel.draftMessage = "Keep this draft"
        viewModel.projectFilesStore.vcsInfo = OpenCodeVCSInfo(branch: "main", defaultBranch: "main")
        viewModel.projectFilesStore.vcsDiffsByMode[.git] = []
        let draftKey = viewModel.messageDraftStorageKey(for: session)

        shell.selectProjectContentTab(.git)

        XCTAssertEqual(viewModel.projectStore.selectedContentTab, .git)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertEqual(viewModel.projectFilesFacade.selectedWorkspaceDirectory, project.worktree)
        XCTAssertEqual(viewModel.composerStore.draftsByChatKey[draftKey]?.text, "Keep this draft")
    }

    func testSelectingGitWithoutGitProjectDoesNothing() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: nil)
        let session = makeSession()
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.selectedSession = session

        shell.selectProjectContentTab(.git)

        XCTAssertEqual(viewModel.projectStore.selectedContentTab, .sessions)
        XCTAssertEqual(viewModel.selectedSession?.id, session.id)
        XCTAssertNil(viewModel.projectFilesFacade.selectedWorkspaceDirectory)
    }

    func testSelectingMCPPreservesDraftAndClearsSession() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let session = makeSession()
        viewModel.currentProject = makeProject()
        viewModel.selectedDirectory = "/tmp/project"
        viewModel.selectedSession = session
        viewModel.draftMessage = "Keep MCP draft"
        viewModel.mcpStore.isReady = true
        let draftKey = viewModel.messageDraftStorageKey(for: session)

        shell.selectProjectContentTab(.mcp)

        XCTAssertEqual(viewModel.projectStore.selectedContentTab, .mcp)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertEqual(viewModel.composerStore.draftsByChatKey[draftKey]?.text, "Keep MCP draft")
    }

    func testTerminalTabIsAvailableForServerProjectAndClearsSelectedSession() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: "git")
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.selectedSession = makeSession()
        viewModel.backendMode = .server
        viewModel.isConnected = true

        XCTAssertTrue(shell.projectContentSnapshot.availableTabs.contains(.terminal))

        shell.selectProjectContentTab(.terminal)

        XCTAssertEqual(viewModel.selectedProjectContentTab, .terminal)
        XCTAssertNil(viewModel.selectedSession)
    }

    func testTerminalDetailRouteUsesSelectedTerminal() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject(vcs: "git")
        let terminal = OpenCodePTY(
            id: "pty_1",
            title: "Terminal 1",
            command: "/bin/zsh",
            args: ["-l"],
            cwd: project.worktree,
            status: "running",
            pid: 42
        )
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.selectedProjectContentTab = .terminal
        viewModel.terminalStore.activate(directory: project.worktree)

        XCTAssertEqual(shell.detailRoute(isCompact: false), .selectTerminal)

        viewModel.terminalStore.append(terminal, directory: project.worktree)

        XCTAssertEqual(shell.detailRoute(isCompact: false), .terminal(id: terminal.id))
    }

    func testObservationRebindsToNewActiveDirectoryStore() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        let project = makeProject()
        viewModel.currentProject = project
        viewModel.selectedDirectory = "/tmp/other"
        let activeStore = viewModel.directoryStoreRegistry.activeStore
        let changed = expectation(description: "App shell observes the new active directory")
        changed.assertForOverFulfill = false
        let observation = shell.objectWillChange.sink { changed.fulfill() }

        activeStore.isLoadingSessions = true

        wait(for: [changed], timeout: 1)
        XCTAssertEqual(shell.contentRoute(isCompact: true), .loadingProject)
        withExtendedLifetime(observation) {}
    }

    func testTranscriptChangesDoNotInvalidateAppShell() {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade
        var changeCount = 0
        let observation = shell.objectWillChange.sink { changeCount += 1 }

        viewModel.objectWillChange.send()
        viewModel.chatStore.messages = [makeMessage()]
        var syncState = viewModel.directoryStore.syncState
        syncState.replaceMessages([makeMessage()], forSessionID: "session")
        viewModel.directoryStore.syncState = syncState

        XCTAssertEqual(changeCount, 0)
        withExtendedLifetime(observation) {}
    }

    func testPreparedSessionStillInvalidatesAppShellRoute() async {
        let viewModel = AppViewModel()
        let session = makeSession()
        viewModel.backendMode = .server
        viewModel.selectedSession = session
        let shell = viewModel.appShellFacade

        // Initial @Published values are also forwarded asynchronously; they must not satisfy this test.
        let initialized = expectation(description: "App shell initial notifications delivered")
        DispatchQueue.main.async { initialized.fulfill() }
        await fulfillment(of: [initialized], timeout: 1)

        XCTAssertEqual(shell.detailRoute(isCompact: false), .loadingChat(sessionID: session.id))
        let changed = expectation(description: "Prepared session invalidates app shell route")
        let observation = shell.objectWillChange.sink { changed.fulfill() }

        viewModel.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: [])

        await fulfillment(of: [changed], timeout: 1)
        XCTAssertEqual(
            shell.detailRoute(isCompact: false),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: 0))
        )
        withExtendedLifetime(observation) {}
    }

    func testBrowserScopeFollowsCurrentProject() async {
        let viewModel = AppViewModel()
        let shell = viewModel.appShellFacade

        viewModel.currentProject = makeProject(id: "project-a")
        await flushBrowserContextUpdates()
        shell.browser.openAddressBar()
        shell.browser.collapse()

        viewModel.currentProject = makeProject(id: "project-b")
        await flushBrowserContextUpdates()
        XCTAssertEqual(shell.browser.activeProjectID, "project-b")
        XCTAssertEqual(shell.browser.presentation, .closed)

        viewModel.currentProject = makeProject(id: "project-a")
        await flushBrowserContextUpdates()
        XCTAssertEqual(shell.browser.activeProjectID, "project-a")
        XCTAssertEqual(shell.browser.presentation, .collapsed)
        shell.browser.clearAllBrowserSessions()
    }

    func testManualBrowserIsAvailableForV2WithoutAdvertisingBridgeCapability() {
        let viewModel = AppViewModel()
        viewModel.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true)
        let factory = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: viewModel.config), eventManager: viewModel.eventManager)
        let connection = factory.makeConnection(profile: .v2, version: "next", healthy: true)
        viewModel.backendConnection = connection
        defer { connection.close() }
        let shell = viewModel.appShellFacade

        XCTAssertFalse(shell.allowsProjectBrowser, "A project is required even for manual browsing")
        viewModel.currentProject = makeProject()
        XCTAssertTrue(shell.allowsProjectBrowser)
        XCTAssertFalse(connection.capabilities.contains(.bridge))
        XCTAssertNil(viewModel.compatibilityClient(for: .bridge))

        viewModel.isConnected = false
        XCTAssertTrue(shell.allowsProjectBrowser, "Manual web browsing does not require an online OpenCode server")
        viewModel.backendMode = .cachedServer
        XCTAssertFalse(shell.allowsProjectBrowser, "Downloaded chats remain read-only")
        viewModel.backendMode = .appleIntelligence
        XCTAssertTrue(shell.allowsProjectBrowser)
        viewModel.currentProject = nil
        XCTAssertFalse(shell.allowsProjectBrowser)
    }

    func testBrowserBindingUsesRetainedConnectionIdentityAndWorktreeAfterPublishedUpdates() async throws {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel(backendFactory: backend)
        let firstConnection = try await backend.connect()
        viewModel.backendConnection = firstConnection
        viewModel.isConnected = true
        viewModel.currentProject = makeProject()
        let shell = viewModel.appShellFacade
        await flushBrowserContextUpdates()
        let mainPage = shell.browser.webView
        shell.browser.addressText = "https://main.example"

        viewModel.selectedDirectory = "/tmp/worktree"
        await flushBrowserContextUpdates()
        let worktreePage = shell.browser.webView
        XCTAssertFalse(worktreePage === mainPage)
        XCTAssertEqual(shell.browser.addressText, "")
        shell.browser.addressText = "https://worktree.example"
        viewModel.selectedDirectory = nil
        await flushBrowserContextUpdates()
        XCTAssertTrue(shell.browser.webView === mainPage)
        XCTAssertEqual(shell.browser.addressText, "https://main.example")

        // The descriptor/project/directory stay identical; only the retained connection UUID changes.
        let replacement = try await backend.connect()
        XCTAssertEqual(replacement.descriptor, firstConnection.descriptor)
        firstConnection.close()
        viewModel.backendConnection = replacement
        await flushBrowserContextUpdates()
        XCTAssertFalse(shell.browser.webView === mainPage)
        XCTAssertEqual(shell.browser.addressText, "")
        XCTAssertNil(mainPage.navigationDelegate)
        XCTAssertNil(worktreePage.navigationDelegate)
        viewModel.selectedDirectory = "/tmp/worktree"
        await flushBrowserContextUpdates()
        XCTAssertFalse(shell.browser.webView === worktreePage)
        XCTAssertEqual(shell.browser.addressText, "")

        let replacementPage = shell.browser.webView
        let replacementDataStore = replacementPage.configuration.websiteDataStore
        viewModel.isConnected = false
        await flushBrowserContextUpdates()
        XCTAssertNil(replacementPage.navigationDelegate)
        XCTAssertEqual(shell.browser.presentation, .closed)
        XCTAssertFalse(shell.browser.isLoading)
        XCTAssertFalse(shell.browser.webView.configuration.websiteDataStore === replacementDataStore)

        let offlinePage = shell.browser.webView
        replacement.close()
        viewModel.backendConnection = nil
        await flushBrowserContextUpdates()
        XCTAssertNil(offlinePage.navigationDelegate)
        XCTAssertFalse(shell.browser.webView === offlinePage)
        shell.browser.clearAllBrowserSessions()
    }

    private func flushBrowserContextUpdates() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    private func makeProject(id: String = "project", vcs: String? = nil) -> OpenCodeProject {
        OpenCodeProject(
            id: id,
            worktree: "/tmp/\(id)",
            vcs: vcs,
            name: "Project",
            sandboxes: nil,
            icon: nil,
            time: nil
        )
    }

    private func makeSession() -> OpenCodeSession {
        OpenCodeSession(
            id: "session",
            title: "Session",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
    }

    private func makeMessage() -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "message", role: "assistant", sessionID: "session", time: nil, agent: nil, model: nil),
            parts: []
        )
    }
}

@MainActor
final class ProjectStoreTests: XCTestCase {
    func testProjectsDefaultToVisibleAndServerOrder() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(ids: ["a", "b", "c"], userDefaults: userDefaults)

        XCTAssertEqual(store.orderedProjects(scopeKey: "server").map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.visibleProjects(scopeKey: "server").map(\.id), ["a", "b", "c"])
    }

    func testVisibilityIsScopedAndPersisted() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(ids: ["a", "b"], userDefaults: userDefaults)
        let hiddenProject = store.projects[1]

        store.setProjectVisibility(hiddenProject, isVisible: false, scopeKey: "server-a")

        XCTAssertEqual(store.visibleProjects(scopeKey: "server-a").map(\.id), ["a"])
        XCTAssertEqual(store.visibleProjects(scopeKey: "server-b").map(\.id), ["a", "b"])

        let reloaded = ProjectStore(projects: store.projects, userDefaults: userDefaults)
        XCTAssertEqual(reloaded.visibleProjects(scopeKey: "server-a").map(\.id), ["a"])
    }

    func testReorderingPersistsAndAppendsNewProjects() {
        let (userDefaults, suiteName) = makeUserDefaults()
        defer { userDefaults.removePersistentDomain(forName: suiteName) }
        let store = makeStore(ids: ["a", "b", "c"], userDefaults: userDefaults)

        store.moveProjects(fromOffsets: IndexSet(integer: 0), toOffset: 3, scopeKey: "server")
        XCTAssertEqual(store.orderedProjects(scopeKey: "server").map(\.id), ["b", "c", "a"])

        let reloaded = ProjectStore(projects: makeProjects(ids: ["a", "b", "c", "d"]), userDefaults: userDefaults)
        XCTAssertEqual(reloaded.orderedProjects(scopeKey: "server").map(\.id), ["b", "c", "a", "d"])
    }

    private func makeStore(ids: [String], userDefaults: UserDefaults) -> ProjectStore {
        ProjectStore(projects: makeProjects(ids: ids), userDefaults: userDefaults)
    }

    private func makeUserDefaults() -> (UserDefaults, String) {
        let suiteName = "ProjectStoreTests.\(UUID().uuidString)"
        return (UserDefaults(suiteName: suiteName)!, suiteName)
    }

    private func makeProjects(ids: [String]) -> [OpenCodeProject] {
        ids.map {
            OpenCodeProject(id: $0, worktree: "/tmp/\($0)", vcs: "git", name: $0, sandboxes: nil, icon: nil, time: nil)
        }
    }
}
