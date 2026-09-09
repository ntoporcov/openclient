import XCTest
@testable import OpenClient

@MainActor
final class CoordinatorTests: XCTestCase {
    override func setUp() {
        super.setUp()
        CoordinatorMockURLProtocol.requestHandler = nil
    }

    func testConnectionCoordinatorConnectsAfterBootstrap() async {
        CoordinatorMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/global/health":
                return try jsonResponse(for: request, body: #"{"healthy":true,"version":"1.2.3"}"#)
            case "/project":
                return try jsonResponse(for: request, body: "[]")
            case "/project/current":
                return try jsonResponse(for: request, body: "null")
            default:
                throw OpenCodeAPIError.invalidURL
            }
        }
        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)
        var appliedBootstrap = false

        await coordinator.connect(
            client: makeClient(),
            applyLegacyBootstrap: { _ in
                XCTAssertEqual(store.apiProfile, .legacy)
                appliedBootstrap = true
            },
            applyV2Connection: { XCTFail("Legacy connection must not bootstrap v2") },
            handleFailure: { XCTFail("Connection should succeed") }
        )

        XCTAssertTrue(appliedBootstrap)
        XCTAssertTrue(store.isConnected)
        XCTAssertEqual(store.backendMode, .server)
        XCTAssertEqual(store.serverVersion, "1.2.3")
        XCTAssertFalse(store.isLoading)
    }

    func testInvalidatedConnectionAttemptCannotFinishOrOverwriteNewerState() async {
        CoordinatorMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/global/health":
                return try jsonResponse(for: request, body: #"{"healthy":true,"version":"old"}"#)
            default:
                throw OpenCodeAPIError.invalidURL
            }
        }
        let store = ConnectionStore(backendMode: .cachedServer)
        let coordinator = ConnectionCoordinator(connectionStore: store)
        var attemptChecks = 0
        var handledFailure = false

        await coordinator.connect(
            client: makeClient(),
            isCurrentAttempt: {
                attemptChecks += 1
                guard attemptChecks == 1 else {
                    store.applyErrorMessage("newer attempt")
                    return false
                }
                return true
            },
            applyLegacyBootstrap: { _ in XCTFail("Stale attempt should not bootstrap") },
            applyV2Connection: { XCTFail("Stale attempt should not bootstrap") },
            handleFailure: { handledFailure = true }
        )

        XCTAssertFalse(handledFailure)
        XCTAssertEqual(store.backendMode, .cachedServer)
        XCTAssertEqual(store.errorMessage, "newer attempt")
        XCTAssertTrue(store.isLoading)
        XCTAssertFalse(store.isConnected)
    }

    func testCachedConnectionFallbackCanPreserveRetryFailure() {
        let store = ConnectionStore()
        store.applyConnectionFailure(OpenCodeAPIError.timedOut)

        store.applyCachedServerConnection(preservingError: true)

        XCTAssertEqual(store.backendMode, .cachedServer)
        XCTAssertEqual(store.errorMessage, OpenCodeAPIError.timedOut.localizedDescription)
    }

    func testCachedConnectionRequiresExplicitOfferAcceptance() {
        let store = ConnectionStore()
        store.applyConnectionFailure(OpenCodeAPIError.timedOut)

        store.offerCachedServerConnection()

        XCTAssertEqual(store.backendMode, .none)
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(store.isOfferingCachedServerConnection)
        XCTAssertEqual(store.errorMessage, OpenCodeAPIError.timedOut.localizedDescription)

        store.applyCachedServerConnection()

        XCTAssertEqual(store.backendMode, .cachedServer)
        XCTAssertFalse(store.isOfferingCachedServerConnection)
        XCTAssertNil(store.errorMessage)
    }

    func testStartingAnotherConnectionDismissesCachedConnectionOffer() {
        let store = ConnectionStore()
        store.offerCachedServerConnection()

        store.beginConnecting()

        XCTAssertFalse(store.isOfferingCachedServerConnection)
        XCTAssertTrue(store.isLoading)
    }

    func testConnectionCoordinatorForcedV2SkipsLegacyBootstrap() async {
        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)
        let client = makeClient(apiPreference: .v2)
        var appliedLegacyBootstrap = false
        var appliedV2Connection = false
        var failed = false
        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            return try jsonResponse(
                for: request,
                body: #"{"healthy":true,"version":"0.0.0-next-17055","pid":42}"#
            )
        }

        await coordinator.connect(
            client: client,
            applyLegacyBootstrap: { _ in appliedLegacyBootstrap = true },
            applyV2Connection: {
                XCTAssertEqual(store.apiProfile, .v2)
                appliedV2Connection = true
            },
            handleFailure: { failed = true }
        )

        XCTAssertFalse(appliedLegacyBootstrap)
        XCTAssertTrue(appliedV2Connection)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.backendMode, .serverV2)
        XCTAssertEqual(store.apiProfile, .v2)
        XCTAssertTrue(store.isConnected)
    }

    func testConnectionCoordinatorFailsWhenV2NavigationBootstrapFails() async {
        struct NavigationError: Error {}

        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)
        let client = makeClient(apiPreference: .v2)
        var appliedLegacyBootstrap = false
        var failed = false
        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            return try jsonResponse(
                for: request,
                body: #"{"healthy":true,"version":"0.0.0-next-17055","pid":42}"#
            )
        }

        await coordinator.connect(
            client: client,
            applyLegacyBootstrap: { _ in appliedLegacyBootstrap = true },
            applyV2Connection: { throw NavigationError() },
            handleFailure: { failed = true }
        )

        XCTAssertFalse(appliedLegacyBootstrap)
        XCTAssertTrue(failed)
        XCTAssertEqual(store.backendMode, .none)
        XCTAssertNil(store.apiProfile)
        XCTAssertFalse(store.isConnected)
    }

    func testConnectionCoordinatorAutomaticFallsBackForLegacyHealthShape() async {
        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)
        let client = makeClient(apiPreference: .automatic)
        var appliedLegacyBootstrap = false
        var appliedV2Connection = false
        var failed = false
        CoordinatorMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/health":
                return try jsonResponse(for: request, body: #"{"healthy":true}"#)
            case "/global/health":
                return try jsonResponse(for: request, body: #"{"healthy":true,"version":"1.18.7"}"#)
            case "/project":
                return try jsonResponse(for: request, body: "[]")
            case "/project/current":
                return try jsonResponse(for: request, statusCode: 404, body: "{}")
            default:
                XCTFail("Unexpected request: \(request.url?.absoluteString ?? "nil")")
                return try jsonResponse(for: request, statusCode: 404, body: "{}")
            }
        }

        await coordinator.connect(
            client: client,
            applyLegacyBootstrap: { _ in appliedLegacyBootstrap = true },
            applyV2Connection: { appliedV2Connection = true },
            handleFailure: { failed = true }
        )

        XCTAssertTrue(appliedLegacyBootstrap)
        XCTAssertFalse(appliedV2Connection)
        XCTAssertFalse(failed)
        XCTAssertEqual(store.backendMode, .server)
        XCTAssertEqual(store.apiProfile, .legacy)
        XCTAssertTrue(store.isConnected)
    }

    func testConnectionCoordinatorAutomaticDoesNotFallbackAfterAuthenticationFailure() async {
        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)
        let client = makeClient(apiPreference: .automatic)
        var appliedSuccess = false
        var failed = false
        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            return try jsonResponse(for: request, statusCode: 401, body: "{}")
        }

        await coordinator.connect(
            client: client,
            applyLegacyBootstrap: { _ in appliedSuccess = true },
            applyV2Connection: { appliedSuccess = true },
            handleFailure: { failed = true }
        )

        XCTAssertFalse(appliedSuccess)
        XCTAssertTrue(failed)
        XCTAssertEqual(store.backendMode, .none)
        XCTAssertNil(store.apiProfile)
        XCTAssertFalse(store.isConnected)
    }

    func testV2BootstrapCancellationClearsResolvedProfile() async {
        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            return try jsonResponse(for: request, body: #"{"healthy":true,"version":"next","pid":42}"#)
        }
        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)
        var handledFailure = false

        await coordinator.connect(
            client: makeClient(apiPreference: .v2),
            applyLegacyBootstrap: { _ in XCTFail("Must not use legacy bootstrap") },
            applyV2Connection: {
                XCTAssertEqual(store.apiProfile, .v2)
                throw CancellationError()
            },
            handleFailure: { handledFailure = true }
        )

        XCTAssertTrue(handledFailure)
        XCTAssertNil(store.apiProfile)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.backendMode, .none)
        XCTAssertFalse(store.isConnected)
        XCTAssertFalse(store.isLoading)
    }

    func testInvalidatedV2BootstrapCannotOverwriteNewerConnection() async {
        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            return try jsonResponse(for: request, body: #"{"healthy":true,"version":"old","pid":42}"#)
        }
        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)
        var isCurrent = true

        await coordinator.connect(
            client: makeClient(apiPreference: .v2),
            isCurrentAttempt: { isCurrent },
            applyLegacyBootstrap: { _ in XCTFail("Must not use legacy bootstrap") },
            applyV2Connection: {
                isCurrent = false
                store.applySuccessfulServerConnection(version: "new", healthy: true)
                store.finishConnecting()
            },
            handleFailure: { XCTFail("Stale attempt must not handle failure") }
        )

        XCTAssertEqual(store.apiProfile, .legacy)
        XCTAssertEqual(store.backendMode, .server)
        XCTAssertEqual(store.serverVersion, "new")
        XCTAssertTrue(store.isConnected)
        XCTAssertFalse(store.isLoading)
    }

    func testForcedV2UnavailableDoesNotFallBackToLegacy() async {
        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/api/health")
            return try jsonResponse(for: request, statusCode: 404, body: "{}")
        }
        let store = ConnectionStore()
        let coordinator = ConnectionCoordinator(connectionStore: store)

        await coordinator.connect(
            client: makeClient(apiPreference: .v2),
            applyLegacyBootstrap: { _ in XCTFail("Forced v2 must not fall back") },
            applyV2Connection: { XCTFail("Unavailable v2 must not bootstrap") },
            handleFailure: {}
        )

        XCTAssertEqual(store.errorMessage, OpenCodeAPIError.v2Unavailable.localizedDescription)
        XCTAssertNil(store.apiProfile)
        XCTAssertFalse(store.isConnected)
    }

    func testStartingConnectionClearsPreviousV2ProfileAndVersion() {
        let store = ConnectionStore()
        store.applySuccessfulV2Connection(version: "old", healthy: true)

        store.beginConnecting()

        XCTAssertNil(store.apiProfile)
        XCTAssertEqual(store.serverVersion, "")
        XCTAssertFalse(store.isConnected)
        XCTAssertTrue(store.isLoading)
    }

    func testMCPFacadeUsesNegotiatedV2RoutesForAutomaticConnections() async {
        let disconnected = expectation(description: "v2 MCP disconnect")
        CoordinatorMockURLProtocol.requestHandler = { request in
            switch request.url?.path {
            case "/api/mcp":
                return try jsonResponse(for: request, body: #"{"data":[{"name":"tools","status":{"status":"connected"}}]}"#)
            case "/api/mcp/tools/disconnect":
                XCTAssertEqual(request.httpMethod, "POST")
                disconnected.fulfill()
                return try jsonResponse(for: request, statusCode: 204, body: "")
            default:
                XCTFail("Unexpected legacy request: \(request.url?.path ?? "nil")")
                throw OpenCodeAPIError.invalidURL
            }
        }
        let store = MCPStore()
        let client = makeClient(apiPreference: .automatic)
        let facade = MCPFacade(store: store, clientProvider: { client }, directoryProvider: { "/repo" }, apiProfileProvider: { .v2 })

        await facade.reload()
        XCTAssertEqual(facade.snapshot.connectedServerCount, 1)
        await facade.toggleServer(name: "tools")

        await fulfillment(of: [disconnected], timeout: 1)
        XCTAssertNil(facade.snapshot.errorMessage)
        XCTAssertTrue(facade.snapshot.togglingServerNames.isEmpty)
    }

    func testMCPFacadeDoesNotHydrateBeforeProfileNegotiation() async {
        CoordinatorMockURLProtocol.requestHandler = { _ in
            XCTFail("No API request is allowed before negotiation")
            throw OpenCodeAPIError.invalidURL
        }
        let client = makeClient(apiPreference: .automatic)
        let facade = MCPFacade(store: MCPStore(), clientProvider: { client }, directoryProvider: { "/repo" }, apiProfileProvider: { nil })

        await facade.reload()
        await facade.toggleServer(name: "tools")

        XCTAssertFalse(facade.snapshot.isLoading)
        XCTAssertTrue(facade.snapshot.servers.isEmpty)
    }

    func testProjectFilesFacadeUsesV2ForTreeContentAndGit() async throws {
        CoordinatorMockURLProtocol.requestHandler = { request in
            let body: String
            switch request.url?.path {
            case "/api/fs/list":
                body = #"{"location":{"directory":"/repo","project":{"id":"p","directory":"/repo","canonical":"/repo"}},"data":[{"path":"main.swift","type":"file"}]}"#
            case "/api/fs/read/main.swift": body = "let value = 1"
            case "/api/vcs": body = #"{"data":{"branch":{"current":"feature","default":"main"}}}"#
            case "/api/vcs/status": body = #"{"data":[]}"#
            case "/api/vcs/diff": body = #"{"data":[]}"#
            default:
                XCTFail("Unexpected legacy request: \(request.url?.path ?? "nil")")
                throw OpenCodeAPIError.invalidURL
            }
            return try jsonResponse(for: request, body: body)
        }
        let client = makeClient(apiPreference: .automatic)
        let store = ProjectFilesStore()
        let facade = ProjectFilesFacade(
            store: store, clientProvider: { client }, hasGitProjectProvider: { true },
            effectiveSelectedDirectoryProvider: { "/repo" }, currentProjectProvider: { nil },
            workspaceDirectoriesProvider: { ["/unsupported-worktree"] }, workspaceDisplayNameProvider: { $0 },
            workspaceKeyProvider: { $0 }, isFilesPresentedProvider: { true }, preserveNavigationState: {},
            showFilesRoute: {}, apiProfileProvider: { .v2 }
        )

        await facade.reloadGitViewData(force: true)
        await facade.reloadFileTree(force: true)
        let node = try XCTUnwrap(facade.snapshot.visibleRows.first?.node)
        store.selectProjectFile(node, isChanged: false)
        await facade.loadSelectedFileContentIfNeeded()

        XCTAssertEqual(facade.snapshot.vcsInfo?.branch, "feature")
        XCTAssertEqual(facade.snapshot.selectedFileContent?.content, "let value = 1")
        XCTAssertEqual(facade.workspaceDirectories, ["/unsupported-worktree"])
        XCTAssertNil(facade.snapshot.vcsErrorMessage)
        XCTAssertNil(facade.snapshot.fileTreeErrorMessage)
        XCTAssertNil(facade.snapshot.fileContentErrorMessage)
    }

    func testEventSyncCoordinatorMatchesSelectedSessionEvents() {
        let coordinator = EventSyncCoordinator()
        let selected = "ses_selected"

        XCTAssertTrue(coordinator.eventAffectsSelectedSession(
            .sessionStatus(sessionID: selected, status: "busy"),
            selectedSessionID: selected,
            selectedMessages: [],
            hasGitProject: false
        ))

        XCTAssertTrue(coordinator.eventAffectsSelectedSession(
            .messageUpdated(OpenCodeMessage(id: "msg_1", role: "assistant", sessionID: selected, time: nil, agent: nil, model: nil)),
            selectedSessionID: selected,
            selectedMessages: [],
            hasGitProject: false
        ))

        XCTAssertFalse(coordinator.eventAffectsSelectedSession(
            .messagePartDelta(sessionID: "ses_other", messageID: "msg_1", partID: "part_1", field: "text", delta: "Hello"),
            selectedSessionID: selected,
            selectedMessages: [],
            hasGitProject: false
        ))
    }

    func testEventSyncCoordinatorMatchesRemovalEventsBySelectedMessages() {
        let coordinator = EventSyncCoordinator()
        let selectedMessages = [makeMessage(id: "msg_selected", sessionID: "ses_selected")]

        XCTAssertTrue(coordinator.eventAffectsSelectedSession(
            .messagePartRemoved(messageID: "msg_selected", partID: "part_1"),
            selectedSessionID: "ses_selected",
            selectedMessages: selectedMessages,
            hasGitProject: false
        ))

        XCTAssertFalse(coordinator.eventAffectsSelectedSession(
            .messagePartRemoved(messageID: "msg_other", partID: "part_1"),
            selectedSessionID: "ses_selected",
            selectedMessages: selectedMessages,
            hasGitProject: false
        ))
    }

    func testEventSyncCoordinatorHandlesNilSelectionAndVCS() {
        let coordinator = EventSyncCoordinator()

        XCTAssertTrue(coordinator.eventAffectsSelectedSession(
            .messagePartDelta(sessionID: "ses_any", messageID: "msg_1", partID: "part_1", field: "text", delta: "Hello"),
            selectedSessionID: nil,
            selectedMessages: [],
            hasGitProject: false
        ))

        XCTAssertTrue(coordinator.eventAffectsSelectedSession(
            .vcsBranchUpdated(branch: "main"),
            selectedSessionID: "ses_selected",
            selectedMessages: [],
            hasGitProject: true
        ))

        XCTAssertFalse(coordinator.eventAffectsSelectedSession(
            .vcsBranchUpdated(branch: "main"),
            selectedSessionID: "ses_selected",
            selectedMessages: [],
            hasGitProject: false
        ))
    }

    func testEventSyncCoordinatorExtractsSessionIDsFromSessionEvents() {
        let coordinator = EventSyncCoordinator()
        let session = makeSession(id: "ses_selected", directory: "/tmp/project")

        XCTAssertEqual(coordinator.sessionID(for: .sessionCreated(session)), "ses_selected")
        XCTAssertEqual(coordinator.sessionID(for: .sessionStatus(sessionID: "ses_selected", status: "busy")), "ses_selected")
        XCTAssertEqual(coordinator.sessionID(for: .sessionIdle(sessionID: "ses_selected")), "ses_selected")
        XCTAssertEqual(coordinator.sessionID(for: .sessionError(sessionID: "ses_selected", message: "error")), "ses_selected")
    }

    func testEventSyncCoordinatorExtractsSessionIDsFromMessageAndInteractionEvents() {
        let coordinator = EventSyncCoordinator()
        let message = OpenCodeMessage(id: "msg_1", role: "assistant", sessionID: "ses_selected", time: nil, agent: nil, model: nil)
        let part = OpenCodePart(id: "part_1", messageID: "msg_1", sessionID: "ses_selected", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "")
        let permission = OpenCodePermission(id: "perm_1", sessionID: "ses_selected", permission: "edit", patterns: [], always: nil, metadata: nil, tool: nil)
        let question = OpenCodeQuestionRequest(id: "q_1", sessionID: "ses_selected", questions: [], tool: nil)

        XCTAssertEqual(coordinator.sessionID(for: .messageUpdated(message)), "ses_selected")
        XCTAssertEqual(coordinator.sessionID(for: .messagePartUpdated(part)), "ses_selected")
        XCTAssertEqual(coordinator.sessionID(for: .messagePartDelta(sessionID: "ses_selected", messageID: "msg_1", partID: "part_1", field: "text", delta: "Hi")), "ses_selected")
        XCTAssertEqual(coordinator.sessionID(for: .permissionAsked(permission)), "ses_selected")
        XCTAssertEqual(coordinator.sessionID(for: .questionAsked(question)), "ses_selected")
    }

    func testEventSyncCoordinatorReturnsNilForGlobalAndVcsEvents() {
        let coordinator = EventSyncCoordinator()

        XCTAssertNil(coordinator.sessionID(for: .serverConnected))
        XCTAssertNil(coordinator.sessionID(for: .vcsBranchUpdated(branch: "main")))
        XCTAssertNil(coordinator.sessionID(for: .fileWatcherUpdated(file: "Sources/File.swift")))
    }

    func testLiveActivityCoordinatorParsesOpenDeepLink() throws {
        let url = try XCTUnwrap(OpenCodeChatActivityDeepLink.openAppURL(
            sessionID: "ses_1",
            directory: "/tmp/project",
            workspaceID: "wrk_1"
        ))

        let deepLink = LiveActivityCoordinator.deepLink(from: url)

        XCTAssertEqual(deepLink, LiveActivityDeepLink(
            sessionID: "ses_1",
            directory: "/tmp/project",
            workspaceID: "wrk_1",
            action: .open
        ))
    }

    func testLiveActivityCoordinatorNormalizesRootDirectoryDeepLinkToGlobalRoute() throws {
        let url = try XCTUnwrap(OpenCodeChatActivityDeepLink.openAppURL(
            sessionID: "ses_global",
            directory: "/",
            workspaceID: nil
        ))

        let deepLink = try XCTUnwrap(LiveActivityCoordinator.deepLink(from: url))
        let resolution = LiveActivityCoordinator.resolveSession(
            sessionID: deepLink.sessionID,
            directory: deepLink.directory,
            workspaceID: deepLink.workspaceID,
            knownSessions: [],
            selectedSession: nil,
            activitySnapshot: LiveActivitySessionSnapshot(
                sessionID: "ses_global",
                sessionTitle: "Global",
                workspaceID: nil,
                directory: "/"
            )
        )

        XCTAssertNil(deepLink.directory)
        XCTAssertNil(resolution.session.directory)
        XCTAssertTrue(resolution.session.isGlobalScopeSession)
    }

    func testLiveActivityCoordinatorParsesPermissionAndQuestionDeepLinks() throws {
        let permissionURL = try XCTUnwrap(OpenCodeChatActivityDeepLink.permissionURL(
            sessionID: "ses_1",
            requestID: "perm_1",
            reply: "allow",
            directory: "/tmp/project"
        ))
        let questionURL = try XCTUnwrap(OpenCodeChatActivityDeepLink.questionURL(
            sessionID: "ses_1",
            requestID: "q_1",
            answer: "Yes",
            directory: "/tmp/project"
        ))

        XCTAssertEqual(LiveActivityCoordinator.deepLink(from: permissionURL)?.action, .permission(requestID: "perm_1", reply: "allow"))
        XCTAssertEqual(LiveActivityCoordinator.deepLink(from: questionURL)?.action, .question(requestID: "q_1", answer: "Yes"))
    }

    func testLiveActivityCoordinatorRejectsInvalidDeepLinks() {
        XCTAssertNil(LiveActivityCoordinator.deepLink(from: URL(string: "openclient://other/session/ses_1")!))
        XCTAssertNil(LiveActivityCoordinator.deepLink(from: URL(string: "openclient://live-activity/project/ses_1")!))
        XCTAssertNil(LiveActivityCoordinator.deepLink(from: URL(string: "openclient://live-activity/session/ses_1?action=permission")!))
    }

    func testLiveActivityCoordinatorResolvesExistingAndFallbackSessions() {
        let known = makeSession(id: "ses_known", directory: "/tmp/project")

        let existing = LiveActivityCoordinator.resolveSession(
            sessionID: known.id,
            directory: nil,
            workspaceID: nil,
            knownSessions: [known],
            selectedSession: nil,
            activitySnapshot: nil
        )
        let activityFallback = LiveActivityCoordinator.resolveSession(
            sessionID: "ses_activity",
            directory: nil,
            workspaceID: nil,
            knownSessions: [],
            selectedSession: nil,
            activitySnapshot: LiveActivitySessionSnapshot(
                sessionID: "ses_activity",
                sessionTitle: "From Activity",
                workspaceID: "wrk_1",
                directory: "/tmp/activity"
            )
        )
        let urlFallback = LiveActivityCoordinator.resolveSession(
            sessionID: "ses_url",
            directory: "/tmp/url",
            workspaceID: "wrk_2",
            knownSessions: [],
            selectedSession: nil,
            activitySnapshot: nil
        )

        XCTAssertEqual(existing, .existing(known))
        XCTAssertEqual(activityFallback.session.title, "From Activity")
        XCTAssertEqual(activityFallback.session.directory, "/tmp/activity")
        XCTAssertEqual(urlFallback.session.title, "Session")
        XCTAssertEqual(urlFallback.session.directory, "/tmp/url")
    }

    func testEventSyncCoordinatorAppliesSelectedSessionRegardlessOfDirectory() {
        let coordinator = EventSyncCoordinator()

        XCTAssertTrue(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "/other/project",
            eventSessionID: "ses_selected",
            selectedSessionID: "ses_selected",
            selectedSessionDirectory: "/tmp/project",
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: []
        ))
    }

    func testEventSyncCoordinatorAppliesAcceptedDirectoriesAndRejectsOtherDirectories() {
        let coordinator = EventSyncCoordinator()

        XCTAssertTrue(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "/tmp/project",
            eventSessionID: nil,
            selectedSessionID: nil,
            selectedSessionDirectory: nil,
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: []
        ))

        XCTAssertTrue(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "/tmp/workspace",
            eventSessionID: nil,
            selectedSessionID: nil,
            selectedSessionDirectory: "/tmp/workspace",
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: []
        ))

        XCTAssertFalse(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "/tmp/other",
            eventSessionID: nil,
            selectedSessionID: nil,
            selectedSessionDirectory: "/tmp/workspace",
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: []
        ))
    }

    func testEventSyncCoordinatorHandlesGlobalEventsByScope() {
        let coordinator = EventSyncCoordinator()

        XCTAssertTrue(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "global",
            eventSessionID: nil,
            selectedSessionID: nil,
            selectedSessionDirectory: nil,
            effectiveSelectedDirectory: nil,
            activeLiveActivitySessionIDs: []
        ))

        XCTAssertTrue(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "global",
            eventSessionID: "ses_background",
            selectedSessionID: "ses_selected",
            selectedSessionDirectory: "/tmp/project",
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: []
        ))

        XCTAssertFalse(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "global",
            eventSessionID: nil,
            selectedSessionID: "ses_selected",
            selectedSessionDirectory: "/tmp/project",
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: []
        ))
    }

    func testEventSyncCoordinatorAppliesActiveLiveActivitySessionEvents() {
        let coordinator = EventSyncCoordinator()

        XCTAssertTrue(coordinator.shouldApplyDirectoryEvent(
            eventDirectory: "/tmp/other",
            eventSessionID: "ses_live",
            selectedSessionID: "ses_selected",
            selectedSessionDirectory: "/tmp/project",
            effectiveSelectedDirectory: "/tmp/project",
            activeLiveActivitySessionIDs: ["ses_live"]
        ))
    }

    func testEventSyncCoordinatorAppliesDirectoryEventsToSnapshot() {
        let coordinator = EventSyncCoordinator()
        let session = makeSession(id: "ses_selected", directory: "/tmp/project")
        let state = EventSyncCoordinator.DirectoryEventState(
            sessions: [],
            selectedSession: nil,
            sessionStatuses: [:],
            syncState: OpenCodeDirectorySyncState(),
            messages: [],
            todos: [],
            permissions: [],
            questions: []
        )

        let application = coordinator.applyDirectoryEvents([
            .sessionCreated(session),
            .sessionStatus(sessionID: "ses_selected", status: "busy"),
        ], to: state)

        XCTAssertEqual(application.state.sessions.map(\.id), ["ses_selected"])
        XCTAssertEqual(application.state.sessionStatuses["ses_selected"], "busy")
        XCTAssertEqual(application.results.count, 2)
        XCTAssertEqual(application.messageApplyCount, 0)
    }

    func testEventSyncCoordinatorCountsMessageApplications() {
        let coordinator = EventSyncCoordinator()
        let selected = makeSession(id: "ses_selected", directory: "/tmp/project")
        let part = OpenCodePart(id: "part_1", messageID: "msg_1", sessionID: "ses_selected", type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "")
        var syncState = OpenCodeDirectorySyncState()
        _ = syncState.applyMessageUpdated(OpenCodeMessage(id: "msg_1", role: "assistant", sessionID: "ses_selected", time: nil, agent: nil, model: nil))
        _ = syncState.applyPartUpdated(part)
        let state = EventSyncCoordinator.DirectoryEventState(
            sessions: [selected],
            selectedSession: selected,
            sessionStatuses: [:],
            syncState: syncState,
            messages: [],
            todos: [],
            permissions: [],
            questions: []
        )

        let application = coordinator.applyDirectoryEvents([
            .messagePartDelta(sessionID: "ses_selected", messageID: "msg_1", partID: "part_1", field: "text", delta: "Hello"),
            .messagePartDelta(sessionID: "ses_selected", messageID: "msg_1", partID: "part_1", field: "text", delta: " world"),
        ], to: state)

        XCTAssertEqual(application.messageApplyCount, 2)
        XCTAssertEqual(application.state.messages.first?.parts.first?.text, "Hello world")
    }

    func testEventSyncCoordinatorDoesNotNeedVisibleMessagesToApplySelectedDelta() {
        let coordinator = EventSyncCoordinator()
        let selected = makeSession(id: "ses_selected", directory: "/tmp/project")
        let message = OpenCodeMessage(id: "msg_1", role: "assistant", sessionID: selected.id, time: nil, agent: nil, model: nil)
        let part = OpenCodePart(id: "part_1", messageID: "msg_1", sessionID: selected.id, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: "")
        var syncState = OpenCodeDirectorySyncState()
        _ = syncState.applyMessageUpdated(message)
        _ = syncState.applyPartUpdated(part)

        let staleVisibleMessage = OpenCodeMessageEnvelope.local(
            role: "assistant",
            text: ".",
            messageID: "stale_msg",
            sessionID: selected.id,
            partID: "stale_part"
        )
        let state = EventSyncCoordinator.DirectoryEventState(
            sessions: [selected],
            selectedSession: selected,
            sessionStatuses: [:],
            syncState: syncState,
            messages: [staleVisibleMessage],
            todos: [],
            permissions: [],
            questions: []
        )

        let application = coordinator.applyDirectoryEvents([
            .messagePartDelta(sessionID: selected.id, messageID: "msg_1", partID: "part_1", field: "text", delta: "Live text"),
        ],
            to: state
        )

        XCTAssertEqual(application.state.messages.map(\.id), ["msg_1"])
        XCTAssertEqual(application.state.messages.first?.parts.first?.text, "Live text")
    }

    func testEventSyncCoordinatorProjectsSelectedPartWhenShellIsMissing() {
        let coordinator = EventSyncCoordinator()
        let selected = makeSession(id: "ses_selected", directory: "/tmp/project")
        let user = OpenCodeMessageEnvelope.local(
            role: "user",
            text: "Start",
            messageID: "msg_user",
            sessionID: selected.id,
            partID: "part_user"
        )
        var syncState = OpenCodeDirectorySyncState()
        syncState.replaceMessages([user], forSessionID: selected.id)

        let part = OpenCodePart(
            id: "part_reasoning",
            messageID: "msg_assistant",
            sessionID: selected.id,
            type: "reasoning",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: ""
        )
        let state = EventSyncCoordinator.DirectoryEventState(
            sessions: [selected],
            selectedSession: selected,
            sessionStatuses: [selected.id: "busy"],
            syncState: syncState,
            messages: [user],
            todos: [],
            permissions: [],
            questions: []
        )

        let application = coordinator.applyDirectoryEvents([
            .messagePartUpdated(part),
            .messagePartDelta(sessionID: selected.id, messageID: "msg_assistant", partID: "part_reasoning", field: "text", delta: "Thinking"),
        ], to: state)

        XCTAssertEqual(Set(application.state.messages.map(\.id)), Set(["msg_user", "msg_assistant"]))
        let projectedAssistant = application.state.messages.first { $0.id == "msg_assistant" }
        XCTAssertEqual(projectedAssistant?.info.role, "assistant")
        XCTAssertEqual(projectedAssistant?.info.parentID, "msg_user")
        XCTAssertEqual(projectedAssistant?.parts.first?.text, "Thinking")
        XCTAssertEqual(application.state.syncState.partsByMessageID["msg_assistant"]?.first?.type, "reasoning")
        XCTAssertEqual(application.state.syncState.partsByMessageID["msg_assistant"]?.first?.text, "Thinking")

        let withShell = coordinator.applyDirectoryEvents([
            .messageUpdated(OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: selected.id, time: nil, agent: nil, model: nil)),
        ], to: application.state)
        XCTAssertEqual(withShell.state.messages.map(\.id), ["msg_assistant", "msg_user"])
        let assistant = withShell.state.messages.first { $0.id == "msg_assistant" }
        XCTAssertEqual(assistant?.parts.first?.type, "reasoning")
        XCTAssertEqual(assistant?.parts.first?.text, "Thinking")
    }

    func testEventSyncCoordinatorStoresSelectedToolPartUntilMessageShellArrives() {
        let coordinator = EventSyncCoordinator()
        let selected = makeSession(id: "ses_selected", directory: "/tmp/project")
        let toolPart = OpenCodePart(
            id: "part_tool",
            messageID: "msg_assistant",
            sessionID: selected.id,
            type: "tool",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: "bash",
            callID: "call_1",
            state: nil,
            text: nil
        )
        let state = EventSyncCoordinator.DirectoryEventState(
            sessions: [selected],
            selectedSession: selected,
            sessionStatuses: [selected.id: "busy"],
            syncState: OpenCodeDirectorySyncState(),
            messages: [],
            todos: [],
            permissions: [],
            questions: []
        )

        let application = coordinator.applyDirectoryEvents([
            .messagePartUpdated(toolPart),
        ], to: state)

        XCTAssertEqual(application.state.messages.map(\.id), ["msg_assistant"])
        XCTAssertEqual(application.state.messages.first?.parts.first?.type, "tool")
        XCTAssertEqual(application.state.syncState.partsByMessageID["msg_assistant"]?.first?.type, "tool")
        XCTAssertEqual(application.state.syncState.partsByMessageID["msg_assistant"]?.first?.tool, "bash")

        let withShell = coordinator.applyDirectoryEvents([
            .messageUpdated(OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: selected.id, time: nil, agent: nil, model: nil)),
        ], to: application.state)
        XCTAssertEqual(withShell.state.messages.map(\.id), ["msg_assistant"])
        XCTAssertEqual(withShell.state.messages.first?.parts.first?.type, "tool")
        XCTAssertEqual(withShell.state.messages.first?.parts.first?.tool, "bash")
    }

    func testSessionCoordinatorCreateSessionTrimsTitleAndUsesDirectoryScope() async throws {
        let expectation = expectation(description: "create session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"title":"New Session"}"#)
            expectation.fulfill()

            return try jsonResponse(for: request, body: #"{"id":"ses_new","title":"New Session","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null}"#)
        }

        let session = try await coordinator.createSession(client: client, title: "  New Session\n", directory: "/tmp/project")

        XCTAssertEqual(session.id, "ses_new")
        XCTAssertEqual(session.title, "New Session")
        XCTAssertEqual(session.directory, "/tmp/project")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorCreateSessionSendsNilTitleForWhitespace() async throws {
        let expectation = expectation(description: "blank create session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session")
            XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{}"#)
            expectation.fulfill()

            return try jsonResponse(for: request, body: #"{"id":"ses_blank","title":null,"workspaceID":null,"directory":null,"projectID":null,"parentID":null}"#)
        }

        let session = try await coordinator.createSession(client: client, title: "  \n", directory: nil)

        XCTAssertEqual(session.id, "ses_blank")
        XCTAssertNil(session.title)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitCreateUsesPreparedTitleAndDirectory() async throws {
        let expectation = expectation(description: "prepared create session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let submission = coordinator.prepareCreateSession(title: "  New Session  ", directory: "/tmp/project")

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"title":"New Session"}"#)
            expectation.fulfill()

            return try jsonResponse(for: request, body: #"{"id":"ses_new","title":"New Session","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null}"#)
        }

        let session = try await coordinator.submitCreate(client: client, submission: submission)

        XCTAssertEqual(session.id, "ses_new")
        XCTAssertEqual(session.title, "New Session")
        XCTAssertEqual(session.directory, "/tmp/project")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorPrepareCreateUsesNilTitleForWhitespace() {
        let coordinator = SessionCoordinator()

        let submission = coordinator.prepareCreateSession(title: "  \n", directory: nil)

        XCTAssertNil(submission.title)
        XCTAssertNil(submission.directory)
    }

    func testSessionCoordinatorDeleteSessionUsesDeleteEndpoint() async throws {
        let expectation = expectation(description: "delete session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_delete")
            XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(request.httpMethod, "DELETE")
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.deleteSession(client: client, sessionID: "ses_delete")

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitDeleteUsesPreparedScopedDeleteEndpoint() async throws {
        let expectation = expectation(description: "prepared delete session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let submission = coordinator.prepareDeleteSession(
            session: makeSession(id: "ses_delete", directory: "/tmp/project", workspaceID: "ws_123"),
            selectedDirectory: nil,
            currentProjectID: "proj_1"
        )

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_delete")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "DELETE")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.submitDelete(client: client, submission: submission)

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorRenameSessionTrimsTitleAndUsesPatchEndpoint() async throws {
        let expectation = expectation(description: "rename session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_rename")
            XCTAssertNil(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems)
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"title":"Renamed"}"#)
            expectation.fulfill()

            return try jsonResponse(for: request, body: #"{"id":"ses_rename","title":"Renamed","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null}"#)
        }

        let session = try await coordinator.renameSession(client: client, sessionID: "ses_rename", title: "  Renamed\n")

        XCTAssertEqual(session?.id, "ses_rename")
        XCTAssertEqual(session?.title, "Renamed")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitRenameUsesPreparedScopedPatchEndpoint() async throws {
        let expectation = expectation(description: "prepared rename session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let submission = try XCTUnwrap(coordinator.prepareRenameSession(
            session: makeSession(id: "ses_rename", directory: "/tmp/project", workspaceID: "ws_123"),
            title: "  Renamed  ",
            selectedDirectory: nil,
            currentProjectID: "proj_1"
        ))

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_rename")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "PATCH")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"title":"Renamed"}"#)
            expectation.fulfill()

            return try jsonResponse(for: request, body: #"{"id":"ses_rename","title":"Renamed","workspaceID":"ws_123","directory":"/tmp/project","projectID":"proj_1","parentID":null}"#)
        }

        let session = try await coordinator.submitRename(client: client, submission: submission)

        XCTAssertEqual(session.id, "ses_rename")
        XCTAssertEqual(session.title, "Renamed")
        XCTAssertEqual(session.workspaceID, "ws_123")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorRenameSessionIgnoresWhitespaceTitle() async throws {
        let client = makeClient()
        let coordinator = SessionCoordinator()
        CoordinatorMockURLProtocol.requestHandler = { _ in
            XCTFail("Whitespace rename should not make a request")
            throw URLError(.badURL)
        }

        let session = try await coordinator.renameSession(client: client, sessionID: "ses_rename", title: "  \n")

        XCTAssertNil(session)
    }

    func testSessionCoordinatorForkSessionUsesScopedForkEndpoint() async throws {
        let expectation = expectation(description: "fork session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_parent/fork")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"messageID":"msg_123"}"#)
            expectation.fulfill()

            return try jsonResponse(for: request, body: #"{"id":"ses_fork","title":"Fork","workspaceID":"ws_123","directory":"/tmp/project","projectID":"proj_1","parentID":"ses_parent"}"#)
        }

        let session = try await coordinator.forkSession(
            client: client,
            sessionID: "ses_parent",
            messageID: "msg_123",
            directory: "/tmp/project",
            workspaceID: "ws_123"
        )

        XCTAssertEqual(session.id, "ses_fork")
        XCTAssertEqual(session.parentID, "ses_parent")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorCompactSessionUsesSummarizeEndpoint() async throws {
        let expectation = expectation(description: "compact session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_compact/summarize")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            let bodyData = Data(try XCTUnwrap(requestBodyString(for: request)).utf8)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["providerID"] as? String, "anthropic")
            XCTAssertEqual(body["modelID"] as? String, "sonnet")
            XCTAssertEqual(body["auto"] as? Bool, false)
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.compactSession(
            client: client,
            sessionID: "ses_compact",
            directory: "/tmp/project",
            model: OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet")
        )

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitForkUsesPreparedScopedForkEndpoint() async throws {
        let expectation = expectation(description: "prepared fork request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let preparation = coordinator.prepareForkSession(
            session: makeSession(id: "ses_parent", directory: "/tmp/project", workspaceID: "ws_123"),
            messageID: "msg_123",
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            sourceMessage: nil
        )

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_parent/fork")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"messageID":"msg_123"}"#)
            expectation.fulfill()

            return try jsonResponse(for: request, body: #"{"id":"ses_fork","title":"Fork","workspaceID":"ws_123","directory":"/tmp/project","projectID":"proj_1","parentID":"ses_parent"}"#)
        }

        let session = try await coordinator.submitFork(client: client, submission: preparation.submission)

        XCTAssertEqual(session.id, "ses_fork")
        XCTAssertEqual(session.parentID, "ses_parent")
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitCompactUsesPreparedSummarizeEndpoint() async throws {
        let expectation = expectation(description: "prepared compact request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let preparation = coordinator.prepareCompactSession(
            session: makeSession(id: "ses_compact_prepared", directory: "/tmp/project"),
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            model: OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet")
        )

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_compact_prepared/summarize")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            let bodyData = Data(try XCTUnwrap(requestBodyString(for: request)).utf8)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["providerID"] as? String, "anthropic")
            XCTAssertEqual(body["modelID"] as? String, "sonnet")
            XCTAssertEqual(body["auto"] as? Bool, false)
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.submitCompact(client: client, preparation: preparation)

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorAbortSessionUsesScopedAbortEndpoint() async throws {
        let expectation = expectation(description: "abort session request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_abort/abort")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.abortSession(
            client: client,
            sessionID: "ses_abort",
            directory: "/tmp/project",
            workspaceID: "ws_123"
        )

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitAbortUsesPreparedScopedAbortEndpoint() async throws {
        let expectation = expectation(description: "prepared abort request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let submission = coordinator.prepareAbortSession(
            session: makeSession(id: "ses_abort", directory: "/tmp/project", workspaceID: "ws_123"),
            selectedDirectory: nil,
            currentProjectID: "proj_1"
        )

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_abort/abort")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "workspace", value: "ws_123"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.submitAbort(client: client, submission: submission)

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitPromptUsesAsyncPromptEndpoint() async throws {
        let expectation = expectation(description: "prompt submission request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let attachment = OpenCodeComposerAttachment(
            id: "att_1",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,bm90ZXM="
        )

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_prompt/prompt_async")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")

            let bodyData = Data(try XCTUnwrap(requestBodyString(for: request)).utf8)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["messageID"] as? String, "msg_prompt")
            XCTAssertEqual(body["agent"] as? String, "build")
            XCTAssertEqual(body["variant"] as? String, "plan")

            let model = try XCTUnwrap(body["model"] as? [String: Any])
            XCTAssertEqual(model["providerID"] as? String, "anthropic")
            XCTAssertEqual(model["modelID"] as? String, "sonnet")

            let parts = try XCTUnwrap(body["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 2)
            XCTAssertEqual(parts[0]["id"] as? String, "part_prompt")
            XCTAssertEqual(parts[0]["type"] as? String, "text")
            XCTAssertEqual(parts[0]["text"] as? String, "Hello from coordinator")
            XCTAssertEqual(parts[1]["type"] as? String, "file")
            XCTAssertEqual(parts[1]["filename"] as? String, "notes.txt")
            XCTAssertEqual(parts[1]["mime"] as? String, "text/plain")
            XCTAssertEqual(parts[1]["url"] as? String, "data:text/plain;base64,bm90ZXM=")
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.submitPrompt(
            client: client,
            submission: SessionCoordinator.PromptSubmission(
                sessionID: "ses_prompt",
                text: "Hello from coordinator",
                agentMentions: [],
                attachments: [attachment],
                directory: "/tmp/project",
                messageID: "msg_prompt",
                partID: "part_prompt",
                model: OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet"),
                agent: "build",
                variant: "plan"
            )
        )

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorSubmitCommandUsesScopedCommandEndpoint() async throws {
        let expectation = expectation(description: "command request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()
        let attachment = OpenCodeComposerAttachment(
            id: "att_1",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,bm90ZXM="
        )

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session/ses_command/command")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
            ])
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/tmp/project")

            let bodyData = Data(try XCTUnwrap(requestBodyString(for: request)).utf8)
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: bodyData) as? [String: Any])
            XCTAssertEqual(body["command"] as? String, "test")
            XCTAssertEqual(body["arguments"] as? String, "--flag")
            XCTAssertEqual(body["model"] as? String, "anthropic/sonnet")
            XCTAssertEqual(body["agent"] as? String, "build")
            XCTAssertEqual(body["variant"] as? String, "plan")

            let parts = try XCTUnwrap(body["parts"] as? [[String: Any]])
            XCTAssertEqual(parts.count, 1)
            XCTAssertEqual(parts[0]["type"] as? String, "file")
            XCTAssertEqual(parts[0]["filename"] as? String, "notes.txt")
            expectation.fulfill()

            return try jsonResponse(for: request, statusCode: 204, body: "")
        }

        try await coordinator.submitCommand(
            client: client,
            submission: SessionCoordinator.CommandSubmission(
                sessionID: "ses_command",
                commandName: "test",
                arguments: "--flag",
                attachments: [attachment],
                directory: "/tmp/project",
                model: OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet"),
                agent: "build",
                variant: "plan"
            )
        )

        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorPreparePromptIgnoresEmptyTextWithoutAttachments() {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_empty", directory: nil)

        let preparation = coordinator.preparePromptSubmission(
            text: "  \n",
            attachments: [],
            session: session,
            selectedDirectory: "/tmp/project",
            currentProjectID: "proj_1",
            messageID: "msg_empty",
            partID: "part_empty",
            model: nil,
            agent: nil,
            variant: nil
        )

        XCTAssertNil(preparation)
    }

    func testSessionCoordinatorPreparePromptAllowsAttachmentOnlySend() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_attachment", directory: "/tmp/project")
        let attachment = OpenCodeComposerAttachment(
            id: "att_1",
            kind: .image,
            filename: "image.png",
            mime: "image/png",
            dataURL: "data:image/png;base64,AAAA"
        )

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "  \n",
            attachments: [attachment],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_attachment",
            partID: "part_attachment",
            model: nil,
            agent: nil,
            variant: nil
        ))

        XCTAssertEqual(preparation.submission.text, "")
        XCTAssertEqual(preparation.submission.attachments, [attachment])
        XCTAssertEqual(preparation.submission.directory, "/tmp/project")
        XCTAssertEqual(preparation.submission.messageID, "msg_attachment")
        XCTAssertEqual(preparation.submission.partID, "part_attachment")
    }

    func testSessionCoordinatorPreparePromptPropagatesModelAgentAndVariant() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_model", directory: nil)
        let model = OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet")

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "  Hello model  ",
            attachments: [],
            session: session,
            selectedDirectory: "/tmp/project",
            currentProjectID: "proj_1",
            messageID: "msg_model",
            partID: "part_model",
            model: model,
            agent: "build",
            variant: "plan"
        ))

        XCTAssertEqual(preparation.submission.text, "Hello model")
        XCTAssertEqual(preparation.submission.model, model)
        XCTAssertEqual(preparation.submission.agent, "build")
        XCTAssertEqual(preparation.submission.variant, "plan")
        XCTAssertEqual(preparation.optimisticModel?.providerID, "anthropic")
        XCTAssertEqual(preparation.optimisticModel?.modelID, "sonnet")
        XCTAssertEqual(preparation.optimisticModel?.variant, "plan")
    }

    func testSessionCoordinatorPreparePromptPropagatesAgentMentions() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_mentions", directory: nil)
        let mention = OpenCodeAgentMention(name: "explore", content: "@explore", start: 4, end: 12)

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Ask @explore now",
            agentMentions: [mention],
            attachments: [],
            session: session,
            selectedDirectory: "/tmp/project",
            currentProjectID: "proj_1",
            messageID: "msg_mentions",
            partID: "part_mentions",
            model: nil,
            agent: "build",
            variant: nil
        ))

        XCTAssertEqual(preparation.submission.agentMentions, [mention])
        let optimistic = coordinator.optimisticUserMessage(for: preparation)
        XCTAssertEqual(optimistic.parts.first(where: { $0.type == "agent" })?.name, "explore")
    }

    func testSessionCoordinatorPreparePromptAdjustsMentionRangesAfterTrimming() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_trim_mentions", directory: nil)

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "  Ask @explore now  ",
            agentMentions: [OpenCodeAgentMention(name: "explore", content: "@explore", start: 6, end: 14)],
            attachments: [],
            session: session,
            selectedDirectory: "/tmp/project",
            currentProjectID: "proj_1",
            messageID: "msg_trim_mentions",
            partID: "part_trim_mentions",
            model: nil,
            agent: "build",
            variant: nil
        ))

        XCTAssertEqual(preparation.submission.text, "Ask @explore now")
        XCTAssertEqual(preparation.submission.agentMentions, [OpenCodeAgentMention(name: "explore", content: "@explore", start: 4, end: 12)])
    }

    func testAgentMentionReconcileUsesUTF16Offsets() {
        let text = "Ask 🧠 @explore now"
        let mention = OpenCodeAgentMention.reconciled(
            [OpenCodeAgentMention(name: "explore", content: "@explore", start: 0, end: 0)],
            in: text
        ).first

        XCTAssertEqual(mention, OpenCodeAgentMention(name: "explore", content: "@explore", start: 7, end: 15))
    }

    func testSessionCoordinatorPreparePromptUsesSessionDirectoryForWorkspaceSession() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_workspace", directory: "/tmp/workspace", parentID: "ses_root")

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Workspace send",
            attachments: [],
            session: session,
            selectedDirectory: "/tmp/selected",
            currentProjectID: "proj_1",
            messageID: "msg_workspace",
            partID: "part_workspace",
            model: nil,
            agent: nil,
            variant: nil
        ))

        XCTAssertEqual(preparation.submission.directory, "/tmp/workspace")
    }

    func testSessionCoordinatorPreparePromptUsesNilDirectoryForGlobalProjectWithoutSelectedDirectory() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_global", directory: nil)

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Global send",
            attachments: [],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "global",
            messageID: "msg_global",
            partID: "part_global",
            model: nil,
            agent: nil,
            variant: nil
        ))

        XCTAssertNil(preparation.submission.directory)
    }

    func testSessionCoordinatorPreparePromptUsesNilDirectoryForGlobalProjectSessionWithRootDirectory() throws {
        let coordinator = SessionCoordinator()
        let session = OpenCodeSession(id: "ses_global", title: nil, workspaceID: nil, directory: "/", projectID: "global", parentID: nil)

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Global send",
            attachments: [],
            session: session,
            selectedDirectory: "/",
            currentProjectID: "global",
            messageID: "msg_global",
            partID: "part_global",
            model: nil,
            agent: nil,
            variant: nil
        ))

        XCTAssertNil(preparation.submission.directory)
    }

    func testSessionCoordinatorPreparePromptUsesNilDirectoryForRootDirectorySessionWithoutProjectID() throws {
        let coordinator = SessionCoordinator()
        let session = OpenCodeSession(id: "ses_global", title: nil, workspaceID: nil, directory: "/", projectID: nil, parentID: nil)

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Global send",
            attachments: [],
            session: session,
            selectedDirectory: "/",
            currentProjectID: "global",
            messageID: "msg_global",
            partID: "part_global",
            model: nil,
            agent: nil,
            variant: nil
        ))

        XCTAssertNil(preparation.submission.directory)
    }

    func testSessionCoordinatorOptimisticUserMessageUsesPreparedPromptMetadata() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_optimistic", directory: "/tmp/project")
        let model = OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet")

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "  Optimistic hello  ",
            attachments: [],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_optimistic",
            partID: "part_optimistic",
            model: model,
            agent: "build",
            variant: "plan"
        ))

        let message = coordinator.optimisticUserMessage(for: preparation)

        XCTAssertEqual(message.id, "msg_optimistic")
        XCTAssertEqual(message.info.role, "user")
        XCTAssertEqual(message.info.sessionID, "ses_optimistic")
        XCTAssertEqual(message.info.agent, "build")
        XCTAssertEqual(message.info.model?.providerID, "anthropic")
        XCTAssertEqual(message.info.model?.modelID, "sonnet")
        XCTAssertEqual(message.info.model?.variant, "plan")
        XCTAssertEqual(message.parts.count, 1)
        XCTAssertEqual(message.parts[0].id, "part_optimistic")
        XCTAssertEqual(message.parts[0].messageID, "msg_optimistic")
        XCTAssertEqual(message.parts[0].sessionID, "ses_optimistic")
        XCTAssertEqual(message.parts[0].type, "text")
        XCTAssertEqual(message.parts[0].text, "Optimistic hello")
    }

    func testSessionCoordinatorOptimisticUserMessageIncludesAttachmentOnlyFilePart() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_attachment_optimistic", directory: "/tmp/project")
        let attachment = OpenCodeComposerAttachment(
            id: "att_1",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,bm90ZXM="
        )

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "  \n",
            attachments: [attachment],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_attachment_optimistic",
            partID: "part_attachment_optimistic",
            model: nil,
            agent: nil,
            variant: nil
        ))

        let message = coordinator.optimisticUserMessage(for: preparation)

        XCTAssertEqual(message.id, "msg_attachment_optimistic")
        XCTAssertEqual(message.parts.count, 1)
        XCTAssertEqual(message.parts[0].messageID, "msg_attachment_optimistic")
        XCTAssertEqual(message.parts[0].sessionID, "ses_attachment_optimistic")
        XCTAssertEqual(message.parts[0].type, "file")
        XCTAssertEqual(message.parts[0].filename, "notes.txt")
        XCTAssertEqual(message.parts[0].mime, "text/plain")
        XCTAssertEqual(message.parts[0].url, "data:text/plain;base64,bm90ZXM=")
    }

    func testSessionCoordinatorPromptRollbackRestoresPreparedPromptState() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_rollback", directory: "/tmp/project")
        let attachment = OpenCodeComposerAttachment(
            id: "att_rollback",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,bm90ZXM="
        )

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "  Restore me  ",
            attachments: [attachment],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_rollback",
            partID: "part_rollback",
            model: nil,
            agent: "build",
            variant: nil
        ))
        let optimisticMessage = coordinator.optimisticUserMessage(for: preparation)

        let rollback = coordinator.promptRollback(
            for: preparation,
            optimisticMessage: optimisticMessage,
            previousStatus: "idle"
        )

        XCTAssertEqual(rollback.sessionID, "ses_rollback")
        XCTAssertEqual(rollback.optimisticMessageID, "msg_rollback")
        XCTAssertEqual(rollback.messageID, "msg_rollback")
        XCTAssertEqual(rollback.partID, "part_rollback")
        XCTAssertEqual(rollback.draftText, "Restore me")
        XCTAssertEqual(rollback.attachments, [attachment])
        XCTAssertEqual(rollback.previousStatus, "idle")
    }

    func testSessionCoordinatorPromptSuccessUsesPreparedPromptIDs() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_success", directory: "/tmp/project")

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Accepted",
            attachments: [],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_success",
            partID: "part_success",
            model: nil,
            agent: nil,
            variant: nil
        ))

        let success = coordinator.promptSuccess(for: preparation)

        XCTAssertEqual(success.sessionID, "ses_success")
        XCTAssertEqual(success.messageID, "msg_success")
        XCTAssertEqual(success.partID, "part_success")
        XCTAssertEqual(success.requestDirectory, "/tmp/project")
    }

    func testSessionCoordinatorPromptStartUsesPreparedPromptMetadata() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_start", directory: "/tmp/project")

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "  Starting prompt  ",
            attachments: [],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_start",
            partID: "part_start",
            model: nil,
            agent: nil,
            variant: nil
        ))

        let start = coordinator.promptStart(for: preparation)

        XCTAssertEqual(start.sessionID, "ses_start")
        XCTAssertEqual(start.messageID, "msg_start")
        XCTAssertEqual(start.partID, "part_start")
        XCTAssertEqual(start.text, "Starting prompt")
        XCTAssertEqual(start.requestDirectory, "/tmp/project")
    }

    func testSessionCoordinatorPromptStatusTransitionPreservesPreviousStatus() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_status", directory: "/tmp/project")

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Status prompt",
            attachments: [],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_status",
            partID: "part_status",
            model: nil,
            agent: nil,
            variant: nil
        ))

        let transition = coordinator.promptStatusTransition(for: preparation, previousStatus: "idle")

        XCTAssertEqual(transition.sessionID, "ses_status")
        XCTAssertEqual(transition.previousStatus, "idle")
        XCTAssertEqual(transition.nextStatus, "busy")
    }

    func testSessionCoordinatorPromptStatusTransitionAllowsMissingPreviousStatus() throws {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_status_nil", directory: "/tmp/project")

        let preparation = try XCTUnwrap(coordinator.preparePromptSubmission(
            text: "Status prompt",
            attachments: [],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            messageID: "msg_status_nil",
            partID: "part_status_nil",
            model: nil,
            agent: nil,
            variant: nil
        ))

        let transition = coordinator.promptStatusTransition(for: preparation, previousStatus: nil)

        XCTAssertEqual(transition.sessionID, "ses_status_nil")
        XCTAssertNil(transition.previousStatus)
        XCTAssertEqual(transition.nextStatus, "busy")
    }

    func testSessionCoordinatorPrepareCommandTrimsArgumentsAndBuildsDraftCommand() {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_command_prepare", directory: nil)
        let command = makeCommand(name: "test")
        let model = OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet")

        let preparation = coordinator.prepareCommandSubmission(
            command: command,
            arguments: "  --flag value  ",
            attachments: [],
            session: session,
            selectedDirectory: "/tmp/project",
            currentProjectID: "proj_1",
            model: model,
            agent: "build",
            variant: "plan"
        )

        XCTAssertEqual(preparation.submission.sessionID, "ses_command_prepare")
        XCTAssertEqual(preparation.submission.commandName, "test")
        XCTAssertEqual(preparation.submission.arguments, "--flag value")
        XCTAssertEqual(preparation.submission.directory, "/tmp/project")
        XCTAssertEqual(preparation.submission.model, model)
        XCTAssertEqual(preparation.submission.agent, "build")
        XCTAssertEqual(preparation.submission.variant, "plan")
        XCTAssertEqual(preparation.draftCommand, "/test --flag value")
    }

    func testSessionCoordinatorPrepareCommandBuildsBareDraftForEmptyArguments() {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_command_empty", directory: "/tmp/project")
        let command = makeCommand(name: "test")

        let preparation = coordinator.prepareCommandSubmission(
            command: command,
            arguments: "  \n",
            attachments: [],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            model: nil,
            agent: nil,
            variant: nil
        )

        XCTAssertEqual(preparation.submission.arguments, "")
        XCTAssertEqual(preparation.submission.directory, "/tmp/project")
        XCTAssertEqual(preparation.draftCommand, "/test")
    }

    func testSessionCoordinatorCommandRollbackRestoresDraftAttachmentsAndPreviousStatus() {
        let coordinator = SessionCoordinator()
        let session = makeSession(id: "ses_command_rollback", directory: "/tmp/project")
        let command = makeCommand(name: "test")
        let attachment = OpenCodeComposerAttachment(
            id: "att_rollback",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,bm90ZXM="
        )
        let preparation = coordinator.prepareCommandSubmission(
            command: command,
            arguments: "  --flag  ",
            attachments: [attachment],
            session: session,
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            model: nil,
            agent: nil,
            variant: nil
        )

        let transition = coordinator.commandStatusTransition(for: preparation, previousStatus: "idle")
        let rollback = coordinator.commandRollback(for: preparation, previousStatus: transition.previousStatus)

        XCTAssertEqual(transition.sessionID, "ses_command_rollback")
        XCTAssertEqual(transition.previousStatus, "idle")
        XCTAssertEqual(transition.nextStatus, "busy")
        XCTAssertEqual(rollback.sessionID, "ses_command_rollback")
        XCTAssertEqual(rollback.draftText, "/test --flag")
        XCTAssertEqual(rollback.attachments, [attachment])
        XCTAssertEqual(rollback.previousStatus, "idle")
    }

    func testSessionCoordinatorPrepareCompactUsesDirectoryModelAndDraftCommand() {
        let coordinator = SessionCoordinator()
        let model = OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet")

        let preparation = coordinator.prepareCompactSession(
            session: makeSession(id: "ses_compact_prepare", directory: nil),
            selectedDirectory: "/tmp/project",
            currentProjectID: "proj_1",
            model: model
        )

        XCTAssertEqual(preparation.sessionID, "ses_compact_prepare")
        XCTAssertEqual(preparation.directory, "/tmp/project")
        XCTAssertEqual(preparation.model, model)
        XCTAssertEqual(preparation.draftCommand, "/compact")
    }

    func testSessionCoordinatorCompactRollbackRestoresDraftAndStatus() {
        let coordinator = SessionCoordinator()
        let preparation = coordinator.prepareCompactSession(
            session: makeSession(id: "ses_compact_rollback", directory: "/tmp/project"),
            selectedDirectory: nil,
            currentProjectID: "proj_1",
            model: OpenCodeModelReference(providerID: "anthropic", modelID: "sonnet")
        )

        let transition = coordinator.compactStatusTransition(for: preparation, previousStatus: "idle")
        let rollback = coordinator.compactRollback(for: preparation, previousStatus: transition.previousStatus)

        XCTAssertEqual(transition.sessionID, "ses_compact_rollback")
        XCTAssertEqual(transition.previousStatus, "idle")
        XCTAssertEqual(transition.nextStatus, "busy")
        XCTAssertEqual(rollback.sessionID, "ses_compact_rollback")
        XCTAssertEqual(rollback.draftText, "/compact")
        XCTAssertEqual(rollback.attachments, [])
        XCTAssertEqual(rollback.previousStatus, "idle")
    }

    func testSessionCoordinatorPrepareForkUsesScopeWorkspaceAndRestoredPrompt() throws {
        let coordinator = SessionCoordinator()
        let attachment = OpenCodeComposerAttachment(
            id: "att_1",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,bm90ZXM="
        )
        let sourceMessage = OpenCodeMessageEnvelope.local(
            role: "user",
            text: "  Restore this  ",
            attachments: [attachment],
            messageID: "msg_source",
            sessionID: "ses_parent",
            partID: "part_source"
        )

        let preparation = coordinator.prepareForkSession(
            session: makeSession(id: "ses_parent", directory: nil, workspaceID: "ws_123"),
            messageID: "msg_source",
            selectedDirectory: "/tmp/project",
            currentProjectID: "proj_1",
            sourceMessage: sourceMessage
        )

        XCTAssertEqual(preparation.submission.sessionID, "ses_parent")
        XCTAssertEqual(preparation.submission.messageID, "msg_source")
        XCTAssertEqual(preparation.submission.directory, "/tmp/project")
        XCTAssertEqual(preparation.submission.workspaceID, "ws_123")
        XCTAssertEqual(preparation.restoredPrompt?.text, "Restore this")
        XCTAssertEqual(preparation.restoredPrompt?.attachments.count, 1)
        XCTAssertEqual(preparation.restoredPrompt?.attachments.first?.filename, "notes.txt")
        XCTAssertEqual(preparation.restoredPrompt?.attachments.first?.mime, "text/plain")
    }

    func testSessionCoordinatorPrepareForkAllowsMissingSourceMessage() {
        let coordinator = SessionCoordinator()

        let preparation = coordinator.prepareForkSession(
            session: makeSession(id: "ses_parent", directory: nil),
            messageID: "msg_missing",
            selectedDirectory: nil,
            currentProjectID: "global",
            sourceMessage: nil
        )

        XCTAssertEqual(preparation.submission.sessionID, "ses_parent")
        XCTAssertEqual(preparation.submission.messageID, "msg_missing")
        XCTAssertNil(preparation.submission.directory)
        XCTAssertNil(preparation.submission.workspaceID)
        XCTAssertNil(preparation.restoredPrompt)
    }

    func testSessionCoordinatorPrepareAbortUsesSessionDirectoryAndWorkspace() {
        let coordinator = SessionCoordinator()

        let submission = coordinator.prepareAbortSession(
            session: makeSession(id: "ses_abort_prepare", directory: "/tmp/project", workspaceID: "ws_123"),
            selectedDirectory: "/tmp/selected",
            currentProjectID: "proj_1"
        )

        XCTAssertEqual(submission.sessionID, "ses_abort_prepare")
        XCTAssertEqual(submission.directory, "/tmp/project")
        XCTAssertEqual(submission.workspaceID, "ws_123")
    }

    func testSessionCoordinatorPrepareAbortUsesGlobalNilDirectory() {
        let coordinator = SessionCoordinator()

        let submission = coordinator.prepareAbortSession(
            session: makeSession(id: "ses_abort_global", directory: nil),
            selectedDirectory: nil,
            currentProjectID: "global"
        )

        XCTAssertEqual(submission.sessionID, "ses_abort_global")
        XCTAssertNil(submission.directory)
        XCTAssertNil(submission.workspaceID)
    }

    func testSessionCoordinatorPrepareDeleteUsesSessionDirectoryAndWorkspace() {
        let coordinator = SessionCoordinator()

        let submission = coordinator.prepareDeleteSession(
            session: makeSession(id: "ses_delete_prepare", directory: "/tmp/project", workspaceID: "ws_123"),
            selectedDirectory: "/tmp/selected",
            currentProjectID: "proj_1"
        )

        XCTAssertEqual(submission.sessionID, "ses_delete_prepare")
        XCTAssertEqual(submission.directory, "/tmp/project")
        XCTAssertEqual(submission.workspaceID, "ws_123")
    }

    func testSessionCoordinatorPrepareDeleteUsesGlobalNilDirectory() {
        let coordinator = SessionCoordinator()

        let submission = coordinator.prepareDeleteSession(
            session: makeSession(id: "ses_delete_global", directory: nil),
            selectedDirectory: nil,
            currentProjectID: "global"
        )

        XCTAssertEqual(submission.sessionID, "ses_delete_global")
        XCTAssertNil(submission.directory)
        XCTAssertNil(submission.workspaceID)
    }

    func testSessionCoordinatorPrepareRenameTrimsTitleAndUsesSessionScope() throws {
        let coordinator = SessionCoordinator()

        let submission = try XCTUnwrap(coordinator.prepareRenameSession(
            session: makeSession(id: "ses_rename_prepare", directory: "/tmp/project", workspaceID: "ws_123"),
            title: "  Renamed  ",
            selectedDirectory: "/tmp/selected",
            currentProjectID: "proj_1"
        ))

        XCTAssertEqual(submission.sessionID, "ses_rename_prepare")
        XCTAssertEqual(submission.title, "Renamed")
        XCTAssertEqual(submission.directory, "/tmp/project")
        XCTAssertEqual(submission.workspaceID, "ws_123")
    }

    func testSessionCoordinatorPrepareRenameIgnoresWhitespaceTitle() {
        let coordinator = SessionCoordinator()

        let submission = coordinator.prepareRenameSession(
            session: makeSession(id: "ses_rename_blank", directory: "/tmp/project"),
            title: "  \n",
            selectedDirectory: nil,
            currentProjectID: "proj_1"
        )

        XCTAssertNil(submission)
    }

    func testSessionCoordinatorLoadsWorkspaceSessionsWithRootsLimitAndEstimatedTotal() async throws {
        let expectation = expectation(description: "workspace sessions request captured")
        let client = makeClient()
        let coordinator = SessionCoordinator()

        CoordinatorMockURLProtocol.requestHandler = { request in
            XCTAssertEqual(request.url?.path, "/session")
            XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                URLQueryItem(name: "directory", value: "/tmp/project"),
                URLQueryItem(name: "roots", value: "true"),
                URLQueryItem(name: "limit", value: "5"),
            ])
            XCTAssertEqual(request.httpMethod, "GET")
            expectation.fulfill()

            return try jsonResponse(for: request, body: """
            [
              {"id":"ses_1","title":"One","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null},
              {"id":"ses_2","title":"Two","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null},
              {"id":"ses_3","title":"Three","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null},
              {"id":"ses_4","title":"Four","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null},
              {"id":"ses_5","title":"Five","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null}
            ]
            """)
        }

        let result = try await coordinator.loadWorkspaceSessions(client: client, directory: "/tmp/project", limit: 2)

        XCTAssertEqual(result.sessions.map(\.id), ["ses_1", "ses_2", "ses_3", "ses_4", "ses_5"])
        XCTAssertEqual(result.estimatedTotal, 6)
        await fulfillment(of: [expectation], timeout: 1)
    }

    func testSessionCoordinatorReloadDirectoryBootstrapsScopedStateAndStatuses() async throws {
        let client = makeClient()
        let coordinator = SessionCoordinator()
        var seenPaths: [String] = []

        CoordinatorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            seenPaths.append(path)
            XCTAssertTrue(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "directory", value: "/tmp/project")) ?? false)

            switch path {
            case "/session":
                XCTAssertEqual(URLComponents(
                    url: try XCTUnwrap(request.url),
                    resolvingAgainstBaseURL: false
                )?.queryItems, [
                    URLQueryItem(name: "directory", value: "/tmp/project"),
                    URLQueryItem(name: "roots", value: "true"),
                    URLQueryItem(name: "limit", value: "100"),
                ])
                return try jsonResponse(for: request, body: """
                [
                  {"id":"ses_root","title":"Root","workspaceID":null,"directory":"/tmp/project","projectID":"proj_1","parentID":null}
                ]
                """)
            case "/command", "/permission", "/question":
                return try jsonResponse(for: request, body: "[]")
            case "/session/status":
                return try jsonResponse(for: request, body: #"{"ses_root":{"type":"busy"}}"#)
            default:
                break
            }

            return try jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
        }

        let result = try await coordinator.reloadDirectory(
            client: client,
            directory: "/tmp/project",
            sessionLimit: 100
        )

        XCTAssertEqual(result.bootstrap.sessions.map(\.id), ["ses_root"])
        XCTAssertEqual(result.bootstrap.sessionTotal, 1)
        XCTAssertEqual(result.bootstrap.sessionLimit, 100)
        XCTAssertEqual(result.bootstrap.commands, [])
        XCTAssertEqual(result.bootstrap.permissions, [])
        XCTAssertEqual(result.bootstrap.questions, [])
        XCTAssertEqual(result.statuses, ["ses_root": "busy"])
        XCTAssertTrue(seenPaths.contains("/session"))
        XCTAssertTrue(seenPaths.contains("/command"))
        XCTAssertTrue(seenPaths.contains("/permission"))
        XCTAssertTrue(seenPaths.contains("/question"))
        XCTAssertTrue(seenPaths.contains("/session/status"))
    }

    func testProjectCoordinatorCreateProjectWarmsDiscoveryAndCreatesLocalProjectForGlobalResult() async throws {
        let client = makeClient()
        let coordinator = ProjectCoordinator()
        let existingGlobal = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: "Global", sandboxes: nil, icon: nil, time: nil)
        var seenPaths: [String] = []

        CoordinatorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            seenPaths.append(path)

            switch path {
            case "/session":
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    URLQueryItem(name: "directory", value: "/tmp/new-project"),
                    URLQueryItem(name: "roots", value: "true"),
                    URLQueryItem(name: "limit", value: "55"),
                ])
                return try jsonResponse(for: request, body: "[]")
            case "/project/current":
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    URLQueryItem(name: "directory", value: "/tmp/new-project"),
                ])
                return try jsonResponse(for: request, body: #"{"id":"global","worktree":"/","vcs":null,"name":"Global","sandboxes":null,"icon":null,"time":null}"#)
            default:
                return try jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }
        }

        let result = try await coordinator.createProject(client: client, directory: " /tmp/new-project\n", currentProjects: [existingGlobal])

        XCTAssertEqual(result?.selectedDirectory, "/tmp/new-project")
        XCTAssertEqual(result?.projects?.map(\.id).sorted(), ["global", "local:/tmp/new-project"])
        XCTAssertEqual(result?.projects?.first(where: { $0.id == "local:/tmp/new-project" })?.name, "new-project")
        XCTAssertFalse(seenPaths.contains("/project/global"))
    }

    func testProjectCoordinatorCreateProjectUpdatesCanonicalDiscoveredProject() async throws {
        let client = makeClient()
        let coordinator = ProjectCoordinator()
        var seenPaths: [String] = []

        CoordinatorMockURLProtocol.requestHandler = { request in
            let path = request.url?.path ?? ""
            seenPaths.append(path)

            switch path {
            case "/session":
                return try jsonResponse(for: request, body: "[]")
            case "/project/current":
                return try jsonResponse(for: request, body: #"{"id":"proj_1","worktree":"/canonical/project","vcs":"git","name":"Old","sandboxes":null,"icon":null,"time":null}"#)
            case "/project/proj_1":
                XCTAssertEqual(request.httpMethod, "PATCH")
                XCTAssertEqual(URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems, [
                    URLQueryItem(name: "directory", value: "/canonical/project"),
                ])
                XCTAssertEqual(try XCTUnwrap(requestBodyString(for: request)), #"{"name":"requested"}"#)
                return try jsonResponse(for: request, body: #"{"id":"proj_1","worktree":"/canonical/project","vcs":"git","name":"project","sandboxes":null,"icon":null,"time":null}"#)
            default:
                return try jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }
        }

        let result = try await coordinator.createProject(client: client, directory: "/tmp/requested", currentProjects: [])

        XCTAssertEqual(result?.selectedDirectory, "/canonical/project")
        XCTAssertNil(result?.projects)
        XCTAssertEqual(seenPaths, ["/session", "/project/current", "/project/proj_1"])
    }

    func testProjectCoordinatorRefreshPreservesExistingGlobalProjectWhenServerOmitsIt() async throws {
        let client = makeClient()
        let coordinator = ProjectCoordinator()
        let global = OpenCodeProject(id: "global", worktree: "", vcs: nil, name: "Global", sandboxes: nil, icon: nil, time: nil)

        CoordinatorMockURLProtocol.requestHandler = { request in
            switch request.url?.path ?? "" {
            case "/project":
                return try jsonResponse(for: request, body: #"[{"id":"proj_1","worktree":"/tmp/project","vcs":"git","name":"Project","sandboxes":null,"icon":null,"time":null}]"#)
            case "/project/current":
                return try jsonResponse(for: request, body: #"{"id":"proj_1","worktree":"/tmp/project","vcs":"git","name":"Project","sandboxes":null,"icon":null,"time":null}"#)
            default:
                return try jsonResponse(for: request, statusCode: 404, body: #"{"error":"unexpected"}"#)
            }
        }

        let result = try await coordinator.refreshProjects(
            client: client,
            currentProjects: [global],
            currentProject: global,
            selectedDirectory: nil
        )

        XCTAssertEqual(result.currentProject?.id, "global")
        XCTAssertTrue(result.projects.contains { $0.id == "global" })
    }

    func testProjectCoordinatorRecentSessionNavigationPrefersExactDirectoryOverProjectID() {
        let coordinator = ProjectCoordinator()
        let project = makeProject(id: "proj_1", worktree: "/tmp/project")
        let other = makeProject(id: "proj_2", worktree: "/tmp/other")
        let session = OpenCodeSession(id: "ses_1", title: nil, workspaceID: nil, directory: "/tmp/other", projectID: "proj_1", parentID: nil)

        let result = coordinator.recentSessionNavigationResult(for: session, projects: [other, project])

        // Non-global sessions resolve an exact worktree match before falling back to projectID.
        XCTAssertEqual(result.currentProject?.id, "proj_2")
        XCTAssertEqual(result.routeDirectory, "/tmp/other")
        XCTAssertFalse(result.shouldPreserveMissingSession)
        XCTAssertEqual(result.projects.map(\.id), ["proj_2", "proj_1"])
    }

    func testProjectCoordinatorBootstrapProjectsAddsAndSortsGlobalProject() {
        let coordinator = ProjectCoordinator()
        let project = makeProject(id: "proj_1", worktree: "/tmp/project")

        let projects = coordinator.bootstrapProjects([project])

        XCTAssertEqual(projects.first?.id, "global")
        XCTAssertTrue(projects.contains(project))
    }

    func testProjectCoordinatorBootstrapProjectsIncludesCurrentProjectWhenProjectListOmitsIt() {
        let coordinator = ProjectCoordinator()
        let listed = makeProject(id: "proj_listed", worktree: "/tmp/listed")
        let current = makeProject(id: "proj_current", worktree: "/tmp/current")

        let projects = coordinator.bootstrapProjects([listed], currentProject: current)

        XCTAssertEqual(projects.first?.id, "global")
        XCTAssertTrue(projects.contains(listed))
        XCTAssertTrue(projects.contains(current))
    }

    func testProjectCoordinatorRecentSessionDirectoriesIncludesCurrentSelectedProjectsAndSandboxes() {
        let coordinator = ProjectCoordinator()
        let current = makeProject(id: "proj_current", worktree: "/tmp/current")
        let project = OpenCodeProject(
            id: "proj_1",
            worktree: "/tmp/project",
            vcs: nil,
            name: "Project",
            sandboxes: ["/tmp/project/sandbox", "/tmp/selected"],
            icon: nil,
            time: nil
        )
        let global = OpenCodeProject(id: "global", worktree: "", vcs: nil, name: "Global", sandboxes: nil, icon: nil, time: nil)

        let directories = coordinator.recentSessionDirectories(
            projects: [global, project],
            currentProject: current,
            selectedDirectory: "/tmp/selected"
        )

        XCTAssertEqual(directories.map { $0 ?? "global" }, [
            "global",
            "/tmp/selected",
            "/tmp/current",
            "/tmp/project",
            "/tmp/project/sandbox",
        ])
    }

    func testProjectCoordinatorRecentSessionNavigationMatchesProjectDirectoryAndSandboxes() {
        let coordinator = ProjectCoordinator()
        let project = OpenCodeProject(
            id: "proj_1",
            worktree: "/tmp/project",
            vcs: nil,
            name: "Project",
            sandboxes: ["/tmp/project/sandbox"],
            icon: nil,
            time: nil
        )
        let session = makeSession(id: "ses_1", directory: "/tmp/project/sandbox")

        let result = coordinator.recentSessionNavigationResult(for: session, projects: [project])

        XCTAssertEqual(result.currentProject?.id, "proj_1")
        XCTAssertEqual(result.routeDirectory, "/tmp/project/sandbox")
        XCTAssertFalse(result.shouldPreserveMissingSession)
    }

    func testProjectCoordinatorRecentSessionNavigationCreatesGlobalProjectWhenMissing() {
        let coordinator = ProjectCoordinator()
        let session = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)

        let result = coordinator.recentSessionNavigationResult(for: session, projects: [])

        XCTAssertEqual(result.currentProject?.id, "global")
        XCTAssertNil(result.routeDirectory)
        XCTAssertTrue(result.shouldPreserveMissingSession)
        XCTAssertEqual(result.projects.map(\.id), ["global"])
    }

    func testProjectCoordinatorRecentSessionResolutionPreservesMissingGlobalOnly() {
        let coordinator = ProjectCoordinator()
        let global = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        let project = makeSession(id: "ses_project", directory: "/tmp/project")

        let globalResult = coordinator.resolveRecentSessionAfterReload(
            recentSession: global,
            matchingSession: nil,
            allSessions: []
        )
        let projectResult = coordinator.resolveRecentSessionAfterReload(
            recentSession: project,
            matchingSession: nil,
            allSessions: []
        )

        XCTAssertEqual(globalResult.session, global)
        XCTAssertTrue(globalResult.shouldUpsertVisibleSession)
        XCTAssertNil(projectResult.session)
        XCTAssertFalse(projectResult.shouldUpsertVisibleSession)
    }

    func testSessionCoordinatorPreservesPendingRecentSelectionMissingFromReload() {
        let coordinator = SessionCoordinator()
        let previous = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)

        let selection = coordinator.selectionAfterDirectoryReload(
            previousSelectedSession: previous,
            currentSelectedSessionID: previous.id,
            sessions: [],
            currentStreamDirectory: nil,
            isProjectWorkspacesEnabled: false,
            effectiveSelectedDirectory: nil,
            workspaceDirectories: [],
            preserveMissingSelectedSession: true,
            fallbackSession: { _ in nil }
        )

        XCTAssertEqual(selection.selectedSession, previous)
        XCTAssertFalse(selection.shouldClearActiveChat)
    }

    func testSessionCoordinatorClearsMissingSelectionWithoutRecentPreservation() {
        let coordinator = SessionCoordinator()
        let previous = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)

        let selection = coordinator.selectionAfterDirectoryReload(
            previousSelectedSession: previous,
            currentSelectedSessionID: previous.id,
            sessions: [],
            currentStreamDirectory: nil,
            isProjectWorkspacesEnabled: false,
            effectiveSelectedDirectory: nil,
            workspaceDirectories: [],
            preserveMissingSelectedSession: false,
            fallbackSession: { _ in nil }
        )

        XCTAssertNil(selection.selectedSession)
        XCTAssertTrue(selection.shouldClearActiveChat)
    }

    func testSessionCoordinatorReloadSelectionUsesRefreshedSelectedSession() {
        let coordinator = SessionCoordinator()
        let refreshed = makeSession(id: "ses_1", directory: "/tmp/project")

        let selection = coordinator.selectionAfterDirectoryReload(
            previousSelectedSession: makeSession(id: "ses_1", directory: "/old/project"),
            currentSelectedSessionID: "ses_1",
            sessions: [refreshed],
            currentStreamDirectory: nil,
            isProjectWorkspacesEnabled: false,
            effectiveSelectedDirectory: "/tmp/project",
            workspaceDirectories: [],
            fallbackSession: { _ in nil }
        )

        XCTAssertEqual(selection.selectedSession, refreshed)
        XCTAssertEqual(selection.streamDirectory, "/tmp/project")
        XCTAssertFalse(selection.shouldClearActiveChat)
        XCTAssertFalse(selection.preservedWorkspaceSelection)
    }

    func testSessionCoordinatorReloadSelectionPreservesWorkspaceSession() {
        let coordinator = SessionCoordinator()
        let workspaceSession = makeSession(id: "ses_workspace", directory: "/tmp/project/sandbox/")

        let selection = coordinator.selectionAfterDirectoryReload(
            previousSelectedSession: workspaceSession,
            currentSelectedSessionID: "ses_workspace",
            sessions: [makeSession(id: "root", directory: "/tmp/project")],
            currentStreamDirectory: nil,
            isProjectWorkspacesEnabled: true,
            effectiveSelectedDirectory: "/tmp/project",
            workspaceDirectories: ["/tmp/project/sandbox"],
            fallbackSession: { _ in nil }
        )

        XCTAssertEqual(selection.selectedSession, workspaceSession)
        XCTAssertEqual(selection.streamDirectory, "/tmp/project/sandbox/")
        XCTAssertFalse(selection.shouldClearActiveChat)
        XCTAssertTrue(selection.preservedWorkspaceSelection)
    }

    func testSessionCoordinatorReloadSelectionClearsMissingSelection() {
        let coordinator = SessionCoordinator()

        let selection = coordinator.selectionAfterDirectoryReload(
            previousSelectedSession: makeSession(id: "missing", directory: "/old/project"),
            currentSelectedSessionID: "missing",
            sessions: [makeSession(id: "root", directory: "/tmp/project")],
            currentStreamDirectory: nil,
            isProjectWorkspacesEnabled: false,
            effectiveSelectedDirectory: "/tmp/project",
            workspaceDirectories: [],
            fallbackSession: { _ in nil }
        )

        XCTAssertNil(selection.selectedSession)
        XCTAssertEqual(selection.streamDirectory, "/tmp/project")
        XCTAssertTrue(selection.shouldClearActiveChat)
        XCTAssertFalse(selection.preservedWorkspaceSelection)
    }
}

private func makeClient(apiPreference: OpenCodeAPIPreference = .legacy) -> OpenCodeAPIClient {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [CoordinatorMockURLProtocol.self]
    return OpenCodeAPIClient(
        config: OpenCodeServerConfig(
            baseURL: "http://127.0.0.1:4096",
            username: "opencode",
            password: "pw",
            apiPreference: apiPreference
        ),
        session: URLSession(configuration: configuration)
    )
}

private func makeSession(id: String, directory: String?, workspaceID: String? = nil, parentID: String? = nil) -> OpenCodeSession {
    OpenCodeSession(id: id, title: nil, workspaceID: workspaceID, directory: directory, projectID: nil, parentID: parentID)
}

private func makeProject(id: String, worktree: String) -> OpenCodeProject {
    OpenCodeProject(id: id, worktree: worktree, vcs: nil, name: URL(fileURLWithPath: worktree).lastPathComponent, sandboxes: nil, icon: nil, time: nil)
}

private func makeMessage(id: String, sessionID: String) -> OpenCodeMessageEnvelope {
    OpenCodeMessageEnvelope(
        info: OpenCodeMessage(id: id, role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil),
        parts: [
            OpenCodePart(id: "part_\(id)", messageID: id, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: ""),
        ]
    )
}

private func makeCommand(name: String) -> OpenCodeCommand {
    OpenCodeCommand(
        name: name,
        description: nil,
        agent: nil,
        model: nil,
        source: nil,
        template: "",
        subtask: nil,
        hints: []
    )
}

private func jsonResponse(for request: URLRequest, statusCode: Int = 200, body: String) throws -> (HTTPURLResponse, Data) {
    (
        HTTPURLResponse(url: try XCTUnwrap(request.url), statusCode: statusCode, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!,
        Data(body.utf8)
    )
}

private func requestBodyString(for request: URLRequest) -> String? {
    if let body = request.httpBody {
        return String(data: body, encoding: .utf8)
    }

    guard let stream = request.httpBodyStream else { return nil }
    stream.open()
    defer { stream.close() }

    var data = Data()
    let bufferSize = 1_024
    let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: bufferSize)
    defer { buffer.deallocate() }

    while stream.hasBytesAvailable {
        let count = stream.read(buffer, maxLength: bufferSize)
        if count < 0 { return nil }
        if count == 0 { break }
        data.append(buffer, count: count)
    }

    return String(data: data, encoding: .utf8)
}

private final class CoordinatorMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
