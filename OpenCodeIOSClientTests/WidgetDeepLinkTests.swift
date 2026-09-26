import XCTest
@testable import OpenClient

final class WidgetDeepLinkTests: XCTestCase {
    private let widgetStorageKey = "OpenCodeWidgetSnapshotPayload"

    override func setUp() {
        super.setUp()
        clearWidgetPayloadStorage()
    }

    override func tearDown() {
        clearWidgetPayloadStorage()
        super.tearDown()
    }

    func testActionWidgetDeepLinkRoundTrips() throws {
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.actionURL(
            serverID: "server_1",
            projectID: "proj_1",
            directory: "/tmp/project",
            commandName: "test",
            providerID: "openai",
            modelID: "gpt-5",
            reasoningVariant: "balanced"
        ))

        let request = try XCTUnwrap(OpenCodeWidgetDeepLink.request(from: url))

        XCTAssertEqual(request.kind, .action(commandName: "test"))
        XCTAssertEqual(request.serverID, "server_1")
        XCTAssertEqual(request.projectID, "proj_1")
        XCTAssertEqual(request.directory, "/tmp/project")
        XCTAssertEqual(request.providerID, "openai")
        XCTAssertEqual(request.modelID, "gpt-5")
        XCTAssertEqual(request.reasoningVariant, "balanced")
        XCTAssertEqual(request.profile, .legacy)
    }

    func testSessionLinksKeepRawOwnerAndRejectUnknownOrDuplicateProfiles() throws {
        let snapshot = widgetSession(profile: .v2)
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(snapshot))
        let request = try XCTUnwrap(OpenCodeWidgetDeepLink.request(from: url))
        XCTAssertEqual(request.profile, .v2)
        XCTAssertEqual(request.serverID, snapshot.serverID)
        XCTAssertEqual(request.kind, .session(sessionID: snapshot.id))
        XCTAssertEqual(request.projectID, snapshot.projectID)
        XCTAssertEqual(request.directory, snapshot.directory)
        XCTAssertNil(OpenCodeWidgetDeepLink.request(from: URL(string: url.absoluteString + "&profile=legacy")!))
        XCTAssertNil(OpenCodeWidgetDeepLink.request(from: URL(string: url.absoluteString.replacingOccurrences(of: "profile=v2", with: "profile=future"))!))
        let old = URL(string: url.absoluteString.replacingOccurrences(of: "profile=v2&", with: ""))!
        XCTAssertEqual(OpenCodeWidgetDeepLink.request(from: old)?.profile, .legacy)
    }

    func testNotificationPWAHandoffURLParsesWithoutChangingIdentityOrLocation() throws {
        let url = try XCTUnwrap(URL(string: "openclient://widget/session?profile=legacy&serverID=http%3A%2F%2Fmac.local%3A4096%2F%7Copencode&sessionID=ses_1&projectID=project_1&directory=%2Ftmp%2Fa%20b"))

        let request = try XCTUnwrap(OpenCodeWidgetDeepLink.request(from: url))

        XCTAssertEqual(request.profile, .legacy)
        XCTAssertEqual(request.serverID, "http://mac.local:4096/|opencode")
        XCTAssertEqual(request.kind, .session(sessionID: "ses_1"))
        XCTAssertEqual(request.projectID, "project_1")
        XCTAssertEqual(request.directory, "/tmp/a b")
    }

    func testLegacyJSONDefaultsOnlyMissingProfileAndPreservesRawIDs() throws {
        let data = Data("""
        {"id":"raw|server","displayName":"Server","baseURL":"https://server.invalid","username":"user","generatedAt":0,"isLastConnected":true}
        """.utf8)
        let server = try JSONDecoder().decode(OpenCodeWidgetServerSnapshot.self, from: data)
        XCTAssertEqual(server.owner.profile, .legacy)
        XCTAssertEqual(server.id, "raw|server")
        XCTAssertEqual(server.owner.entityID(), "raw|server")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["profile"] = "future"
        XCTAssertThrowsError(try JSONDecoder().decode(OpenCodeWidgetServerSnapshot.self,
            from: JSONSerialization.data(withJSONObject: object)))
    }

    func testMergesAndRemovalAreScopedByProfileAndRawServer() {
        let store = OpenCodeWidgetStore()
        for profile in [OpenCodeProfileIdentity.legacy, .v2] {
            let server = widgetServer(profile: profile)
            store.updatingServer(server, projects: [widgetProject(profile: profile)],
                sessions: [widgetSession(profile: profile)], replacingSessionIDs: ["home-session"])
        }
        XCTAssertEqual(store.load().servers.count, 2)
        XCTAssertEqual(store.load().projects.count, 2)
        XCTAssertEqual(store.load().sessions.count, 2)
        XCTAssertEqual(store.load().lastConnectedServer()?.owner.profile, .v2)
        XCTAssertEqual(Set(store.load().sessions.map(\.entityID)).count, 2)
        store.removeSession(serverID: "raw|server", sessionID: "home-session")
        XCTAssertEqual(store.load().sessions.map { $0.owner.profile }, [.v2])
        store.removeSession(owner: .init(profile: .v2, serverID: "other"), sessionID: "home-session")
        XCTAssertEqual(store.load().sessions.count, 1)
    }

    func testAuthoritativeEmptyCatalogClearsOnlyItsOwner() {
        let store = OpenCodeWidgetStore()
        for profile in [OpenCodeProfileIdentity.legacy, .v2] {
            let server = widgetServer(profile: profile)
            let command = OpenCodeWidgetCommandSnapshot(id: "command", serverID: server.id, projectID: "home-project",
                directory: "/home-project", name: "test", summary: nil, sortTitle: "test", profile: profile)
            let model = OpenCodeWidgetModelSnapshot(id: "model", serverID: server.id, providerID: "provider",
                providerName: "Provider", modelID: "model", modelName: "Model", reasoningVariants: [], sortTitle: "model", profile: profile)
            store.updatingServer(server, projects: [widgetProject(profile: profile)], sessions: [widgetSession(profile: profile)],
                replacingSessionIDs: ["home-session"], commands: [command], replacingCommandProjectIDs: ["home-project"], models: [model])
        }
        let v2 = widgetServer(profile: .v2)
        store.updatingServer(v2, projects: [], sessions: [], replacingSessionIDs: [], projectsAreAuthoritative: false)
        XCTAssertEqual(store.load().projects.count, 2)
        XCTAssertEqual(store.load().commands.count, 2)
        XCTAssertEqual(store.load().models.count, 2)
        store.updatingServer(v2, projects: [], sessions: [], replacingSessionIDs: [],
            replacingCommandProjectIDs: ["home-project"], projectsAreAuthoritative: true, modelsAreAuthoritative: true)
        XCTAssertEqual(store.load().projects.map { $0.owner.profile }, [.legacy])
        XCTAssertEqual(store.load().sessions.map { $0.owner.profile }, [.legacy])
        XCTAssertEqual(store.load().commands.map { $0.owner.profile }, [.legacy])
        XCTAssertEqual(store.load().models.map { $0.owner.profile }, [.legacy])
    }

    func testUpdatingAnotherOwnerPreservesV2ActionCapabilities() {
        let store = OpenCodeWidgetStore()
        var v2 = widgetServer(profile: .v2)
        v2.supportsNewSession = true
        v2.supportsCommands = true
        store.updatingServer(v2, projects: [], sessions: [], replacingSessionIDs: [])
        store.updatingServer(widgetServer(profile: .legacy), projects: [], sessions: [], replacingSessionIDs: [])
        let stored = store.load().servers.first { $0.owner.profile == .v2 }
        XCTAssertEqual(stored?.offersNewSession, true)
        XCTAssertEqual(stored?.offersCommands, true)
        XCTAssertEqual(stored?.isLastConnected, false)
    }

    func testV2EntityIDsUseUnambiguousComponentFraming() {
        let owner = OpenCodeWidgetOwner(profile: .v2, serverID: "a|b")
        XCTAssertNotEqual(owner.entityID(["c"]), OpenCodeWidgetOwner(profile: .v2, serverID: "a").entityID(["b|c"]))
        XCTAssertNotEqual(owner.entityID(["x", "y|z"]), owner.entityID(["x|y", "z"]))
    }

    func testNewSessionWidgetDeepLinkRoundTrips() throws {
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.newSessionURL(
            serverID: "server_1",
            projectID: "global",
            directory: nil,
            providerID: "anthropic",
            modelID: "claude-opus-4-1",
            reasoningVariant: nil
        ))

        let request = try XCTUnwrap(OpenCodeWidgetDeepLink.request(from: url))

        XCTAssertEqual(request.kind, .newSession)
        XCTAssertEqual(request.serverID, "server_1")
        XCTAssertEqual(request.projectID, "global")
        XCTAssertNil(request.directory)
        XCTAssertEqual(request.providerID, "anthropic")
        XCTAssertEqual(request.modelID, "claude-opus-4-1")
        XCTAssertNil(request.reasoningVariant)
    }

    func testV2ActionLinksPreserveRawOwnerAndExplicitRootWhileOldPayloadsStayLegacy() throws {
        for action in [false, true] {
            let url = try XCTUnwrap(action
                ? OpenCodeWidgetDeepLink.actionURL(serverID: "raw|server", projectID: "global", directory: "/",
                    commandName: "test", providerID: nil, modelID: nil, reasoningVariant: nil, profile: .v2)
                : OpenCodeWidgetDeepLink.newSessionURL(serverID: "raw|server", projectID: "global", directory: "/",
                    providerID: nil, modelID: nil, reasoningVariant: nil, profile: .v2))
            let request = try XCTUnwrap(OpenCodeWidgetDeepLink.request(from: url))
            XCTAssertEqual(request.profile, .v2)
            XCTAssertEqual(request.serverID, "raw|server")
            XCTAssertEqual(request.directory, "/")
        }
        XCTAssertTrue(widgetServer(profile: .legacy).offersNewSession)
        XCTAssertFalse(widgetServer(profile: .v2).offersNewSession)
        XCTAssertFalse(widgetServer(profile: .v2).offersCommands)
    }

    func testActionWidgetDeepLinkRequiresCommand() {
        XCTAssertNil(OpenCodeWidgetDeepLink.actionURL(
            serverID: "server_1",
            projectID: "proj_1",
            directory: "/tmp/project",
            commandName: nil,
            providerID: nil,
            modelID: nil,
            reasoningVariant: nil
        ))

        XCTAssertNil(OpenCodeWidgetDeepLink.actionURL(
            serverID: "server_1",
            projectID: "proj_1",
            directory: "/tmp/project",
            commandName: "",
            providerID: nil,
            modelID: nil,
            reasoningVariant: nil
        ))
    }

    func testWidgetPayloadDecodesOlderSnapshotsWithoutShortcutMetadata() throws {
        let data = """
        {
          "servers": [],
          "projects": [],
          "sessions": [],
          "generatedAt": 0
        }
        """.data(using: .utf8)!

        let payload = try JSONDecoder().decode(OpenCodeWidgetSnapshotPayload.self, from: data)

        XCTAssertEqual(payload.commands, [])
        XCTAssertEqual(payload.models, [])
    }

    func testControlWidgetKindsAreStableAndDistinct() {
        XCTAssertEqual(OpenCodeWidgetKind.newSessionControl, "OpenCodeNewSessionControl")
        XCTAssertEqual(OpenCodeWidgetKind.actionControl, "OpenCodeActionControl")
        XCTAssertNotEqual(OpenCodeWidgetKind.newSessionControl, OpenCodeWidgetKind.newSessionShortcut)
        XCTAssertNotEqual(OpenCodeWidgetKind.actionControl, OpenCodeWidgetKind.actionShortcut)
    }

    func testWidgetStoreCapsPersistedModelsPerServer() {
        let models = (0 ..< 140).map { index in
            OpenCodeWidgetModelSnapshot(
                id: "server_1|provider|model_\(index)",
                serverID: "server_1",
                providerID: "provider",
                providerName: "Provider",
                modelID: "model_\(index)",
                modelName: "Model \(index)",
                reasoningVariants: [],
                sortTitle: "provider model \(index)"
            )
        }
        let payload = OpenCodeWidgetSnapshotPayload(
            servers: [OpenCodeWidgetServerSnapshot(
                id: "server_1",
                displayName: "Server",
                baseURL: "http://localhost:4096",
                username: "",
                generatedAt: Date(timeIntervalSince1970: 0),
                isLastConnected: true
            )],
            projects: [],
            sessions: [],
            models: models,
            generatedAt: Date(timeIntervalSince1970: 0)
        )

        OpenCodeWidgetStore().save(payload)

        let loaded = OpenCodeWidgetStore().load()
        XCTAssertEqual(loaded.models.count, 120)
        XCTAssertEqual(loaded.models.first?.modelID, "model_0")
        XCTAssertEqual(loaded.models.last?.modelID, "model_119")
    }

    func testWidgetStoreDropsOversizedPayloadWithoutDecoding() {
        widgetDefaults().set(Data(repeating: 0, count: 1_000_001), forKey: widgetStorageKey)

        XCTAssertEqual(OpenCodeWidgetStore().load(), .empty)
    }

    private func widgetDefaults() -> UserDefaults {
        UserDefaults(suiteName: OpenCodeWidgetStore.appGroupIdentifier) ?? .standard
    }

    private func clearWidgetPayloadStorage() {
        UserDefaults(suiteName: OpenCodeWidgetStore.appGroupIdentifier)?.removeObject(forKey: widgetStorageKey)
        UserDefaults.standard.removeObject(forKey: widgetStorageKey)
    }
}

private func widgetServer(profile: OpenCodeProfileIdentity) -> OpenCodeWidgetServerSnapshot {
    .init(id: "raw|server", displayName: "Server", baseURL: "https://server.invalid", username: "user",
        generatedAt: .distantPast, isLastConnected: true, profile: profile)
}

private func widgetProject(profile: OpenCodeProfileIdentity) -> OpenCodeWidgetProjectSnapshot {
    .init(id: "home-project", serverID: "raw|server", title: "Home", worktree: "/home-project", sortTitle: "home", profile: profile)
}

private func widgetSession(profile: OpenCodeProfileIdentity, serverID: String = "raw|server",
                           directory: String = "/home-project", projectID: String = "home-project") -> OpenCodeWidgetSessionSnapshot {
    .init(id: "home-session", serverID: serverID, projectID: projectID, title: "Snapshot title", projectLabel: "Home",
        directory: directory, workspaceID: nil, status: .ready, summaryKind: .snippet, summaryText: "Snapshot",
        updatedAt: nil, lastActiveAt: .distantPast, isPinned: true, pinOrder: 0, profile: profile)
}

@MainActor
final class WidgetSessionRoutingTests: XCTestCase {
    func testColdLaunchPreparationReservesSessionBeforeAutomaticConnectionTaskRuns() throws {
        let model = AppViewModel(backendFactory: HomeTestBackend())
        defer { model.disconnect() }
        model.config = .init(baseURL: "https://cold-reservation.invalid", password: "test", apiPreference: .automatic)
        model.recentServerConfigs = [model.config]
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(widgetSession(
            profile: .v2,
            serverID: model.config.recentServerID
        )))

        model.prepareOpenURLPresentation(url)

        XCTAssertEqual(model.deepLinkRoutingStore.pendingWidgetSession?.request, OpenCodeWidgetDeepLink.request(from: url))
        XCTAssertFalse(model.deepLinkRoutingStore.allowsAutomaticConnection)
    }

    func testWarmAutomaticV2OpensCanonicalSessionWithoutChangingPreferenceOrCreating() async throws {
        let (model, backend) = try await warmModel()
        defer { model.disconnect() }
        let previousPresentationRequest = model.chatDetailPresentationRequest
        model.selectedProjectContentTab = .git
        model.appShellFacade.selectActivity()
        await model.handleOpenURL(try link(model))
        XCTAssertEqual(model.selectedSession?.id, "home-session")
        XCTAssertEqual(model.selectedSession?.title, "Recent chat", "Never select the stale widget's title or location")
        XCTAssertEqual(model.currentProject?.id, "home-project")
        XCTAssertEqual(model.selectedProjectContentTab, .sessions)
        XCTAssertEqual(
            model.appShellFacade.detailRoute(isCompact: true),
            .chat(.init(sessionID: "home-session", presentationRequest: model.chatDetailPresentationRequest))
        )
        XCTAssertEqual(model.appShellFacade.contentRoute(isCompact: true), .projectContent)
        XCTAssertEqual(model.chatDetailPresentationRequest, previousPresentationRequest + 1)
        XCTAssertEqual(model.config.apiPreference, .automatic)
        XCTAssertEqual(model.recentServerConfigs.first?.apiPreference, .automatic)
        XCTAssertEqual(backend.storedSessions.count, 1)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testProjectListDeepLinkRequestsDetailOnlyAfterSessionHydrationCommits() async throws {
        let (model, backend) = try await warmModel()
        defer { model.disconnect() }
        model.currentProject = nil
        model.selectedSession = nil
        model.appShellFacade.selectProjectContent()
        let previousPresentationRequest = model.chatDetailPresentationRequest
        let transcriptRequested = expectation(description: "Transcript hydration started")
        var releaseTranscript: CheckedContinuation<Void, Never>?
        backend.beforeTranscript = {
            await withCheckedContinuation { continuation in
                releaseTranscript = continuation
                transcriptRequested.fulfill()
            }
        }
        defer {
            releaseTranscript?.resume()
            backend.beforeTranscript = nil
        }

        let url = try link(model)
        let route = Task { await model.handleOpenURL(url) }
        await fulfillment(of: [transcriptRequested], timeout: 2)

        XCTAssertEqual(model.currentProject?.id, "home-project")
        XCTAssertEqual(model.selectedSession?.id, "home-session")
        XCTAssertEqual(model.chatDetailPresentationRequest, previousPresentationRequest)

        releaseTranscript?.resume()
        releaseTranscript = nil
        await route.value

        XCTAssertEqual(model.chatDetailPresentationRequest, previousPresentationRequest + 1)
        XCTAssertEqual(model.appShellFacade.contentRoute(isCompact: true), .projectContent)
        XCTAssertEqual(
            model.appShellFacade.detailRoute(isCompact: true),
            .chat(.init(sessionID: "home-session", presentationRequest: model.chatDetailPresentationRequest))
        )
    }

    func testLegacyCanonicalSessionOpensBeforeProjectCatalogDiscoversItsProject() async throws {
        let (model, backend) = try await warmModel()
        defer { model.disconnect() }
        backend.projectsSnapshotOverride = []
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(widgetSession(
            profile: .legacy,
            serverID: model.config.recentServerID
        )))

        await model.handleOpenURL(url)

        XCTAssertEqual(model.selectedSession?.id, "home-session")
        XCTAssertEqual(model.currentProject?.id, "home-project")
        XCTAssertEqual(model.currentProject?.worktree, "/home-project")
        XCTAssertEqual(model.projects.map(\.id), ["home-project"])
        XCTAssertEqual(model.selectedProjectContentTab, .sessions)
        XCTAssertEqual(
            model.appShellFacade.detailRoute(isCompact: true),
            .chat(.init(sessionID: "home-session", presentationRequest: model.chatDetailPresentationRequest))
        )
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testMalformedWidgetHandoffLeavesSanitizedDiagnostic() async throws {
        let (model, _) = try await warmModel()
        defer { model.disconnect() }
        model.isShowingDebugProbe = true
        let url = try XCTUnwrap(URL(string: "openclient://widget/session?profile=unknown&serverID=secret&sessionID=ses_1&projectID=project_1"))

        await model.handleOpenURL(url)

        XCTAssertTrue(model.debugProbeLog.contains(where: { $0.contains("widget handoff rejected stage=parse") }))
        XCTAssertFalse(model.debugProbeLog.contains(where: { $0.contains("secret") }))
    }

    func testWrongProfileUnknownServerAndLocationDoNotSelectOrFallback() async throws {
        for invalid in ["profile", "server", "directory", "project", "unknown"] {
            let (model, backend) = try await warmModel()
            defer { model.disconnect() }
            let snapshot = widgetSession(profile: invalid == "profile" ? .legacy : .v2,
                serverID: invalid == "server" ? "missing" : model.config.recentServerID,
                directory: invalid == "directory" ? "/wrong" : "/home-project",
                projectID: invalid == "project" ? "missing" : "home-project")
            var url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(snapshot))
            if invalid == "unknown" {
                url = try XCTUnwrap(URL(string: url.absoluteString.replacingOccurrences(of: "profile=v2", with: "profile=unknown")))
            }
            await model.handleOpenURL(url)
            XCTAssertNil(model.selectedSession, invalid)
            XCTAssertNil(model.currentProject, invalid)
            XCTAssertTrue(backend.submissions.isEmpty)
            XCTAssertEqual(backend.storedSessions.count, 1)
        }
    }

    func testLateCanonicalReadCannotSelectOnReplacementConnection() async throws {
        let (model, backend) = try await warmModel()
        defer { model.disconnect() }
        let began = expectation(description: "Canonical session read suspended")
        var release: CheckedContinuation<Void, Never>?
        backend.beforeSessionFetch = {
            await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
        }
        let url = try link(model)
        let route = Task { await model.handleOpenURL(url) }
        await fulfillment(of: [began], timeout: 1)
        model.backendConnection?.close()
        model.backendConnection = try await backend.connect()
        release?.resume()
        await route.value
        backend.beforeSessionFetch = nil
        XCTAssertNil(model.selectedSession)
        XCTAssertNil(model.currentProject)
    }

    func testPendingLinkWaitsForMatchingConnectionButDoesNotUpgradeLegacy() async throws {
        for legacy in [false, true] {
            let (model, backend) = try await warmModel()
            defer { model.disconnect() }
            model.connectionStore.beginConnecting()
            model.connectionAttemptID = UUID()
            let url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(widgetSession(
                profile: legacy ? .legacy : .v2, serverID: model.config.recentServerID)))
            let route = Task { await model.handleOpenURL(url) }
            // Yield until the route has subscribed to the connection's published completion.
            for _ in 0..<10 { await Task.yield() }
            XCTAssertNil(model.selectedSession)
            XCTAssertNotNil(model.deepLinkRoutingStore.pendingWidgetSession)
            model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
            model.connectionStore.finishConnecting()
            model.connectionAttemptID = nil
            await route.value
            XCTAssertEqual(model.selectedSession?.id, legacy ? nil : "home-session")
            XCTAssertNil(model.deepLinkRoutingStore.pendingWidgetSession)
            XCTAssertEqual(model.config.apiPreference, .automatic)
            XCTAssertTrue(backend.submissions.isEmpty)
        }
    }

    func testUnknownV2ActionServerDoesNotPresentAWorkingComposer() async throws {
        let (model, backend) = try await warmModel()
        defer { model.disconnect() }
        let url = try XCTUnwrap(URL(string: "openclient://widget/new-session?profile=v2&serverID=raw&projectID=home-project"))
        model.prepareOpenURLPresentation(url)
        await model.handleOpenURL(url)
        XCTAssertNil(model.newProjectChatSheetRequest)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testPendingLinkDoesNotReplaceAnUnrelatedConnectionAttempt() async throws {
        let (model, backend) = try await warmModel()
        defer { model.disconnect() }
        let active = model.config
        let other = OpenCodeServerConfig(baseURL: "https://other.invalid", password: "test", apiPreference: .automatic)
        model.recentServerConfigs.append(other)
        model.connectionStore.beginConnecting()
        let attempt = UUID()
        model.connectionAttemptID = attempt
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(widgetSession(profile: .v2, serverID: other.recentServerID)))
        await model.handleOpenURL(url)
        XCTAssertEqual(model.connectionAttemptID, attempt)
        XCTAssertEqual(model.config, active)
        XCTAssertNil(model.selectedSession)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testPendingLinkReplacesAutomaticConnectionAttemptForDifferentSavedServer() async throws {
        let (model, backend) = try await warmModel()
        defer { model.disconnect() }
        let target = OpenCodeServerConfig(
            baseURL: "https://notification-target.invalid",
            password: "target",
            apiPreference: .automatic
        )
        model.recentServerConfigs.append(target)
        model.automaticConnectionRetryEnabled = true
        model.connectionStore.beginConnecting()
        model.connectionAttemptID = UUID()
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(widgetSession(
            profile: .v2,
            serverID: target.recentServerID
        )))

        await model.handleOpenURL(url)

        XCTAssertEqual(model.config.recentServerID, target.recentServerID)
        XCTAssertFalse(model.automaticConnectionRetryEnabled)
        XCTAssertNil(model.selectedSession, "The generic test backend cannot satisfy a resolved OpenCode profile")
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testColdRouteUsesSavedPreferenceAndFailsClosedWithoutResolvedProfile() async throws {
        let backend = HomeTestBackend()
        let model = AppViewModel(backendFactory: backend)
        defer { model.disconnect() }
        let saved = OpenCodeServerConfig(baseURL: "https://cold-widget.invalid", password: "saved", apiPreference: .automatic)
        model.config = .init(baseURL: saved.baseURL, password: "stale", apiPreference: .legacy)
        model.recentServerConfigs = [saved]
        model.automaticConnectionRetryEnabled = false
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(widgetSession(profile: .v2, serverID: saved.recentServerID)))
        await model.handleOpenURL(url)
        XCTAssertEqual(model.config.apiPreference, .automatic)
        XCTAssertEqual(model.config.recentServerID, saved.recentServerID)
        XCTAssertNil(model.connectionStore.apiProfile, "A generic backend cannot stand in for a resolved OpenCode profile")
        XCTAssertNil(model.selectedSession)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    private func warmModel() async throws -> (AppViewModel, HomeTestBackend) {
        let backend = HomeTestBackend()
        let model = AppViewModel(backendFactory: backend)
        model.config = .init(baseURL: "https://widget-\(UUID().uuidString).invalid", password: "test", apiPreference: .automatic)
        model.recentServerConfigs = [model.config]
        model.automaticConnectionRetryEnabled = false
        model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        model.backendConnection = try await backend.connect()
        return (model, backend)
    }

    private func link(_ model: AppViewModel) throws -> URL {
        try XCTUnwrap(OpenCodeWidgetDeepLink.sessionURL(widgetSession(profile: .v2, serverID: model.config.recentServerID)))
    }
}

@MainActor
final class WidgetActionRoutingTests: XCTestCase {
    func testNewSessionIsValidatedBeforePresentationAndDoesNotReplaceEditedComposer() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        XCTAssertFalse(model.newProjectChatFacade.ownsPaywallPresentation)
        let url = try link(model)
        model.prepareOpenURLPresentation(url)
        XCTAssertNil(model.newProjectChatSheetRequest)
        await model.handleOpenURL(url)
        let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
        XCTAssertTrue(model.newProjectChatFacade.isReady(for: sheet))
        XCTAssertTrue(services.creations.isEmpty)
        await model.handleOpenURL(try link(model, project: "global", directory: nil))
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, sheet.id)
        XCTAssertEqual(model.newProjectChatSheetRequest?.workspaceDirectory, "/home-project")
    }

    func testWrongProfileServerStaleDestinationAndMissingCommandNeverCreate() async throws {
        for invalid in ["profile", "server", "project", "directory", "command"] {
            let (model, services) = makeModel()
            defer { model.disconnect() }
            let url = try link(model, action: true,
                project: invalid == "project" ? "missing" : "home-project",
                directory: invalid == "directory" ? "/stale" : "/home-project",
                profile: invalid == "profile" ? .legacy : .v2,
                server: invalid == "server" ? "unknown" : nil,
                command: invalid == "command" ? "missing" : "test")
            await model.handleOpenURL(url)
            XCTAssertTrue(services.creations.isEmpty, invalid)
            XCTAssertTrue(services.commands.isEmpty, invalid)
            XCTAssertNil(model.newProjectChatSheetRequest)
        }
    }

    func testCommandUncertainOrWrongOwnerReceiptNeverCreatesOrPostsAgain() async throws {
        for wrongOwner in [false, true] {
            let (model, services) = makeModel()
            defer { model.disconnect() }
            services.receipt = { request in
                wrongOwner ? .accepted(sessionID: "other-session", messageID: request.messageID)
                    : .uncertain(sessionID: request.sessionID, messageID: request.messageID)
            }
            let url = try link(model, action: true)
            await model.handleOpenURL(url)
            await model.handleOpenURL(url)
            XCTAssertEqual(services.creations.count, 1)
            XCTAssertEqual(services.commands.count, 1)
            XCTAssertEqual(model.usageMeter.createdSessionCount, 1)
            XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
            let request = try XCTUnwrap(services.commands.first)
            XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: request.messageID, sessionID: request.sessionID), .uncertain)
            let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "/test", messageID: request.messageID, sessionID: request.sessionID)
            XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: try XCTUnwrap(model.backendConnection?.id)))
            await model.handleOpenURL(url)
            XCTAssertEqual(services.commands.count, 1)
            XCTAssertTrue(services.backend.submissions.isEmpty, "Widget commands must not add an evaluation prompt")
        }
    }

    func testRejectedCommandRefundsAndRetriesOnlyInCreatedSession() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        services.receipt = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        let url = try link(model, action: true)
        await model.handleOpenURL(url)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 0)
        services.receipt = nil
        await model.handleOpenURL(url)
        XCTAssertEqual(services.creations.count, 1)
        XCTAssertEqual(services.commands.count, 2)
        XCTAssertNotEqual(services.commands.first?.messageID, services.commands.last?.messageID)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
        XCTAssertEqual(services.completionReads, 0, "Admission must not be presented as command completion")
    }

    func testAcceptedCommandCannotRunAgainUntilItsOwnCanonicalTurnCompletes() async throws {
        let (model, services) = makeModel()
        model.commerceFacade.debugEntitlementOverride = .unlocked
        defer { model.disconnect() }
        let url = try link(model, action: true)
        await model.handleOpenURL(url)
        await model.handleOpenURL(url)
        XCTAssertEqual(services.creations.count, 1)
        let input = try XCTUnwrap(services.commands.first)
        services.turn = .init(sessionID: input.sessionID, userMessageID: "another-input",
            assistantMessageID: "answer", text: "done", failed: false)
        await model.handleOpenURL(url)
        XCTAssertEqual(services.creations.count, 1)
        services.turn = .init(sessionID: input.sessionID, userMessageID: input.messageID,
            assistantMessageID: "answer", text: "done", failed: false)
        await model.handleOpenURL(url)
        XCTAssertEqual(services.creations.count, 2)
        XCTAssertEqual(services.commands.count, 2)
    }

    func testLostCreateResponseBlocksDuplicateAndRefundsUnspentPrompt() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        services.losesCreateReceipt = true
        let url = try link(model, action: true)
        await model.handleOpenURL(url)
        await model.handleOpenURL(url)
        XCTAssertEqual(services.creations.count, 1)
        XCTAssertTrue(services.commands.isEmpty)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 0)
    }

    func testNewChatUncertaintyRetainsEditedDraftAndUsesOwnedReceipt() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        await model.handleOpenURL(try link(model))
        let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
        services.backend.admissionResult = { .accepted(sessionID: "wrong-owner", messageID: $0.messageID) }
        let first = await submit(model, sheet: sheet)
        let edited = await submit(model, sheet: sheet, text: "Edited draft", id: "edited")
        XCTAssertFalse(first)
        XCTAssertFalse(edited)
        XCTAssertEqual(services.creations.count, 1)
        XCTAssertEqual(services.backend.submissions.count, 1)
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, sheet.id)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
        let input = try XCTUnwrap(services.backend.submissions.first)
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: input.text, messageID: input.messageID, sessionID: input.sessionID)
        XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: try XCTUnwrap(model.backendConnection?.id)))
        services.backend.admissionResult = nil
        let accepted = await submit(model, sheet: sheet, text: "Edited draft", id: "edited")
        XCTAssertTrue(accepted)
        XCTAssertEqual(services.creations.count, 1)
        XCTAssertEqual(services.backend.submissions.last?.text, "Edited draft")
        XCTAssertEqual(services.backend.submissions.count, 2)
    }

    func testWidgetPaywallKeepsComposerAndDoesNotCreate() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        await model.handleOpenURL(try link(model))
        let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
        let usage = ShareQuotaUsageStore()
        usage.meter = .init(promptDay: OpenClientUsageMeter.dayString(for: Date()), dailyPromptCount: 999, createdSessionCount: 0)
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free), usageStore: usage)
        model.commerceFacade.hydratePersistedState()
        let sent = await submit(model, sheet: sheet, text: "Do not lose this edit")
        XCTAssertFalse(sent)
        XCTAssertTrue(services.creations.isEmpty)
        XCTAssertTrue(model.newProjectChatFacade.ownsPaywallPresentation)
        XCTAssertFalse(model.newProjectChatFacade.shouldDismissForPaywall(sheet))
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, sheet.id)
    }

    func testRejectedWidgetDraftReusesSessionAndAppliesEditedModelBeforePosting() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        await model.handleOpenURL(try link(model))
        let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
        services.backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        let first = await submit(model, sheet: sheet)
        XCTAssertFalse(first)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 0)
        let selection = try XCTUnwrap(model.backendConnection?.sessionSelection as? ShareSelectionService)
        services.backend.admissionResult = { request in
            XCTAssertEqual(selection.operations, ["model:edited:default"])
            return .accepted(sessionID: request.sessionID, messageID: request.messageID)
        }
        let accepted = await model.newProjectChatFacade.startNewChat(title: "", prompt: "Edited", agentMentions: [],
            attachments: [], messageID: "edited", partID: "edited-part",
            composerSelection: .init(agentName: nil, modelReference: .init(providerID: "fake", modelID: "edited"), reasoningVariant: nil),
            projectID: "home-project", workspaceDirectory: "/home-project", workspaceSelection: .main, newWorkspaceName: "", request: sheet)
        XCTAssertTrue(accepted)
        XCTAssertEqual(services.creations.count, 1)
        XCTAssertEqual(services.backend.submissions.last?.model?.modelID, "edited")
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
    }

    func testConcurrentCommandDeliveryAndLateReceiptCannotAffectReplacementConnection() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        let began = expectation(description: "Command suspended")
        var release: CheckedContinuation<Void, Never>?
        services.beforeCommand = {
            await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
        }
        let url = try link(model, action: true)
        let first = Task { await model.handleOpenURL(url) }
        await fulfillment(of: [began], timeout: 1)
        await model.handleOpenURL(url)
        XCTAssertEqual(services.creations.count, 1)
        XCTAssertEqual(services.commands.count, 1)
        model.backendConnection?.close()
        model.backendConnection = try await services.backend.connect()
        model.errorMessage = "Replacement error"
        release?.resume()
        await first.value
        services.beforeCommand = nil
        XCTAssertEqual(model.errorMessage, "Replacement error")
        await model.handleOpenURL(url)
        XCTAssertEqual(services.commands.count, 1)
    }

    func testLateWidgetPromptAcceptanceCannotConsumeReplacementComposer() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        await model.handleOpenURL(try link(model))
        let original = try XCTUnwrap(model.newProjectChatSheetRequest)
        services.backend.admissionResult = { input in
            model.dismissNewProjectChatSheet()
            model.presentNewProjectChatSheet(initialContent: .init(text: "Replacement edit", attachments: []))
            return .accepted(sessionID: input.sessionID, messageID: input.messageID)
        }
        let sent = await submit(model, sheet: original)
        XCTAssertFalse(sent)
        model.newProjectChatFacade.dismissNewChat(requestID: original.id)
        XCTAssertEqual(model.newProjectChatSheetRequest?.initialContent?.text, "Replacement edit")
    }

    func testLateWidgetReceiptsSettleOnlyTheirOriginalReservationAfterReplacement() async throws {
        for action in [false, true] {
            for outcome in ["rejected", "accepted", "uncertain", "wrong-session", "wrong-message"] {
                for replaceCommerce in [false, true] {
                    let (model, services) = makeModel()
                    defer { model.disconnect() }
                    let originalCommerce = model.commerceFacade
                    let began = expectation(description: "Widget submission suspended")
                    var release: CheckedContinuation<Void, Never>?
                    let suspend = { @MainActor in
                        await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
                    }
                    let receipt: (String, String) -> BackendAdmission = { sessionID, messageID in
                        switch outcome {
                        case "rejected": return .rejected(sessionID: sessionID, messageID: messageID)
                        case "accepted": return .accepted(sessionID: sessionID, messageID: messageID)
                        case "wrong-session": return .rejected(sessionID: "other", messageID: messageID)
                        case "wrong-message": return .rejected(sessionID: sessionID, messageID: "other")
                        default: return .uncertain(sessionID: sessionID, messageID: messageID)
                        }
                    }
                    let operation: Task<Void, Never>
                    if action {
                        services.beforeCommand = suspend
                        services.receipt = { receipt($0.sessionID, $0.messageID) }
                        let url = try link(model, action: true)
                        operation = Task { await model.handleOpenURL(url) }
                    } else {
                        await model.handleOpenURL(try link(model))
                        let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
                        services.beforePrompt = { _ in await suspend() }
                        services.backend.admissionResult = { receipt($0.sessionID, $0.messageID) }
                        operation = Task { _ = await self.submit(model, sheet: sheet) }
                    }
                    await fulfillment(of: [began], timeout: 1)
                    XCTAssertEqual(originalCommerce.usageMeter.dailyPromptCount, 1)
                    model.backendConnection?.close()
                    model.backendConnection = services.connection()
                    if replaceCommerce {
                        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free), usageStore: ShareQuotaUsageStore())
                    }
                    XCTAssertTrue(model.reserveUserPromptIfAllowed(), "A newer unrelated reservation")
                    model.errorMessage = "New connection error"
                    release?.resume()
                    await operation.value
                    services.beforeCommand = nil
                    services.beforePrompt = nil
                    let originalRemaining = outcome == "rejected" ? 0 : 1
                    XCTAssertEqual(originalCommerce.usageMeter.dailyPromptCount, originalRemaining + (replaceCommerce ? 0 : 1))
                    XCTAssertEqual(model.usageMeter.dailyPromptCount, replaceCommerce ? 1 : originalRemaining + 1)
                    XCTAssertEqual(model.errorMessage, "New connection error")
                    if action {
                        await model.handleOpenURL(try link(model, action: true))
                        XCTAssertEqual(services.commands.count, 1)
                    }
                    XCTAssertEqual(originalCommerce.usageMeter.dailyPromptCount, originalRemaining + (replaceCommerce ? 0 : 1),
                        "A retained checkpoint must not refund its reservation twice")
                    model.refundReservedUserPromptIfNeeded()
                    XCTAssertEqual(model.usageMeter.dailyPromptCount, replaceCommerce ? 0 : originalRemaining)
                }
            }
        }
    }

    func testCompletedWidgetCommandRevalidatesOnSameOwnerReconnectBeforeNewRun() async throws {
        let (model, services) = makeModel()
        model.commerceFacade.debugEntitlementOverride = .unlocked
        defer { model.disconnect() }
        let url = try link(model, action: true)
        await model.handleOpenURL(url)
        let input = try XCTUnwrap(services.commands.first)
        let replacement = WidgetActionServices(backend: services.backend)
        model.backendConnection?.close()
        model.backendConnection = replacement.connection()
        await model.handleOpenURL(url)
        XCTAssertEqual(replacement.completionReads, 1)
        XCTAssertTrue(replacement.creations.isEmpty)
        replacement.turn = .init(sessionID: input.sessionID, userMessageID: "another-input", assistantMessageID: "answer", text: "done", failed: false)
        await model.handleOpenURL(url)
        XCTAssertTrue(replacement.creations.isEmpty)
        replacement.turn = .init(sessionID: input.sessionID, userMessageID: input.messageID, assistantMessageID: "answer", text: "done", failed: false)
        await model.handleOpenURL(url)
        XCTAssertEqual(replacement.creations.count, 1)
        XCTAssertEqual(replacement.commands.count, 1)
        XCTAssertEqual(services.completionReads, 0, "Do not reuse a service from the closed connection")
    }

    func testCanonicalWidgetAdmissionSurvivesNewConnectionLedgerPruningAndLateRejection() async throws {
        for action in [false, true] {
            let (model, services) = makeModel()
            defer { model.disconnect() }
            let originalConnectionID = try XCTUnwrap(model.backendConnection?.id)
            let began = expectation(description: "Original widget POST suspended")
            var release: CheckedContinuation<Void, Never>?
            var prompt: BackendSubmission?
            let operation: Task<Void, Never>
            if action {
                services.beforeCommand = {
                    await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
                }
                services.receipt = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
                let url = try link(model, action: true)
                operation = Task { await model.handleOpenURL(url) }
            } else {
                await model.handleOpenURL(try link(model))
                let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
                services.beforePrompt = { input in
                    prompt = input
                    await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
                }
                services.backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
                operation = Task { _ = await self.submit(model, sheet: sheet) }
            }
            await fulfillment(of: [began], timeout: 1)
            let sessionID = try XCTUnwrap(action ? services.commands.first?.sessionID : prompt?.sessionID)
            let messageID = try XCTUnwrap(action ? services.commands.first?.messageID : prompt?.messageID)
            let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Canonical input", messageID: messageID, sessionID: sessionID)
            XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: originalConnectionID))
            XCTAssertEqual(model.chatStore.promptAdmissionPhase(messageID: messageID, sessionID: sessionID,
                connectionID: originalConnectionID), .admitted)

            model.backendConnection?.close()
            model.backendConnection = services.connection()
            let newConnectionID = try XCTUnwrap(model.backendConnection?.id)
            XCTAssertTrue(model.reserveUserPromptIfAllowed())
            let newerInput = BackendSubmission(sessionID: "new-session", messageID: "new-input", text: "New connection prompt")
            XCTAssertTrue(model.chatStore.beginPromptAdmission(newerInput, connectionID: newConnectionID))
            XCTAssertNil(model.chatStore.promptAdmissionPhase(messageID: messageID, sessionID: sessionID,
                connectionID: originalConnectionID), "The real begin API must prune the old entry")
            model.errorMessage = "New connection error"
            release?.resume()
            await operation.value
            services.beforeCommand = nil
            services.beforePrompt = nil

            XCTAssertEqual(model.usageMeter.dailyPromptCount, 2, "Canonical admission must win over the late rejected receipt")
            XCTAssertEqual(model.errorMessage, "New connection error")
            XCTAssertEqual(model.chatStore.promptAdmissionPhase(messageID: newerInput.messageID,
                sessionID: newerInput.sessionID, connectionID: newConnectionID), .submitting)
            XCTAssertNil(model.chatStore.promptAdmissionPhase(messageID: messageID, sessionID: sessionID,
                connectionID: originalConnectionID), "Retaining operation evidence must not restore pruned ledger records")
            if action {
                services.turn = .init(sessionID: sessionID, userMessageID: messageID,
                    assistantMessageID: "completed-answer", text: "done", failed: false)
                model.commerceFacade.debugEntitlementOverride = .unlocked
                services.receipt = nil
                await model.handleOpenURL(try link(model, action: true))
                XCTAssertEqual(services.creations.count, 2, "The accepted checkpoint must remain eligible for verified completion recovery")
            }
        }
    }

    func testCheckpointRetainsOnlyExactAdmissionEvidenceWithoutRetainingLedgerHistory() async throws {
        let (model, _) = makeModel()
        defer { model.disconnect() }
        let connectionID = try XCTUnwrap(model.backendConnection?.id)
        let input = BackendSubmission(sessionID: "original-session", messageID: "original-input", text: "Original")
        XCTAssertTrue(model.chatStore.beginPromptAdmission(input, connectionID: connectionID))
        let checkpoint = NewProjectChatCheckpoint(connectionID: connectionID, messageID: input.messageID, partID: "part")
        checkpoint.admission = .submitting
        let evidence = checkpoint.retainAdmissionEvidence(in: model.chatStore, sessionID: input.sessionID)
        defer { evidence.cancel() }
        let wrongSession = OpenCodeMessageEnvelope.local(role: "user", text: "Wrong", messageID: input.messageID, sessionID: "other-session")
        XCTAssertFalse(model.confirmCanonicalPromptAdmission(wrongSession.info, connectionID: connectionID))
        XCTAssertEqual(checkpoint.admission, .submitting)
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: input.text, messageID: input.messageID, sessionID: input.sessionID)
        XCTAssertFalse(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: UUID()))
        XCTAssertEqual(checkpoint.admission, .submitting)
        XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: connectionID))
        XCTAssertEqual(checkpoint.admission, .admitted)
        let nextConnectionID = UUID()
        XCTAssertTrue(model.chatStore.beginPromptAdmission(.init(sessionID: "next-session", messageID: input.messageID, text: "New"),
            connectionID: nextConnectionID))
        model.chatStore.applyPromptAdmission(.rejected, messageID: input.messageID, connectionID: nextConnectionID)
        XCTAssertEqual(checkpoint.admission, .admitted)
        XCTAssertEqual(model.chatStore.promptAdmissions.count, 1)
        XCTAssertNil(model.chatStore.promptAdmissionPhase(messageID: input.messageID, sessionID: input.sessionID, connectionID: connectionID))
    }

    func testLateRejectionDoesNotRefundANewerUsageDay() async throws {
        for action in [false, true] {
            let (model, services) = makeModel()
            defer { model.disconnect() }
            let nextDay = OpenClientUsageMeter.dayString(for: try XCTUnwrap(Calendar.current.date(byAdding: .day, value: 1, to: Date())))
            let receipt: (String, String) -> BackendAdmission = { sessionID, messageID in
                model.commerceFacade.usageMeter = .init(promptDay: nextDay, dailyPromptCount: 1, createdSessionCount: 1)
                return .rejected(sessionID: sessionID, messageID: messageID)
            }
            if action {
                services.receipt = { receipt($0.sessionID, $0.messageID) }
                await model.handleOpenURL(try link(model, action: true))
            } else {
                await model.handleOpenURL(try link(model))
                let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
                services.backend.admissionResult = { receipt($0.sessionID, $0.messageID) }
                _ = await submit(model, sheet: sheet)
            }
            XCTAssertEqual(model.usageMeter.promptDay, nextDay)
            XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
        }
    }

    func testReconnectCompletionReadCannotCreateOnASecondReplacement() async throws {
        let (model, services) = makeModel()
        model.commerceFacade.debugEntitlementOverride = .unlocked
        defer { model.disconnect() }
        let url = try link(model, action: true)
        await model.handleOpenURL(url)
        let input = try XCTUnwrap(services.commands.first)
        let replacement = WidgetActionServices(backend: services.backend)
        replacement.turn = .init(sessionID: input.sessionID, userMessageID: input.messageID, assistantMessageID: "answer", text: "done", failed: false)
        let finalConnection = replacement.connection()
        replacement.beforeCompletion = {
            model.backendConnection?.close()
            model.backendConnection = finalConnection
            model.errorMessage = "Another connection owns the UI"
        }
        model.backendConnection?.close()
        model.backendConnection = replacement.connection()
        await model.handleOpenURL(url)
        XCTAssertTrue(replacement.creations.isEmpty)
        XCTAssertTrue(replacement.commands.isEmpty)
        XCTAssertEqual(model.errorMessage, "Another connection owns the UI")
        replacement.beforeCompletion = nil
        await model.handleOpenURL(url)
        XCTAssertEqual(replacement.creations.count, 1, "The old completed checkpoint was retained for fresh revalidation")
    }

    func testReconnectCannotRetireUncertainOrWrongOwnerCommand() async throws {
        for invalid in ["uncertain", "profile", "config", "scope"] {
            let (model, services) = makeModel()
            model.commerceFacade.debugEntitlementOverride = .unlocked
            defer { model.disconnect() }
            if invalid == "uncertain" { services.receipt = { .uncertain(sessionID: $0.sessionID, messageID: $0.messageID) } }
            let url = try link(model, action: true)
            await model.handleOpenURL(url)
            let input = try XCTUnwrap(services.commands.first)
            let replacement = WidgetActionServices(backend: services.backend)
            if invalid != "uncertain" {
                replacement.turn = .init(sessionID: input.sessionID, userMessageID: input.messageID, assistantMessageID: "answer", text: "done", failed: false)
            }
            model.backendConnection?.close()
            model.backendConnection = replacement.connection()
            if invalid == "profile" { model.connectionStore.apiProfile = .legacy }
            if invalid == "config" {
                model.config.password = "changed"
                model.recentServerConfigs = [model.config]
            }
            if invalid == "scope" { replacement.sessionDirectoryOverride = "/other" }
            await model.handleOpenURL(url)
            XCTAssertTrue(replacement.creations.isEmpty, invalid)
            XCTAssertTrue(replacement.commands.isEmpty, invalid)
            XCTAssertEqual(replacement.completionReads, invalid == "uncertain" ? 1 : 0, invalid)
        }
    }

    func testWidgetRoutingErrorClearsOnValidDraftRevalidationAndCancelOnlyWhenOwned() async throws {
        for cancel in [false, true] {
            for unrelated in [false, true] {
                let (model, _) = makeModel()
                defer { model.disconnect() }
                await model.handleOpenURL(try link(model, action: true, command: "missing"))
                XCTAssertNotNil(model.errorMessage)
                if unrelated { model.errorMessage = "Unrelated error" }
                if cancel {
                    model.newProjectChatFacade.dismissNewChat()
                } else {
                    await model.handleOpenURL(try link(model))
                    let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
                    XCTAssertTrue(model.newProjectChatFacade.isReady(for: sheet))
                }
                XCTAssertEqual(model.errorMessage, unrelated ? "Unrelated error" : nil)
            }
        }
        let (model, _) = makeModel()
        defer { model.disconnect() }
        await model.handleOpenURL(try link(model))
        let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
        await model.handleOpenURL(try link(model, action: true, command: "missing"))
        XCTAssertNotNil(model.errorMessage)
        await model.newProjectChatFacade.retryShare(sheet)
        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, sheet.id)
        await model.handleOpenURL(try link(model, action: true, command: "missing"))
        let reusedText = try XCTUnwrap(model.errorMessage)
        model.errorMessage = reusedText
        model.newProjectChatFacade.dismissNewChat(requestID: sheet.id)
        XCTAssertEqual(model.errorMessage, reusedText, "A later writer owns even an identical error value")
    }

    func testOuterWidgetRoutingFailuresClearOnValidTargetWithoutClearingUnrelatedSameText() async throws {
        for failure in ["project", "missing-server", "profile"] {
            for replaceError in [false, true] {
                let (model, _) = makeModel()
                defer { model.disconnect() }
                let invalidURL = try link(model, project: failure == "project" ? "missing-project" : "home-project",
                    profile: failure == "profile" ? .legacy : .v2,
                    server: failure == "missing-server" ? "unknown-server" : nil)
                await model.handleOpenURL(invalidURL)
                XCTAssertNil(model.newProjectChatSheetRequest)
                let originalError = try XCTUnwrap(model.errorMessage)
                if replaceError { model.errorMessage = originalError }
                await model.handleOpenURL(try link(model))
                let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
                XCTAssertTrue(model.newProjectChatFacade.isReady(for: sheet))
                XCTAssertEqual(model.errorMessage, replaceError ? originalError : nil, failure)
                model.newProjectChatFacade.dismissNewChat(requestID: sheet.id)
                XCTAssertEqual(model.errorMessage, replaceError ? originalError : nil, failure)
            }
        }
    }

    func testGlobalExecutionUsesCanonicalDefaultAndStaleCatalogBlocksSheetSubmission() async throws {
        let (model, services) = makeModel()
        defer { model.disconnect() }
        await model.handleOpenURL(try link(model, project: "global", directory: nil))
        let sheet = try XCTUnwrap(model.newProjectChatSheetRequest)
        XCTAssertEqual(sheet.workspaceDirectory, "/execution-default")
        services.defaultDirectory = "/changed"
        let accepted = await model.newProjectChatFacade.startNewChat(title: "", prompt: "test", agentMentions: [],
            attachments: [], messageID: "id", partID: "part", composerSelection: .init(agentName: nil, modelReference: nil, reasoningVariant: nil),
            projectID: "global", workspaceDirectory: sheet.workspaceDirectory, workspaceSelection: .main,
            newWorkspaceName: "", request: sheet)
        XCTAssertFalse(accepted)
        XCTAssertTrue(services.creations.isEmpty)
    }

    private func makeModel() -> (AppViewModel, WidgetActionServices) {
        let services = WidgetActionServices()
        let model = AppViewModel(backendFactory: services.backend)
        model.config = .init(baseURL: "https://widget-\(UUID().uuidString).invalid", password: "test", apiPreference: .automatic)
        model.recentServerConfigs = [model.config]
        model.automaticConnectionRetryEnabled = false
        model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        model.backendConnection = services.connection()
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free), usageStore: ShareQuotaUsageStore())
        return (model, services)
    }

    private func link(_ model: AppViewModel, action: Bool = false, project: String = "home-project", directory: String? = "/home-project",
                      profile: OpenCodeProfileIdentity = .v2, server: String? = nil, command: String = "test") throws -> URL {
        try XCTUnwrap(action ? OpenCodeWidgetDeepLink.actionURL(serverID: server ?? model.config.recentServerID,
            projectID: project, directory: directory, commandName: command, providerID: nil, modelID: nil, reasoningVariant: nil, profile: profile)
            : OpenCodeWidgetDeepLink.newSessionURL(serverID: server ?? model.config.recentServerID, projectID: project, directory: directory,
                providerID: nil, modelID: nil, reasoningVariant: nil, profile: profile))
    }

    private func submit(_ model: AppViewModel, sheet: NewProjectChatSheetRequest, text: String = "Original", id: String = "input") async -> Bool {
        await model.newProjectChatFacade.startNewChat(title: "", prompt: text, agentMentions: [], attachments: [],
            messageID: id, partID: id + "-part", composerSelection: .init(agentName: nil, modelReference: nil, reasoningVariant: nil),
            projectID: "home-project", workspaceDirectory: "/home-project", workspaceSelection: .main, newWorkspaceName: "", request: sheet)
    }
}

@MainActor
private final class WidgetActionServices: BackendProjectsService, BackendSessionsService, BackendCommandsService, BackendChatService {
    let backend: HomeTestBackend
    let actionContractID = "widget-test"
    var creations: [BackendSessionCreation] = []
    var commands: [BackendCommandSubmission] = []
    var receipt: ((BackendCommandSubmission) -> BackendAdmission)?
    var beforeCommand: (() async -> Void)?
    var beforePrompt: ((BackendSubmission) async -> Void)?
    var beforeCompletion: (() async -> Void)?
    var sessionDirectoryOverride: String?
    var losesCreateReceipt = false
    var completionReads = 0
    var turn: BackendActionTurn?
    var defaultDirectory: String? = "/execution-default"
    init(backend: HomeTestBackend? = nil) { self.backend = backend ?? HomeTestBackend() }
    func connection() -> BackendConnection {
        BackendConnection(descriptor: .init(id: "widget-test", name: "Widget", version: "2"),
            projects: self, sessions: self, chat: self, models: backend, events: backend,
            commands: self, sessionSelection: ShareSelectionService())
    }
    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        var snapshot = try await backend.projectsSnapshot()
        snapshot.defaultDirectory = defaultDirectory
        return snapshot
    }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        creations.append(request)
        let session = try await backend.createSession(request)
        if losesCreateReceipt { throw URLError(.timedOut) }
        return session
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        try await backend.sessions(scope: scope, cursor: cursor, limit: limit, roots: roots)
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        let session = try await backend.session(id: id, scope: scope)
        guard let directory = sessionDirectoryOverride else { return session }
        return .init(id: session.id, title: session.title, workspaceID: session.workspaceID,
            directory: directory, projectID: session.projectID, parentID: session.parentID)
    }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        try await backend.transcript(sessionID: sessionID, scope: scope, cursor: cursor, limit: limit)
    }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        await beforePrompt?(request)
        return try await backend.submit(request)
    }
    func interrupt(sessionID: String, scope: BackendScope) async throws { try await backend.interrupt(sessionID: sessionID, scope: scope) }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession {
        try await backend.renameSession(id: id, title: title, scope: scope)
    }
    func deleteSession(id: String, scope: BackendScope) async throws { try await backend.deleteSession(id: id, scope: scope) }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] {
        try await backend.searchSessions(query: query, scope: scope, limit: limit)
    }
    func listCommands(scope: BackendScope) async throws -> [OpenCodeCommand] {
        [.init(name: "test", description: nil, agent: nil, model: nil, source: "project", template: "test", subtask: nil, hints: [])]
    }
    func submitCommand(_ request: BackendCommandSubmission) async throws -> BackendAdmission {
        commands.append(request)
        await beforeCommand?()
        return receipt?(request) ?? .accepted(sessionID: request.sessionID, messageID: request.messageID)
    }
    func waitUntilIdle(sessionID: String, scope: BackendScope) async throws { completionReads += 1 }
    func completedTurn(sessionID: String, userMessageID: String, scope: BackendScope) async throws -> BackendActionTurn? {
        completionReads += 1
        await beforeCompletion?()
        return turn
    }
    func needsAttention(sessionID: String, scope: BackendScope) async throws -> Bool { false }
}

@MainActor
final class ShareDeepLinkTests: XCTestCase {
    func testWarmV2ShareIsAcceptedAndConsumedOnceWithoutReplacingPreview() async throws {
        let payload = try savedPayload()
        defer { _ = try? OpenClientSharePayloadStore.load(id: payload.id) }
        let url = try shareURL(payload)
        let viewModel = makeViewModel()
        viewModel.config.apiPreference = .v2
        viewModel.recentServerConfigs = [viewModel.config]
        viewModel.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        viewModel.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: viewModel.config),
            eventManager: viewModel.eventManager).makeConnection(profile: .v2, version: "2", healthy: true)
        defer { viewModel.disconnect() }
        viewModel.projects = [OpenCodeProject(
            id: "share-project", worktree: "/share-project", vcs: nil,
            name: "Share", sandboxes: nil, icon: nil, time: nil
        )]
        viewModel.prepareOpenURLPresentation(url)
        let preview = try XCTUnwrap(viewModel.newProjectChatSheetRequest)
        XCTAssertFalse(viewModel.newProjectChatFacade.isReady(for: preview))
        await viewModel.handleOpenURL(url)

        let staged = try XCTUnwrap(viewModel.newProjectChatSheetRequest)
        XCTAssertEqual(staged.id, preview.id)
        XCTAssertTrue(viewModel.newProjectChatFacade.isReady(for: staged))
        XCTAssertEqual(staged.initialContent?.text, payload.text)
        XCTAssertEqual(staged.initialContent?.attachments.count, 1)
        XCTAssertEqual(staged.initialContent?.attachments.first?.dataURL, payload.attachments.first?.dataURL)
        XCTAssertThrowsError(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false))

        viewModel.prepareOpenURLPresentation(url)
        await viewModel.handleOpenURL(url)
        XCTAssertEqual(viewModel.newProjectChatSheetRequest?.id, staged.id)
        XCTAssertEqual(viewModel.newProjectChatSheetRequest?.initialContent, staged.initialContent)
        viewModel.dismissNewProjectChatSheet()
        await viewModel.handleOpenURL(url)
        XCTAssertNil(viewModel.newProjectChatSheetRequest)
    }

    func testSharePreviewDoesNotConsumePayloadWhenConnectionFails() async throws {
        let payload = try savedPayload()
        defer { _ = try? OpenClientSharePayloadStore.load(id: payload.id) }
        let url = try shareURL(payload)
        let viewModel = makeViewModel()
        viewModel.hasSavedServer = true
        viewModel.localCacheRepository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        _ = URLProtocol.registerClass(ShareFailureURLProtocol.self)
        defer { URLProtocol.unregisterClass(ShareFailureURLProtocol.self) }

        viewModel.prepareOpenURLPresentation(url)
        let previewID = try XCTUnwrap(viewModel.newProjectChatSheetRequest?.id)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)

        await viewModel.handleOpenURL(url)

        XCTAssertFalse(viewModel.isConnected)
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(viewModel.newProjectChatSheetRequest?.id, previewID)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
    }

    func testUnknownRequestedServerDoesNotConsumeShareOnAnotherConnectedServer() async throws {
        let payload = try savedPayload()
        defer { _ = try? OpenClientSharePayloadStore.load(id: payload.id) }
        let url = try shareURL(payload, serverID: "missing-server")
        let viewModel = makeViewModel()
        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)

        await viewModel.handleOpenURL(url)

        XCTAssertFalse(viewModel.newProjectChatFacade.isReady(for: try XCTUnwrap(viewModel.newProjectChatSheetRequest)))
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
    }

    func testProjectRefreshFailureDoesNotConsumeShare() async throws {
        let payload = try savedPayload()
        defer { _ = try? OpenClientSharePayloadStore.load(id: payload.id) }
        let viewModel = makeViewModel()
        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        viewModel.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: viewModel.config),
            eventManager: viewModel.eventManager).makeConnection(profile: .legacy, version: "1", healthy: true)
        defer { viewModel.disconnect() }
        viewModel.projects = []
        _ = URLProtocol.registerClass(ShareFailureURLProtocol.self)
        defer { URLProtocol.unregisterClass(ShareFailureURLProtocol.self) }

        await viewModel.handleOpenURL(try shareURL(payload))

        XCTAssertFalse(viewModel.newProjectChatFacade.isReady(for: try XCTUnwrap(viewModel.newProjectChatSheetRequest)))
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
    }

    private func makeViewModel() -> AppViewModel {
        let viewModel = AppViewModel()
        viewModel.config = OpenCodeServerConfig(baseURL: "https://share-safety.invalid", password: "share-test")
        viewModel.recentServerConfigs = [viewModel.config]
        viewModel.hasSavedServer = false
        viewModel.automaticConnectionRetryEnabled = false
        return viewModel
    }

    private func savedPayload() throws -> OpenClientSharePayload {
        let payload = OpenClientSharePayload(
            id: UUID().uuidString,
            serverID: nil,
            text: "Keep this shared draft",
            attachments: [OpenClientShareAttachment(
                filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,bm90ZQ=="
            )]
        )
        try OpenClientSharePayloadStore.save(payload)
        return payload
    }

    private func shareURL(_ payload: OpenClientSharePayload, serverID: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = "openclient"
        components.host = "share"
        components.queryItems = [URLQueryItem(name: "id", value: payload.id)]
        if let serverID {
            components.queryItems?.append(URLQueryItem(name: "server", value: serverID))
        }
        return try XCTUnwrap(components.url)
    }
}

@MainActor
final class NewShareHandoffTests: XCTestCase {
    func testColdRoutingPreservesSavedPreferenceAndDeduplicatesConcurrentDelivery() async throws {
        for preference in [OpenCodeAPIPreference.v2, .automatic] {
            let factory = ShareHandoffFactory()
            let model = AppViewModel(backendFactory: factory)
            let saved = OpenCodeServerConfig(baseURL: "https://\(UUID().uuidString).invalid", password: "saved", apiPreference: preference)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ShareV2ReadFailureURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let adapter = OpenCodeBackendAdapter(client: .init(config: saved, session: session), profile: .v2)
            factory.preparedConnection = BackendConnection(descriptor: .init(id: "cold-v2", name: "Share", version: "2"),
                capabilities: [.interactions], projects: adapter, sessions: factory.backend, chat: factory.backend,
                models: factory.backend, events: factory.backend)
            model.config = OpenCodeServerConfig(baseURL: saved.baseURL, password: "stale", apiPreference: .legacy)
            model.recentServerConfigs = [saved]
            let payload = try makePayload(serverID: saved.recentServerID)
            defer { cleanUp(model, payload) }
            let url = try url(payload)
            let began = expectation(description: "Connection suspended")
            var release: CheckedContinuation<Void, Never>?
            factory.beforeConnect = {
                XCTAssertEqual(model.config, saved)
                await withCheckedContinuation { continuation in
                    release = continuation
                    began.fulfill()
                }
            }
            model.prepareOpenURLPresentation(url)
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            XCTAssertFalse(model.newProjectChatFacade.isReady(for: request))
            let route = Task { await model.handleOpenURL(url) }
            await fulfillment(of: [began], timeout: 1)
            model.prepareOpenURLPresentation(url)
            await model.handleOpenURL(url)
            XCTAssertEqual(factory.connections, 1)
            XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
            XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
            release?.resume()
            await route.value
            factory.beforeConnect = nil
            XCTAssertEqual(model.config.apiPreference, preference)
            XCTAssertEqual(model.connectionStore.apiProfile, .v2)
            XCTAssertTrue(model.newProjectChatFacade.isReady(for: request))
            XCTAssertTrue(factory.backend.submissions.isEmpty)
            XCTAssertThrowsError(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false))
        }
    }

    func testWarmAutomaticV2AndIntentionalEmptyCredentialRemainAuthoritative() async throws {
        let model = AppViewModel()
        model.config = .init(baseURL: "https://\(UUID().uuidString).invalid", username: "", password: "", apiPreference: .automatic)
        model.passwordStore.savePassword("", for: model.config.recentServerID)
        model.recentServerConfigs = [model.config]
        model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        model.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: model.config),
            eventManager: model.eventManager).makeConnection(profile: .v2, version: "2", healthy: true)
        let connectionID = model.backendConnection?.id
        model.projects = [project]
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        XCTAssertTrue(model.newProjectChatFacade.isReady(for: request))
        XCTAssertEqual(model.backendConnection?.id, connectionID)
        XCTAssertEqual(model.config.apiPreference, .automatic)
        XCTAssertEqual(model.config.password, "")
        model.passwordStore.deletePassword(for: model.config.recentServerID)
        XCTAssertFalse(model.newProjectChatFacade.isReady(for: request), "Missing credentials must not be treated as intentional no-auth")
    }

    func testColdIntentionalNoAuthConnectsButMissingKeychainDoesNot() async throws {
        for hasCredential in [false, true] {
            let factory = ShareHandoffFactory()
            let model = AppViewModel(backendFactory: factory)
            model.config = .init(baseURL: "https://\(UUID().uuidString).invalid", username: "", apiPreference: .automatic)
            model.recentServerConfigs = [model.config]
            if hasCredential { model.passwordStore.savePassword("", for: model.config.recentServerID) }
            let payload = try makePayload(serverID: model.config.recentServerID)
            defer { cleanUp(model, payload) }
            await model.handleOpenURL(try url(payload))
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            XCTAssertEqual(factory.connections, hasCredential ? 1 : 0)
            XCTAssertEqual(model.newProjectChatFacade.isReady(for: request), hasCredential)
            if !hasCredential {
                XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
            }
        }
    }

    func testExplicitPayloadServerMismatchCannotSendOnConnectedServer() async throws {
        let (model, backend) = await warmModel()
        let original = model.config
        let payload = try makePayload(serverID: "another-server")
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload, serverID: original.recentServerID))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        XCTAssertFalse(model.newProjectChatFacade.isReady(for: request))
        let sent = await submit(model, request: request)
        XCTAssertFalse(sent)
        XCTAssertEqual(model.config, original)
        XCTAssertTrue(backend.submissions.isEmpty)
        XCTAssertEqual(backend.storedSessions.count, 1)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
    }

    func testPreviewCannotManuallySendBeforeDestinationValidation() async throws {
        let (model, backend) = await warmModel()
        let payload = try makePayload(serverID: "unknown-server")
        defer { cleanUp(model, payload) }
        model.prepareOpenURLPresentation(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        let sent = await submit(model, request: request)
        XCTAssertFalse(sent)
        XCTAssertTrue(backend.submissions.isEmpty)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
    }

    func testUnknownSavedServerCanBeRetriedWithoutReplacingEditedPreview() async throws {
        let (model, _) = await warmModel()
        let saved = model.config
        let payload = try makePayload(serverID: saved.recentServerID)
        defer { cleanUp(model, payload) }
        model.recentServerConfigs = []
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        XCTAssertFalse(model.newProjectChatFacade.isReady(for: request))
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
        model.recentServerConfigs = [saved]
        await model.newProjectChatFacade.retryShare(request)
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
        XCTAssertTrue(model.newProjectChatFacade.isReady(for: request))
        XCTAssertEqual(model.newProjectChatSheetRequest?.initialContent, request.initialContent)
    }

    func testRevalidatingShareClearsMirroredRoutingErrorWithoutReplacingSheet() async throws {
        for usesRetryButton in [false, true] {
            let (model, backend) = await warmModel(selection: ShareSelectionService(), v2: true)
            let payload = try makePayload(serverID: model.config.recentServerID)
            defer { cleanUp(model, payload) }
            let validURL = try url(payload, serverID: model.config.recentServerID)
            await model.handleOpenURL(validURL)
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            let connectionID = model.backendConnection?.id
            XCTAssertTrue(model.newProjectChatFacade.isReady(for: request))
            XCTAssertThrowsError(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false))

            let conflictingURL = try url(payload, serverID: "missing-server")
            model.prepareOpenURLPresentation(conflictingURL)
            await model.handleOpenURL(conflictingURL)
            let mismatch = try XCTUnwrap(model.newProjectChatFacade.shareError(for: request))
            XCTAssertEqual(model.errorMessage, mismatch)
            XCTAssertFalse(model.newProjectChatFacade.isReady(for: request))

            if usesRetryButton {
                await model.newProjectChatFacade.retryShare(request)
            } else {
                model.prepareOpenURLPresentation(validURL)
                await model.handleOpenURL(validURL)
            }
            XCTAssertTrue(model.newProjectChatFacade.isReady(for: request))
            XCTAssertNil(model.newProjectChatFacade.shareError(for: request))
            XCTAssertNil(model.errorMessage, "The session list must not retain the handoff's resolved error")
            XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
            XCTAssertEqual(model.newProjectChatSheetRequest?.initialContent, request.initialContent)
            XCTAssertEqual(model.backendConnection?.id, connectionID)
            XCTAssertTrue(backend.submissions.isEmpty)
            XCTAssertEqual(backend.storedSessions.count, 1)
            model.newProjectChatFacade.dismissNewChat(requestID: request.id)
            XCTAssertNil(model.errorMessage)
        }
    }

    func testShareRevalidationPreservesAnUnrelatedAppError() async throws {
        let (model, backend) = await warmModel()
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        let validURL = try url(payload, serverID: model.config.recentServerID)
        await model.handleOpenURL(validURL)
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        await model.handleOpenURL(try url(payload, serverID: "missing-server"))
        XCTAssertNotNil(model.newProjectChatFacade.shareError(for: request))
        model.errorMessage = "Unrelated backend error"

        await model.handleOpenURL(validURL)

        XCTAssertTrue(model.newProjectChatFacade.isReady(for: request))
        XCTAssertNil(model.newProjectChatFacade.shareError(for: request))
        XCTAssertEqual(model.errorMessage, "Unrelated backend error")
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testCancelWhileConnectingPreservesPayloadAndDoesNotReopenSheet() async throws {
        let factory = ShareHandoffFactory()
        let model = AppViewModel(backendFactory: factory)
        model.config = .init(baseURL: "https://\(UUID().uuidString).invalid", password: "saved", apiPreference: .v2)
        model.recentServerConfigs = [model.config]
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        let began = expectation(description: "Connecting")
        var release: CheckedContinuation<Void, Never>?
        factory.beforeConnect = {
            await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
        }
        let route = Task { await model.handleOpenURL(try url(payload)) }
        await fulfillment(of: [began], timeout: 1)
        model.dismissNewProjectChatSheet()
        release?.resume()
        try await route.value
        factory.beforeConnect = nil
        XCTAssertNil(model.newProjectChatSheetRequest)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false), payload)
        await model.handleOpenURL(try url(payload))
        XCTAssertNil(model.newProjectChatSheetRequest)
        XCTAssertTrue(factory.backend.submissions.isEmpty)
    }

    func testUncertainFirstSendReusesCreatedSessionAndOriginalMessageIdentity() async throws {
        let (model, backend) = await warmModel()
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        backend.admissionResult = { .uncertain(sessionID: $0.sessionID, messageID: $0.messageID) }
        let first = await submit(model, request: request, messageID: "original")
        let repeated = await submit(model, request: request, messageID: "new-ui-id")
        let edited = await submit(model, request: request, prompt: "Edited while uncertain", messageID: "edited-ui-id")
        XCTAssertFalse(first)
        XCTAssertFalse(repeated)
        XCTAssertFalse(edited)
        XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
        XCTAssertEqual(backend.submissions.map(\.messageID), ["original"])
        XCTAssertEqual(backend.submissions.first?.attachments, request.initialContent?.attachments)
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
        let submitted = try XCTUnwrap(backend.submissions.first)
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: submitted.text,
            messageID: submitted.messageID, sessionID: submitted.sessionID)
        XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: try XCTUnwrap(model.backendConnection?.id)))
        let confirmed = await submit(model, request: request, messageID: "still-not-another-post")
        XCTAssertTrue(confirmed)
        XCTAssertEqual(backend.submissions.count, 1)
        backend.admissionResult = nil
    }

    func testRejectedFirstSendCanSubmitEditedDraftInSameCreatedSession() async throws {
        let (model, backend) = await warmModel()
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        let first = await submit(model, request: request, messageID: "rejected")
        XCTAssertFalse(first)
        backend.admissionResult = nil
        let edited = await submit(model, request: request, prompt: "Edited draft", messageID: "edited")
        XCTAssertTrue(edited)
        XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
        XCTAssertEqual(backend.submissions.map(\.messageID), ["rejected", "edited"])
        XCTAssertEqual(backend.submissions.last?.text, "Edited draft")
        XCTAssertEqual(backend.submissions.last?.attachments, request.initialContent?.attachments)
    }

    func testV2TextAndImageSubmissionUsesCoreServicesAndRetainsIdentityWithoutTimelineReceipt() async throws {
        for outcome in ["uncertain", "accepted", "rejected"] {
            let backend = HomeTestBackend()
            let model = AppViewModel()
            model.config = .init(baseURL: "https://share-v2.invalid", username: UUID().uuidString,
                password: "saved", apiPreference: .v2)
            model.recentServerConfigs = [model.config]
            model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [ShareV2ReadFailureURLProtocol.self]
            let session = URLSession(configuration: configuration)
            defer { session.invalidateAndCancel() }
            let adapter = OpenCodeBackendAdapter(client: .init(config: model.config, session: session), profile: .v2)
            model.backendConnection = BackendConnection(descriptor: .init(id: "v2-share", name: "Share", version: "2"),
                capabilities: [.interactions], projects: adapter, sessions: backend, chat: backend, models: backend, events: backend)
            model.projects = [project]
            #if DEBUG
            model.commerceFacade.debugEntitlementOverride = .unlocked
            #endif
            let payload = try makePayload(serverID: model.config.recentServerID)
            defer { cleanUp(model, payload) }
            await model.handleOpenURL(try url(payload))
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            backend.admissionResult = { input in
                switch outcome {
                case "accepted": return .accepted(sessionID: input.sessionID, messageID: input.messageID)
                case "rejected": return .rejected(sessionID: input.sessionID, messageID: input.messageID)
                default: return .uncertain(sessionID: input.sessionID, messageID: input.messageID)
                }
            }
            let result = await submit(model, request: request, messageID: "v2-original")
            XCTAssertEqual(result, outcome == "accepted")
            if outcome == "rejected" { backend.admissionResult = nil }
            let repeated = await submit(model, request: request, messageID: "retry-ui-id")
            XCTAssertEqual(repeated, outcome != "uncertain")
            XCTAssertEqual(backend.submissions.map(\.messageID), outcome == "rejected" ? ["v2-original", "retry-ui-id"] : ["v2-original"])
            XCTAssertEqual(backend.submissions.first?.text, payload.text)
            XCTAssertEqual(backend.submissions.first?.attachments.first?.dataURL, payload.attachments.first?.dataURL)
            XCTAssertEqual(backend.submissions.first?.scope, .init(projectID: "home-project", directory: "/home-project"))
            XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
            backend.admissionResult = nil
        }
    }

    func testLateAcceptanceCannotDismissOrConsumeReplacementShare() async throws {
        let (model, backend) = await warmModel()
        let payload = try makePayload(serverID: model.config.recentServerID)
        let replacement = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload); _ = try? OpenClientSharePayloadStore.load(id: replacement.id) }
        await model.handleOpenURL(try url(payload))
        let oldRequest = try XCTUnwrap(model.newProjectChatSheetRequest)
        let replacementURL = try url(replacement)
        backend.admissionResult = { input in
            model.dismissNewProjectChatSheet()
            model.prepareOpenURLPresentation(replacementURL)
            return .accepted(sessionID: input.sessionID, messageID: input.messageID)
        }
        let result = await submit(model, request: oldRequest)
        XCTAssertFalse(result)
        model.newProjectChatFacade.dismissNewChat(requestID: oldRequest.id)
        XCTAssertEqual(model.newProjectChatSheetRequest?.sharePayloadID, replacement.id)
        XCTAssertEqual(try OpenClientSharePayloadStore.load(id: replacement.id, deletesAfterLoad: false), replacement)
        backend.admissionResult = nil
    }

    func testRejectedShareAppliesSessionSelectionsBeforeRetryPrompt() async throws {
        for v2 in [false, true] {
            let selection = ShareSelectionService()
            let (model, backend) = await warmModel(selection: selection, v2: v2)
            let payload = try makePayload(serverID: model.config.recentServerID)
            defer { cleanUp(model, payload) }
            await model.handleOpenURL(try url(payload))
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            backend.admissionResult = { input in
                selection.operations.append("prompt:\(input.messageID)")
                return .rejected(sessionID: input.sessionID, messageID: input.messageID)
            }
            let first = await submit(model, request: request, messageID: "original", selection: expensiveSelection)
            XCTAssertFalse(first)
            backend.admissionResult = { input in
                XCTAssertEqual(selection.operations, ["prompt:original", "agent:plan", "model:cheap:low"])
                XCTAssertEqual(input.agent, "plan")
                XCTAssertEqual(input.model, self.cheapSelection.modelReference)
                XCTAssertEqual(input.variant, "low")
                selection.operations.append("prompt:\(input.messageID)")
                return .accepted(sessionID: input.sessionID, messageID: input.messageID)
            }
            let retried = await submit(model, request: request, messageID: "retry", selection: cheapSelection)
            XCTAssertTrue(retried)
            XCTAssertEqual(selection.operations, ["prompt:original", "agent:plan", "model:cheap:low", "prompt:retry"])
            XCTAssertEqual(model.selectedSession?.agent, "plan")
            XCTAssertEqual(model.selectedSession?.model?.modelID, "cheap")
            XCTAssertEqual(model.selectedSession?.model?.variant, "low")
            XCTAssertTrue(selection.scopes.allSatisfy { $0 == .init(projectID: "home-project", directory: "/home-project") })
            XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
            backend.admissionResult = nil
        }
    }

    func testLostSelectionResponseBlocksPromptAndReassertsRevertedSelectionOnSameSession() async throws {
        for losesAgent in [true, false] {
            let selection = ShareSelectionService()
            let (model, backend) = await warmModel(selection: selection, v2: true)
            let usage = ShareQuotaUsageStore()
            model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free), usageStore: usage)
            let payload = try makePayload(serverID: model.config.recentServerID)
            defer { cleanUp(model, payload) }
            await model.handleOpenURL(try url(payload))
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
            _ = await submit(model, request: request, messageID: "original", selection: expensiveSelection)
            if losesAgent {
                selection.beforeAgent = { throw URLError(.timedOut) }
            } else {
                selection.beforeModel = { throw URLError(.timedOut) }
            }
            let failed = await submit(model, request: request, messageID: "retry", selection: cheapSelection)
            XCTAssertFalse(failed)
            XCTAssertEqual(backend.submissions.map(\.messageID), ["original"])
            XCTAssertNil(model.chatFacade.promptAdmissionPhase(messageID: "retry", sessionID: "created-home-session"),
                "A failed selection write is not an uncertain prompt POST")
            XCTAssertEqual(model.usageMeter.dailyPromptCount, 0, "Selection failure refunds the unspent prompt reservation")
            XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
            selection.beforeAgent = nil
            selection.beforeModel = nil
            selection.operations = []
            backend.admissionResult = { input in
                XCTAssertEqual(selection.operations, losesAgent ? ["agent:build"] : ["agent:build", "model:expensive:high"])
                return .accepted(sessionID: input.sessionID, messageID: input.messageID)
            }
            let recovered = await submit(model, request: request, messageID: "another-ui-id", selection: expensiveSelection)
            XCTAssertTrue(recovered)
            XCTAssertEqual(backend.submissions.map(\.messageID), ["original", "retry"])
            XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
            XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
            backend.admissionResult = nil
        }
    }

    func testSelectionChangesAwaitAcknowledgementAndRecheckConnectionBeforePrompt() async throws {
        let selection = ShareSelectionService()
        let (model, backend) = await warmModel(selection: selection, v2: true)
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        _ = await submit(model, request: request, selection: expensiveSelection)
        let began = expectation(description: "Selection write is awaiting acknowledgement")
        var release: CheckedContinuation<Void, Never>?
        selection.beforeModel = {
            await withCheckedContinuation { continuation in release = continuation; began.fulfill() }
        }
        let retry = Task { await submit(model, request: request, messageID: "retry", selection: cheapSelection) }
        await fulfillment(of: [began], timeout: 1)
        XCTAssertEqual(backend.submissions.count, 1)
        model.backendConnection?.close()
        release?.resume()
        let result = await retry.value
        XCTAssertFalse(result)
        XCTAssertEqual(backend.submissions.count, 1)
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
        selection.beforeModel = nil
        backend.admissionResult = nil
    }

    func testUnresolvedDefaultResetCannotSilentlyReusePreviousSelection() async throws {
        for clearsAgent in [true, false] {
            let selection = ShareSelectionService()
            let (model, backend) = await warmModel(selection: selection, v2: true)
            let payload = try makePayload(serverID: model.config.recentServerID)
            defer { cleanUp(model, payload) }
            await model.handleOpenURL(try url(payload))
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
            _ = await submit(model, request: request, selection: expensiveSelection)
            let unresolved = NewProjectChatComposerSelection(agentName: clearsAgent ? nil : "plan",
                modelReference: clearsAgent ? cheapSelection.modelReference : nil, reasoningVariant: nil)
            let result = await submit(model, request: request, messageID: "retry", selection: unresolved)
            XCTAssertFalse(result)
            XCTAssertTrue(selection.operations.isEmpty, "Validate both selections before making partial changes")
            XCTAssertEqual(backend.submissions.count, 1)
            XCTAssertNotNil(model.newProjectChatFacade.shareError(for: request))
            backend.admissionResult = nil
            let explicit = await submit(model, request: request, messageID: "explicit", selection: cheapSelection)
            XCTAssertTrue(explicit)
            XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
        }
    }

    func testVariantCanBeResetWithAnExplicitModelBeforeRetry() async throws {
        let selection = ShareSelectionService()
        let (model, backend) = await warmModel(selection: selection, v2: true)
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        _ = await submit(model, request: request, selection: expensiveSelection)
        backend.admissionResult = nil
        let reset = NewProjectChatComposerSelection(agentName: expensiveSelection.agentName,
            modelReference: expensiveSelection.modelReference, reasoningVariant: nil)
        let result = await submit(model, request: request, messageID: "retry", selection: reset)
        XCTAssertTrue(result)
        XCTAssertEqual(selection.operations, ["model:expensive:default"])
        XCTAssertNil(backend.submissions.last?.variant)
    }

    func testQuotaDenialKeepsEditedSharedSheetThroughPaywallDismissalAndRetry() async throws {
        for limit in [OpenClientPaywallReason.sessionLimit, .promptLimit] {
            let (model, backend) = await warmModel()
            let usage = ShareQuotaUsageStore()
            let store = CommerceStore(usageMeter: .init(promptDay: OpenClientUsageMeter.dayString(for: Date()),
                dailyPromptCount: limit == .promptLimit ? OpenClientCommerceLimits.dailyPromptLimit : 0,
                createdSessionCount: limit == .sessionLimit ? OpenClientCommerceLimits.freeSessionLimit : 0),
                debugEntitlementOverride: .free)
            model.commerceFacade = CommerceFacade(store: store, usageStore: usage)
            let payload = try makePayload(serverID: model.config.recentServerID)
            defer { cleanUp(model, payload) }
            await model.handleOpenURL(try url(payload))
            let request = try XCTUnwrap(model.newProjectChatSheetRequest)
            let draft = MessageComposerDraftStore()
            draft.text = limit == .promptLimit ? "" : "Edited shared text"
            let images = [editedImage]
            let denied = await submit(model, request: request, prompt: draft.text, attachments: images)
            XCTAssertFalse(denied)
            XCTAssertEqual(model.newProjectChatFacade.paywallReason, limit)
            XCTAssertFalse(model.newProjectChatFacade.shouldDismissForPaywall(request))
            let ordinary = NewProjectChatSheetRequest(projectID: nil, workspaceDirectory: nil,
                locksProject: false, composerSelection: nil)
            XCTAssertTrue(model.newProjectChatFacade.shouldDismissForPaywall(ordinary))
            XCTAssertTrue(model.newProjectChatFacade.ownsPaywallPresentation)
            XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
            XCTAssertEqual(backend.storedSessions.count, 1, "Quota denial must not create a session")
            XCTAssertTrue(backend.submissions.isEmpty)
            XCTAssertThrowsError(try OpenClientSharePayloadStore.load(id: payload.id, deletesAfterLoad: false))
            model.commerceFacade.dismissPaywall()
            XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
            XCTAssertTrue(model.newProjectChatFacade.isReady(for: request))
            model.commerceFacade.debugEntitlementOverride = .unlocked
            let sent = await submit(model, request: request, prompt: draft.text, attachments: images)
            XCTAssertTrue(sent)
            XCTAssertEqual(backend.submissions.last?.text, draft.text)
            XCTAssertEqual(backend.submissions.last?.attachments, images)
        }
    }

    func testPromptQuotaDenialAfterCreationPreservesCheckpointAndEditedImages() async throws {
        let (model, backend) = await warmModel()
        let usage = ShareQuotaUsageStore()
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free), usageStore: usage)
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        backend.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        _ = await submit(model, request: request, messageID: "original")
        model.commerceFacade.usageMeter.dailyPromptCount = OpenClientCommerceLimits.dailyPromptLimit
        let denied = await submit(model, request: request, prompt: "Edited retry", messageID: "retry", attachments: [editedImage])
        XCTAssertFalse(denied)
        XCTAssertEqual(model.commerceFacade.paywallReason, .promptLimit)
        XCTAssertFalse(model.newProjectChatFacade.shouldDismissForPaywall(request))
        XCTAssertEqual(backend.submissions.count, 1)
        model.commerceFacade.dismissPaywall()
        XCTAssertEqual(model.newProjectChatSheetRequest?.id, request.id)
        model.commerceFacade.usageMeter.dailyPromptCount = 0
        backend.admissionResult = nil
        let result = await submit(model, request: request, prompt: "Edited retry", messageID: "another-ui-id", attachments: [editedImage])
        XCTAssertTrue(result)
        XCTAssertEqual(backend.submissions.map(\.messageID), ["original", "retry"])
        XCTAssertEqual(backend.submissions.last?.text, "Edited retry")
        XCTAssertEqual(backend.submissions.last?.attachments, [editedImage])
        XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
    }

    func testSharedPaywallPresentationKeepsTheDraftViewMounted() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let sheet = try String(contentsOf: root.appendingPathComponent("OpenCodeIOSClient/Views/Projects/ProjectListView.swift"), encoding: .utf8)
        let shell = try String(contentsOf: root.appendingPathComponent("OpenCodeIOSClient/Views/Root/RootView.swift"), encoding: .utf8)
        XCTAssertTrue(sheet.contains("viewModel.shouldDismissForPaywall(request)"))
        XCTAssertTrue(sheet.contains("OpenClientPaywallView(commerce: viewModel.commerce, reason: reason)"))
        XCTAssertTrue(sheet.contains("if !hasAppliedInitialContent, let initialContent = request.initialContent"))
        XCTAssertTrue(shell.contains("shell.newProjectChat.ownsPaywallPresentation ? nil : shell.commerce.paywallReason"))
        XCTAssertTrue(sheet.contains("viewModel.isReady(for: request)"))
        XCTAssertTrue(sheet.contains("viewModel.connectionContextID == context, viewModel.isPresented(request)"))
    }

    func testConnectionReplacementDisablesAcceptedShareAndCannotCreateAnotherSession() async throws {
        let (model, backend) = await warmModel()
        let payload = try makePayload(serverID: model.config.recentServerID)
        defer { cleanUp(model, payload) }
        await model.handleOpenURL(try url(payload))
        let request = try XCTUnwrap(model.newProjectChatSheetRequest)
        backend.admissionResult = { .uncertain(sessionID: $0.sessionID, messageID: $0.messageID) }
        _ = await submit(model, request: request)
        model.backendConnection?.close()
        model.backendConnection = try await backend.connect()
        XCTAssertFalse(model.newProjectChatFacade.isReady(for: request))
        await model.newProjectChatFacade.retryShare(request)
        let retried = await submit(model, request: request)
        XCTAssertFalse(retried)
        XCTAssertEqual(backend.submissions.count, 1)
        XCTAssertEqual(backend.storedSessions.filter { $0.id == "created-home-session" }.count, 1)
        backend.admissionResult = nil
    }

    func testLegacyWidgetLinkCannotPresentComposerOnV2() async throws {
        let (model, backend) = await warmModel()
        defer { model.disconnect() }
        model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        let url = try XCTUnwrap(OpenCodeWidgetDeepLink.newSessionURL(serverID: model.config.recentServerID,
            projectID: "home-project", directory: "/home-project", providerID: nil, modelID: nil, reasoningVariant: nil))
        model.prepareOpenURLPresentation(url)
        await model.handleOpenURL(url)
        XCTAssertNil(model.newProjectChatSheetRequest)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testSessionCreatedCallbackStillPrecedesPromptAcceptance() async throws {
        let (model, backend) = await warmModel()
        defer { model.disconnect() }
        var callbacks: [String] = []
        backend.admissionResult = { input in
            XCTAssertEqual(callbacks, ["created"])
            return .accepted(sessionID: input.sessionID, messageID: input.messageID)
        }
        let accepted = await model.startNewProjectChat(prompt: "Talk", messageID: "talk-input", projectID: "home-project",
            onSessionCreated: { _ in callbacks.append("created") },
            onPromptAccepted: { session, messageID, scope in
                XCTAssertEqual(session.id, "created-home-session")
                XCTAssertEqual(messageID, "talk-input")
                XCTAssertEqual(scope, .init(projectID: "home-project", directory: "/home-project"))
                callbacks.append("accepted")
            })
        XCTAssertTrue(accepted)
        XCTAssertEqual(callbacks, ["created", "accepted"])
        backend.admissionResult = nil
    }

    private var project: OpenCodeProject {
        .init(id: "home-project", worktree: "/home-project", vcs: nil, name: "Home", sandboxes: nil, icon: nil, time: nil)
    }

    private func warmModel(selection: (any BackendSessionSelectionService)? = nil, v2: Bool = false) async -> (AppViewModel, HomeTestBackend) {
        let backend = HomeTestBackend()
        let model = AppViewModel(backendFactory: backend)
        model.config = .init(baseURL: "https://\(UUID().uuidString).invalid", password: "saved")
        model.recentServerConfigs = [model.config]
        model.automaticConnectionRetryEnabled = false
        #if DEBUG
        model.commerceFacade.debugEntitlementOverride = .unlocked
        #endif
        await model.connectionFacade.connect()
        if selection != nil {
            model.backendConnection?.close()
            let projects: any BackendProjectsService
            if v2 {
                model.config.apiPreference = .v2
                model.recentServerConfigs = [model.config]
                model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
                let configuration = URLSessionConfiguration.ephemeral
                configuration.protocolClasses = [ShareV2ReadFailureURLProtocol.self]
                projects = OpenCodeBackendAdapter(client: .init(config: model.config, session: URLSession(configuration: configuration)), profile: .v2)
            } else {
                projects = backend
            }
            model.backendConnection = BackendConnection(descriptor: .init(id: "share-selection", name: "Share", version: "2"),
                capabilities: v2 ? [.interactions] : [], projects: projects, sessions: backend, chat: backend,
                models: backend, events: backend, sessionSelection: selection)
        }
        return (model, backend)
    }

    private var expensiveSelection: NewProjectChatComposerSelection {
        .init(agentName: "build", modelReference: .init(providerID: "test", modelID: "expensive"), reasoningVariant: "high")
    }

    private var cheapSelection: NewProjectChatComposerSelection {
        .init(agentName: "plan", modelReference: .init(providerID: "test", modelID: "cheap"), reasoningVariant: "low")
    }

    private var editedImage: OpenCodeComposerAttachment {
        .init(id: "edited-image", kind: .image, filename: "edited.png", mime: "image/png", dataURL: "data:image/png;base64,ZWRpdGVk")
    }

    private func makePayload(serverID: String) throws -> OpenClientSharePayload {
        let payload = OpenClientSharePayload(id: UUID().uuidString, serverID: serverID, text: "Shared image",
            attachments: [.init(filename: "image.png", mime: "image/png", dataURL: "data:image/png;base64,aW1hZ2U=")])
        try OpenClientSharePayloadStore.save(payload)
        return payload
    }

    private func url(_ payload: OpenClientSharePayload, serverID: String? = nil) throws -> URL {
        var components = URLComponents()
        components.scheme = "openclient"
        components.host = "share"
        components.queryItems = [.init(name: "id", value: payload.id)]
        if let serverID { components.queryItems?.append(.init(name: "server", value: serverID)) }
        return try XCTUnwrap(components.url)
    }

    private func submit(_ model: AppViewModel, request: NewProjectChatSheetRequest,
                        prompt: String? = nil, messageID: String = "share-message",
                        selection: NewProjectChatComposerSelection = .init(agentName: nil, modelReference: nil, reasoningVariant: nil),
                        attachments: [OpenCodeComposerAttachment]? = nil) async -> Bool {
        await model.newProjectChatFacade.startNewChat(title: "", prompt: prompt ?? request.initialContent?.text ?? "Shared",
            agentMentions: [], attachments: attachments ?? request.initialContent?.attachments ?? [], messageID: messageID, partID: "\(messageID)-part",
            composerSelection: selection, projectID: "home-project",
            workspaceDirectory: "/home-project", workspaceSelection: .main, newWorkspaceName: "", request: request)
    }

    private func cleanUp(_ model: AppViewModel, _ payload: OpenClientSharePayload) {
        model.passwordStore.deletePassword(for: payload.serverID ?? model.config.recentServerID)
        model.disconnect()
        _ = try? OpenClientSharePayloadStore.load(id: payload.id)
    }
}

@MainActor
private final class ShareSelectionService: BackendSessionSelectionService {
    var operations: [String] = []
    var scopes: [BackendScope] = []
    var beforeAgent: (@MainActor () async throws -> Void)?
    var beforeModel: (@MainActor () async throws -> Void)?

    func setAgent(sessionID: String, agent: String, scope: BackendScope) async throws {
        XCTAssertEqual(sessionID, "created-home-session")
        operations.append("agent:\(agent)")
        scopes.append(scope)
        try await beforeAgent?()
    }

    func setModel(sessionID: String, model: OpenCodeModelReference, variant: String?, scope: BackendScope) async throws {
        XCTAssertEqual(sessionID, "created-home-session")
        operations.append("model:\(model.modelID):\(variant ?? "default")")
        scopes.append(scope)
        try await beforeModel?()
    }
}

private final class ShareQuotaUsageStore: OpenClientUsagePersisting {
    var meter = OpenClientUsageMeter.empty
    func load() -> OpenClientUsageMeter { meter }
    func save(_ meter: OpenClientUsageMeter) { self.meter = meter }
}

@MainActor
private final class ShareHandoffFactory: BackendFactory {
    let backend = HomeTestBackend()
    var preparedConnection: BackendConnection?
    var beforeConnect: (@MainActor () async -> Void)?
    var connections = 0

    func connect() async throws -> BackendConnection {
        connections += 1
        await beforeConnect?()
        if let preparedConnection { return preparedConnection }
        return try await backend.connect()
    }
}

private final class ShareFailureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "share-safety.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }

    override func stopLoading() {}
}

private final class ShareV2ReadFailureURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let path = request.url?.path ?? ""
        // Creation and submission use the injected core services; provider/model reads are forbidden.
        XCTAssertTrue(path.hasPrefix("/api/session/") || path == "/api/location" || path == "/api/project"
            || path == "/api/health" || path == "/api/info" || path == "/api/form"
            || path == "/api/permission/request", "Unexpected v2 handoff read: \(path)")
        let body: String?
        switch path {
        case "/api/health":
            let response = HTTPURLResponse(url: request.url!, statusCode: 404, httpVersion: nil, headerFields: nil)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocolDidFinishLoading(self)
            return
        case "/api/info": body = #"{"version":"2.0.16","pid":1,"urls":[],"paths":{}}"#
        case "/api/location":
            body = #"{"directory":"/home-project","project":{"id":"home-project","directory":"/home-project","canonical":"/home-project"}}"#
        case "/api/project":
            body = #"[{"id":"home-project","canonical":"/home-project","sandboxes":[]}]"#
        case "/api/form": body = #"{"location":{"directory":"/home-project"},"data":[]}"#
        case "/api/permission/request": body = #"{"data":[]}"#
        case "/api/session/active": body = #"{"data":{}}"#
        default: body = path.hasSuffix("/permission") || path.hasSuffix("/form") ? #"{"data":[]}"# : nil
        }
        if let body {
            let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil,
                headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() {}
}
