import XCTest
@testable import OpenClient

@MainActor
final class LiveActivityStoreTests: XCTestCase {
    func testPermissionTransportBuildsProfileSpecificScopedRoutesAndBodies() throws {
        for profile in [OpenCodeProfileIdentity.legacy, .v2] {
            let client = OpenCodeLiveActivityActionClient(baseURL: "https://owner.invalid/prefix", username: "owner",
                credentialID: "raw-keychain-id", profile: profile, sessionID: "session")
            let request = try client.permissionRequest(requestID: "request", reply: "once", directory: "/work tree", workspaceID: "workspace", message: "Approved")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, profile == .legacy ? "/prefix/permission/request/reply" : "/prefix/api/session/session/permission/request/reply")
            let components = try XCTUnwrap(URLComponents(url: XCTUnwrap(request.url), resolvingAgainstBaseURL: false))
            XCTAssertEqual(components.queryItems, [.init(name: "directory", value: "/work tree"), .init(name: "workspace", value: "workspace")])
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/work%20tree")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(request.httpBody)) as? [String: String])
            XCTAssertEqual(body, ["reply": "once", "message": "Approved"])
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        }
    }

    func testV2RequiresSessionAndNeverUsesLegacyQuestionTransport() throws {
        var client = OpenCodeLiveActivityActionClient(baseURL: "https://owner.invalid", username: "owner",
            credentialID: "raw-id", profile: .v2)
        XCTAssertThrowsError(try client.permissionRequest(requestID: "r", reply: "once", directory: nil, workspaceID: nil))
        client.sessionID = "s/other?x=1"
        let request = try client.permissionRequest(requestID: "r/other", reply: "reject", directory: nil, workspaceID: nil)
        XCTAssertEqual(request.url?.absoluteString, "https://owner.invalid/api/session/s%2Fother%3Fx%3D1/permission/r%2Fother/reply")
        XCTAssertThrowsError(try client.questionRequest(requestID: "r", answers: [["Yes"]], directory: nil, workspaceID: nil))
        XCTAssertThrowsError(try client.permissionRequest(requestID: "r", reply: "allow", directory: nil, workspaceID: nil))
        client.profile = .legacy
        XCTAssertEqual(try client.questionRequest(requestID: "r", answers: [["Yes"]], directory: nil, workspaceID: nil).url?.path, "/question/r/reply")
    }

    func testPermissionSendUsesRawCredentialIDWithoutPersistentWrites() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityTransportProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel(); LiveActivityTransportProtocol.handler = nil }
        LiveActivityTransportProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/s/permission/r/reply")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + Data("owner:fixture-only".utf8).base64EncodedString())
        }
        let client = OpenCodeLiveActivityActionClient(baseURL: "https://owner.invalid", username: "owner", credentialID: "unchanged|raw-id",
            session: session, profile: .v2, sessionID: "s", loadPassword: { id in
                XCTAssertEqual(id, "unchanged|raw-id")
                return "fixture-only"
            })
        try await client.replyToPermission(requestID: "r", reply: "once", directory: nil, workspaceID: nil)
    }

    func testOwnerBindingInvalidatesTasksAndLateOperationsForEqualSessionIDs() {
        let store = LiveActivityStore()
        let original = LiveActivityStore.Lifetime(owner: .init(profile: .legacy, serverID: "server-a"), connectionID: UUID(), generation: 1)
        store.bind(original)
        let operation = store.beginOperation(sessionID: "same")
        let task = Task { }
        store.setRefreshTask(task, for: "same")
        store.insertActiveSessionID("same")
        store.activityIDsBySessionID["same"] = "os-a"
        let otherProfile = LiveActivityStore.Lifetime(owner: .init(profile: .v2, serverID: "server-a"), connectionID: UUID(), generation: 1)
        store.bind(otherProfile)
        XCTAssertTrue(task.isCancelled)
        XCTAssertTrue(store.activeSessionIDs.isEmpty)
        XCTAssertTrue(store.activityIDsBySessionID.isEmpty)
        XCTAssertFalse(store.owns(operation, sessionID: "same", lifetime: original))
        let next = store.beginOperation(sessionID: "same")
        store.bind(.init(owner: .init(profile: .v2, serverID: "server-b"), connectionID: UUID(), generation: 1))
        XCTAssertFalse(store.owns(next, sessionID: "same", lifetime: otherProfile))
    }

    func testRefreshTaskReplacementCancelsPreviousTask() {
        let store = LiveActivityStore()
        let firstTask = Task { }
        let secondTask = Task { }

        store.setRefreshTask(firstTask, for: "ses_1")
        store.setRefreshTask(secondTask, for: "ses_1")

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(secondTask.isCancelled)
        XCTAssertTrue(store.hasPendingRefresh(for: "ses_1"))
    }

    func testPreviewRefreshTaskReplacementCancelsPreviousTask() {
        let store = LiveActivityStore()
        let firstTask = Task { }
        let secondTask = Task { }

        store.setPreviewRefreshTask(firstTask, for: "ses_1")
        store.setPreviewRefreshTask(secondTask, for: "ses_1")

        XCTAssertTrue(firstTask.isCancelled)
        XCTAssertFalse(secondTask.isCancelled)
    }

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
    func testV2GlobalConcreteDirectoryRoutesColdAndWarm() async throws {
        for warm in [false, true] {
            let fixture = LiveActivityRestoreFixture()
            var attributes = fixture.records[0].attributes
            attributes.projectID = "global"
            attributes.directory = "/actual/workspace"
            attributes.workspaceID = "workspace"
            fixture.records = [.init(id: "restored-os-id", attributes: attributes, state: fixture.records[0].state)]
            fixture.backend.storedSessions = [.init(id: fixture.sessionID, title: "Global", workspaceID: "workspace",
                directory: "/actual/workspace", projectID: "global", parentID: nil)]
            if warm { fixture.install() }
            let url = try fixture.url()
            let link = try XCTUnwrap(LiveActivityCoordinator.deepLink(from: url))
            XCTAssertEqual(fixture.facade.restorationScope(for: link),
                .init(projectID: "global", directory: "/actual/workspace", workspaceID: "workspace"))
            await fixture.model.handleLiveActivityURL(url)
            XCTAssertEqual(fixture.navigations.count, 1)
            XCTAssertEqual(fixture.navigations.first?.directory, "/actual/workspace")
            XCTAssertEqual(fixture.connections.count, warm ? 0 : 1)
            XCTAssertEqual(fixture.canonicalReads, 1)
        }
    }

    func testGlobalOriginRejectsWrongCanonicalProjectWorkspaceAndDirectory() async throws {
        for mismatch in ["project", "workspace", "directory"] {
            let fixture = LiveActivityRestoreFixture()
            var attributes = fixture.records[0].attributes
            attributes.projectID = "global"
            attributes.directory = "/actual/workspace"
            attributes.workspaceID = "workspace"
            fixture.records = [.init(id: "restored-os-id", attributes: attributes, state: fixture.records[0].state)]
            fixture.backend.storedSessions = [.init(id: fixture.sessionID, title: "Wrong origin",
                workspaceID: mismatch == "workspace" ? "other" : "workspace",
                directory: mismatch == "directory" ? "/other" : "/actual/workspace",
                projectID: mismatch == "project" ? "other" : "global", parentID: nil)]
            await fixture.model.handleLiveActivityURL(try fixture.url())
            XCTAssertEqual(fixture.canonicalReads, 1)
            XCTAssertTrue(fixture.navigations.isEmpty, mismatch)
            XCTAssertNil(fixture.facade.pendingDeepLink)
        }
    }

    func testOldLegacyOmittedDirectoryAcceptsOnlyCanonicalGlobalProjectAndMatchingWorkspace() async throws {
        for variant in ["global", "nonglobal", "nonglobal-nil-directory", "wrong-workspace"] {
            let fixture = LiveActivityRestoreFixture(profile: .legacy, missingProfile: true)
            var attributes = fixture.records[0].attributes
            attributes.directory = nil
            attributes.projectID = nil
            let persisted = try JSONEncoder().encode(attributes)
            attributes = try JSONDecoder().decode(OpenCodeChatActivityAttributes.self, from: persisted)
            fixture.records = [.init(id: "restored-os-id", attributes: attributes, state: fixture.records[0].state)]
            fixture.backend.storedSessions = [.init(id: fixture.sessionID, title: "Canonical",
                workspaceID: variant == "wrong-workspace" ? "other" : nil,
                directory: variant == "nonglobal-nil-directory" ? nil : "/actual/workspace",
                projectID: variant.hasPrefix("nonglobal") ? "other" : "global", parentID: nil)]
            let url = try fixture.url()
            XCTAssertNil(fixture.facade.restorationScope(for: try XCTUnwrap(LiveActivityCoordinator.deepLink(from: url)))?.directory)
            await fixture.model.handleLiveActivityURL(url)
            XCTAssertEqual(fixture.canonicalReads, 1)
            XCTAssertEqual(fixture.navigations.count, variant == "global" ? 1 : 0, variant)
        }
    }

    func testStartPreservesGlobalOriginAndSeparatesLegacyRequestScope() async throws {
        for profile in [OpenCodeProfileIdentity.legacy, .v2] {
            let fixture = LiveActivityRestoreFixture(profile: profile)
            fixture.install()
            var requests: [LiveActivityStartRequest] = []
            let facade = LiveActivityFacade(viewModel: fixture.model, requestOrUpdate: { requests.append($0) }, activityRecords: { [] })
            await facade.start(session: .init(id: "global-session", title: "Global", workspaceID: nil,
                directory: "/actual/workspace", projectID: "global", parentID: nil))
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.directory, "/actual/workspace")
            XCTAssertEqual(request.projectID, "global")
            let attributes = OpenCodeChatActivityAttributes(sessionID: request.sessionID, sessionTitle: request.sessionTitle,
                credentialID: request.credentialID, serverBaseURL: request.serverBaseURL, serverUsername: request.serverUsername,
                directory: request.directory, workspaceID: request.workspaceID, profile: request.profile.rawValue, projectID: request.projectID)
            let restored = try JSONDecoder().decode(OpenCodeChatActivityAttributes.self, from: JSONEncoder().encode(attributes))
            XCTAssertEqual(restored.directory, "/actual/workspace")
            XCTAssertEqual(restored.projectID, "global")
            XCTAssertEqual(restored.requestDirectory, profile == .legacy ? nil : "/actual/workspace")
            let client = OpenCodeLiveActivityActionClient(baseURL: fixture.saved.baseURL, username: "owner",
                credentialID: fixture.saved.recentServerID, profile: profile, sessionID: request.sessionID)
            let reply = try client.permissionRequest(requestID: "permission", reply: "once", directory: restored.requestDirectory, workspaceID: nil)
            XCTAssertEqual(reply.value(forHTTPHeaderField: "x-opencode-directory"), profile == .legacy ? nil : "/actual/workspace")
        }
    }

    func testChatHeaderLiveActivityTargetsWindowBAndRejectsClosedContext() async throws {
        let fixture = LiveActivityRestoreFixture(profile: .legacy)
        fixture.install()
        let model = fixture.model
        let root = OpenCodeSession(id: "root-a", title: "Root A", workspaceID: nil, directory: "/root", projectID: "root", parentID: nil)
        model.selectedSession = root
        let session = OpenCodeSession(id: "window-b", title: "Window B", workspaceID: "b-workspace", directory: "/b", projectID: "b-project", parentID: nil)
        let owner = model.directoryStoreRegistry.store(for: "/b")
        owner.sessions = [session]
        let context = ChatWindowContext(model: model, connection: model.backendConnection!, session: session, owner: owner)
        let chat = ChatFacade(viewModel: model, windowContext: context)
        var requests: [LiveActivityStartRequest] = []
        var ended: [String] = []
        model.liveActivityFacade = LiveActivityFacade(viewModel: model, requestOrUpdate: { requests.append($0) },
            activityRecords: { [] }, endActivity: { identity, _, _, _ in ended.append(identity.sessionID) })
        let scope = chat.headerScope(for: session)
        XCTAssertTrue(chat.supportsHeaderLiveActivity(scope))
        await chat.toggleHeaderLiveActivity(scope)
        XCTAssertEqual(requests.map(\.sessionID), ["window-b"])
        XCTAssertEqual(requests.first?.directory, "/b")
        XCTAssertEqual(requests.first?.workspaceID, "b-workspace")
        XCTAssertTrue(chat.isHeaderLiveActivityActive(scope))
        await chat.toggleHeaderLiveActivity(scope)
        XCTAssertEqual(ended, ["window-b"])
        XCTAssertFalse(chat.isHeaderLiveActivityActive(scope))
        context.close()
        await chat.toggleHeaderLiveActivity(scope)
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(model.selectedSession?.id, "root-a")
    }

    func testColdRestoredTapConnectsExactSavedOwnerAndPreservesAutomaticPreference() async throws {
        for profile in [OpenCodeProfileIdentity.legacy, .v2] {
            let fixture = LiveActivityRestoreFixture(profile: profile, missingProfile: profile == .legacy)
            XCTAssertNil(fixture.facade.currentLifetime)
            let record = try XCTUnwrap(fixture.records.first)
            let persisted = try JSONEncoder().encode(record.attributes)
            let restored = try JSONDecoder().decode(OpenCodeChatActivityAttributes.self, from: persisted)
            if profile == .legacy {
                XCTAssertNil((try JSONSerialization.jsonObject(with: persisted) as? [String: Any])?["profile"])
                XCTAssertNil(restored.profile)
            }
            fixture.records = [.init(id: record.id, attributes: restored, state: record.state)]
            fixture.backend.storedSessions[0] = .init(id: fixture.sessionID, title: "Canonical title", workspaceID: nil,
                directory: "/home-project", projectID: "home-project", parentID: nil)
            await fixture.model.handleLiveActivityURL(try fixture.url())
            XCTAssertEqual(fixture.connections.map(\.recentServerID), [fixture.saved.recentServerID])
            XCTAssertEqual(fixture.connections.first?.apiPreference, .automatic)
            XCTAssertEqual(fixture.model.config.apiPreference, .automatic)
            XCTAssertEqual(fixture.canonicalReads, 1)
            XCTAssertEqual(fixture.navigations.map(\.title), ["Canonical title"])
            XCTAssertTrue(fixture.facade.isActive(sessionID: fixture.sessionID))
            XCTAssertEqual(fixture.model.liveActivityStore.activityIDsBySessionID[fixture.sessionID], "restored-os-id")
            XCTAssertNil(fixture.facade.pendingDeepLink)
            XCTAssertTrue(fixture.requests.isEmpty)
            XCTAssertTrue(fixture.ended.isEmpty)
        }
    }

    func testFacadeReconnectReconcilesFreshLifetimeThenUpdatesAndStopsOnlyOwnedOSID() async throws {
        for profile in [OpenCodeProfileIdentity.legacy, .v2] {
            let fixture = LiveActivityRestoreFixture(profile: profile)
            var foreign = fixture.records[0].attributes
            foreign.credentialID = fixture.foreign.recentServerID
            foreign.serverBaseURL = fixture.foreign.baseURL
            fixture.records.append(.init(id: "foreign-os-id", attributes: foreign, state: fixture.records[0].state))
            fixture.install()
            let original = try XCTUnwrap(fixture.facade.currentLifetime)
            fixture.install()
            let restored = try XCTUnwrap(fixture.facade.currentLifetime)
            XCTAssertEqual(original.owner, restored.owner)
            XCTAssertNotEqual(original.connectionID, restored.connectionID)
            XCTAssertNotEqual(original.generation, restored.generation)
            XCTAssertEqual(fixture.model.liveActivityStore.lifetime, restored)
            XCTAssertTrue(fixture.facade.isActive(sessionID: fixture.sessionID))
            XCTAssertTrue(fixture.ended.isEmpty)
            let updated = expectation(description: "Restored activity updated")
            fixture.didUpdate = { updated.fulfill() }
            fixture.facade.refresh(sessionID: fixture.sessionID, immediate: true)
            await fulfillment(of: [updated], timeout: 2)
            XCTAssertEqual(fixture.updated, ["restored-os-id"])
            await fixture.facade.stop(sessionID: fixture.sessionID, immediate: true)
            XCTAssertEqual(fixture.ended, ["restored-os-id"])
            XCTAssertEqual(fixture.records.map(\.id), ["foreign-os-id"])
            XCTAssertFalse(fixture.facade.isActive(sessionID: fixture.sessionID))
            XCTAssertTrue(fixture.requests.isEmpty)
        }
    }

    func testInProgressOwnerConnectionDefersAndDrainsRestoredLinkOnce() async throws {
        let fixture = LiveActivityRestoreFixture()
        fixture.model.config = fixture.saved
        fixture.model.connectionAttemptID = UUID()
        fixture.model.connectionStore.beginConnecting()
        await fixture.model.handleLiveActivityURL(try fixture.url())
        XCTAssertNotNil(fixture.facade.pendingDeepLink)
        XCTAssertTrue(fixture.connections.isEmpty)
        XCTAssertTrue(fixture.navigations.isEmpty)
        fixture.install()
        await fixture.facade.resumePendingDeepLink()
        await fixture.facade.resumePendingDeepLink()
        XCTAssertEqual(fixture.navigations.count, 1)
        XCTAssertEqual(fixture.canonicalReads, 1)
        XCTAssertNil(fixture.facade.pendingDeepLink)
    }

    func testForeignConnectionDoesNotGetReplacedAndClearsPendingOwnedLink() async throws {
        let fixture = LiveActivityRestoreFixture()
        fixture.model.config = fixture.foreign
        fixture.model.connectionAttemptID = UUID()
        fixture.model.connectionStore.beginConnecting()
        await fixture.model.handleLiveActivityURL(try fixture.url())
        XCTAssertNil(fixture.facade.pendingDeepLink)
        XCTAssertTrue(fixture.connections.isEmpty)
        fixture.model.config = fixture.saved
        await fixture.model.handleLiveActivityURL(try fixture.url())
        XCTAssertNotNil(fixture.facade.pendingDeepLink)
        fixture.install(config: fixture.foreign)
        await fixture.facade.resumePendingDeepLink()
        XCTAssertNil(fixture.facade.pendingDeepLink)
        XCTAssertTrue(fixture.navigations.isEmpty)
        XCTAssertFalse(fixture.facade.isActive(sessionID: fixture.sessionID))
        XCTAssertTrue(fixture.ended.isEmpty)
        XCTAssertEqual(fixture.records.count, 1)
    }

    func testConnectFailureCannotNavigateOrReadOrReplyFromRestoredPermissionLink() async throws {
        let fixture = LiveActivityRestoreFixture(backendFactory: LiveActivityFailingConnectionFactory())
        fixture.facade.connectForRestoration = { [weak fixture] saved in
            guard let fixture else { return }
            fixture.model.config = saved
            await fixture.model.connect()
        }
        await fixture.model.handleLiveActivityURL(try fixture.url(action: [
            .init(name: "action", value: "permission"), .init(name: "requestID", value: "permission"), .init(name: "reply", value: "once")
        ]))
        XCTAssertEqual(fixture.canonicalReads, 0)
        XCTAssertTrue(fixture.navigations.isEmpty)
        XCTAssertNil(fixture.facade.pendingDeepLink)
        XCTAssertTrue(fixture.ended.isEmpty)
        XCTAssertEqual(fixture.model.chatDetailPresentationRequest, 0)
    }

    func testAutomaticNegotiationCannotAdoptLegacyOSRecordAsV2() async throws {
        let fixture = LiveActivityRestoreFixture(profile: .v2, missingProfile: true)
        await fixture.model.handleLiveActivityURL(try fixture.url())
        XCTAssertEqual(fixture.connections.first?.apiPreference, .automatic)
        XCTAssertEqual(fixture.model.config.apiPreference, .automatic)
        XCTAssertEqual(fixture.canonicalReads, 0)
        XCTAssertTrue(fixture.navigations.isEmpty)
        XCTAssertFalse(fixture.facade.isActive(sessionID: fixture.sessionID))
        XCTAssertNil(fixture.facade.pendingDeepLink)
        XCTAssertTrue(fixture.ended.isEmpty)
    }

    func testCancellingConnectionDiscardsDeferredOwnedLink() async throws {
        let fixture = LiveActivityRestoreFixture()
        fixture.model.config = fixture.saved
        fixture.model.connectionAttemptID = UUID()
        fixture.model.connectionStore.beginConnecting()
        await fixture.model.handleLiveActivityURL(try fixture.url())
        XCTAssertNotNil(fixture.facade.pendingDeepLink)
        fixture.model.cancelConnectionAttempt()
        XCTAssertNil(fixture.facade.pendingDeepLink)
        fixture.install()
        await fixture.facade.resumePendingDeepLink()
        XCTAssertTrue(fixture.navigations.isEmpty)
        XCTAssertTrue(fixture.ended.isEmpty)
    }

    func testUnknownUnqualifiedAndUnsavedRestoredLinksNeverAutoconnect() async throws {
        let fixture = LiveActivityRestoreFixture()
        let qualified = try fixture.url()
        let unqualified = try XCTUnwrap(OpenCodeChatActivityDeepLink.openAppURL(sessionID: fixture.sessionID, directory: "/home-project"))
        await fixture.model.handleLiveActivityURL(unqualified)
        var attributes = fixture.records[0].attributes
        attributes.profile = "unknown"
        fixture.records = [.init(id: "restored-os-id", attributes: attributes, state: fixture.records[0].state)]
        await fixture.model.handleLiveActivityURL(qualified)
        attributes.profile = "v2"
        fixture.records = [.init(id: "restored-os-id", attributes: attributes, state: fixture.records[0].state)]
        fixture.model.recentServerConfigs = [fixture.foreign]
        await fixture.model.handleLiveActivityURL(qualified)
        XCTAssertTrue(fixture.connections.isEmpty)
        XCTAssertTrue(fixture.navigations.isEmpty)
        XCTAssertNil(fixture.facade.pendingDeepLink)
        XCTAssertEqual(fixture.canonicalReads, 0)
    }

    func testCanonicalReadCompletingAfterForeignConnectionCannotNavigateOrReply() async throws {
        let fixture = LiveActivityRestoreFixture()
        fixture.backend.beforeSessionFetch = { [weak fixture] in
            await Task.yield()
            guard let fixture else { return }
            fixture.install(config: fixture.foreign)
        }
        await fixture.model.handleLiveActivityURL(try fixture.url(action: [
            .init(name: "action", value: "permission"), .init(name: "requestID", value: "permission"), .init(name: "reply", value: "once")
        ]))
        XCTAssertTrue(fixture.navigations.isEmpty)
        XCTAssertNil(fixture.facade.pendingDeepLink)
        XCTAssertEqual(fixture.model.config, fixture.foreign)
        XCTAssertTrue(fixture.ended.isEmpty)
    }

    func testCanonicalSessionScopeMismatchDoesNotUseOSMetadataAsFallback() async throws {
        let fixture = LiveActivityRestoreFixture()
        fixture.backend.storedSessions[0] = .init(id: fixture.sessionID, title: "Moved", workspaceID: nil,
            directory: "/different-directory", projectID: "home-project", parentID: nil)
        await fixture.model.handleLiveActivityURL(try fixture.url())
        XCTAssertEqual(fixture.canonicalReads, 1)
        XCTAssertTrue(fixture.navigations.isEmpty)
        XCTAssertNil(fixture.model.selectedSession)
        XCTAssertNil(fixture.facade.pendingDeepLink)
    }

    func testLateRequestSuccessAndFailureCannotPublishIntoReconnectedSameOwner() async {
        for shouldFail in [false, true] {
            let backend = HomeTestBackend()
            let viewModel = AppViewModel()
            let config = OpenCodeServerConfig(baseURL: "https://owner.invalid")
            let adapter = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: config), profile: .legacy)
            func connection() -> BackendConnection {
                BackendConnection(descriptor: .init(id: "owner", name: "Owner", version: "1"), capabilities: [.liveActivities],
                    projects: adapter, sessions: backend, chat: backend, models: backend, events: backend)
            }
            let original = connection()
            let replacement = connection()
            viewModel.backendConnection = original
            let facade = LiveActivityFacade(viewModel: viewModel, requestOrUpdate: { _ in
                await Task.yield()
                original.close()
                viewModel.backendConnection = replacement
                viewModel.errorMessage = "New connection error"
                if shouldFail { throw URLError(.cancelled) }
            })
            await facade.start(session: backend.storedSessions[0])
            XCTAssertEqual(viewModel.errorMessage, "New connection error")
            XCTAssertTrue(facade.activeSessionIDs.isEmpty)
            XCTAssertTrue(viewModel.liveActivityStore.activeSessionIDs.isEmpty)
            XCTAssertNil(viewModel.liveActivityStore.lastState(for: backend.storedSessions[0].id))
        }
    }

    func testPersistedPreProfileAttributesDecodeAsLegacyAndUnknownProfileFailsClosed() throws {
        let old = Data(#"{"sessionID":"same","sessionTitle":"Old activity","credentialID":"raw-keychain-id","serverBaseURL":"https://old.invalid","serverUsername":"opencode"}"#.utf8)
        let attributes = try JSONDecoder().decode(OpenCodeChatActivityAttributes.self, from: old)
        XCTAssertNil(attributes.profile)
        XCTAssertEqual(attributes.identity?.owner.profile, .legacy)
        XCTAssertEqual(attributes.identity?.owner.serverID, "raw-keychain-id")
        XCTAssertNil(attributes.workspaceID)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: old) as? [String: Any])
        object["profile"] = "future-profile"
        let unknown = try JSONDecoder().decode(OpenCodeChatActivityAttributes.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(unknown.identity)
        XCTAssertFalse(unknown.matches(.init(owner: .init(profile: .legacy, serverID: "raw-keychain-id"), sessionID: "same"), actualActivityID: "os-1"))
    }

    func testActivityMatchingQualifiesProfileServerSessionAndOSID() {
        let attributes = OpenCodeChatActivityAttributes(sessionID: "same", sessionTitle: "Activity", credentialID: "server-a",
            serverBaseURL: "https://a.invalid", serverUsername: "opencode", directory: nil, workspaceID: nil, profile: "v2")
        let identity = OpenCodeLiveActivityOwner(profile: .v2, serverID: "server-a").session("same")
        XCTAssertTrue(attributes.matches(identity, activityID: "os-a", actualActivityID: "os-a"))
        XCTAssertFalse(attributes.matches(identity, activityID: "os-b", actualActivityID: "os-a"))
        XCTAssertFalse(attributes.matches(.init(owner: .init(profile: .legacy, serverID: "server-a"), sessionID: "same"), actualActivityID: "os-a"))
        XCTAssertFalse(attributes.matches(.init(owner: .init(profile: .v2, serverID: "server-b"), sessionID: "same"), actualActivityID: "os-a"))
        XCTAssertFalse(attributes.matches(identity.owner.session("other"), actualActivityID: "os-a"))
    }

    func testReconcileUsesQualifiedOSRecordsAndDropsStaleMembership() {
        let store = LiveActivityStore()
        let lifetime = LiveActivityStore.Lifetime(owner: .init(profile: .v2, serverID: "server-a"), connectionID: UUID(), generation: 1)
        let state = OpenCodeChatActivityAttributes.ContentState(status: "Live", latestSnippet: "Current", transcriptLines: [], updatedAt: .now,
            pendingInteractionKind: nil, interactionID: nil, interactionTitle: nil, interactionSummary: nil,
            questionOptionLabels: [], canReplyToQuestionInline: false)
        let current = OpenCodeChatActivityAttributes(sessionID: "same", sessionTitle: "Activity", credentialID: "server-a",
            serverBaseURL: "https://a.invalid", serverUsername: "opencode", directory: nil, workspaceID: nil, profile: "v2")
        var old = current
        old.profile = nil
        var foreign = current
        foreign.credentialID = "server-b"
        var unknown = current
        unknown.profile = "future"
        store.reconcile([("old", old, state), ("current", current, state), ("foreign", foreign, state), ("unknown", unknown, state)], lifetime: lifetime)
        XCTAssertEqual(store.activeSessionIDs, ["same"])
        XCTAssertEqual(store.activityIDsBySessionID, ["same": "current"])
        XCTAssertEqual(store.lastState(for: "same"), state)
        store.reconcile([], lifetime: lifetime)
        XCTAssertTrue(store.activeSessionIDs.isEmpty)
        XCTAssertTrue(store.activityIDsBySessionID.isEmpty)
        XCTAssertNil(store.lastState(for: "same"))
        let legacyLifetime = LiveActivityStore.Lifetime(owner: .init(profile: .legacy, serverID: "server-a"), connectionID: UUID(), generation: 2)
        store.reconcile([("old", old, state), ("current", current, state)], lifetime: legacyLifetime)
        XCTAssertEqual(store.activityIDsBySessionID, ["same": "old"])
    }

    func testQualifiedDeepLinkRoundTripAndUnknownProfileRejection() throws {
        let owner = OpenCodeLiveActivityOwner(profile: .v2, serverID: "raw|server-id")
        let url = try XCTUnwrap(OpenCodeChatActivityDeepLink.openAppURL(sessionID: "same", directory: "/work tree", workspaceID: "workspace",
            owner: owner, activityID: "os-id"))
        let parsed = try XCTUnwrap(LiveActivityCoordinator.deepLink(from: url))
        XCTAssertEqual(parsed.owner, owner)
        XCTAssertEqual(parsed.activityID, "os-id")
        XCTAssertEqual(parsed.action, .open)
        XCTAssertNil(LiveActivityCoordinator.deepLink(from: URL(string: "openclient://live-activity/session/same?profile=future&serverID=a")!))
    }

    func testFacadeAllowsOwnedV2ButRejectsUnresolvedV2Fallback() async {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel()
        viewModel.config = .init(baseURL: "https://stale-legacy.invalid")
        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        let adapter = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: viewModel.config), profile: .v2)
        viewModel.backendConnection = BackendConnection(
            descriptor: .init(id: "v2", name: "V2", version: "next"), capabilities: [.liveActivities],
            projects: adapter, sessions: backend, chat: backend, models: backend, events: backend
        )
        var requests: [LiveActivityStartRequest] = []
        let facade = LiveActivityFacade(viewModel: viewModel, requestOrUpdate: { requests.append($0) })
        XCTAssertTrue(facade.supportsLiveActivities)
        await facade.start(session: backend.storedSessions[0])
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests.first?.profile, .v2)
        XCTAssertEqual(requests.first?.credentialID, viewModel.config.recentServerID)
        viewModel.activeLiveActivitySessionIDs = []

        viewModel.backendConnection = nil
        viewModel.liveActivityStore.setLastState(nil, for: backend.storedSessions[0].id)
        viewModel.connectionStore.apiProfile = .v2
        await assertFacadeStartIsNoOp(viewModel)

        viewModel.connectionStore.apiProfile = nil
        viewModel.backendMode = .serverV2
        await assertFacadeStartIsNoOp(viewModel)

        viewModel.backendMode = .server
        viewModel.config.apiPreference = .v2
        await assertFacadeStartIsNoOp(viewModel)

        viewModel.config.apiPreference = .automatic
        await assertFacadeStartIsNoOp(viewModel)
    }

    func testFacadeRejectsInjectedBackendWithOrWithoutAdvertisedCapabilityAndAfterRemoval() async {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel(backendFactory: backend)
        viewModel.config = .init(baseURL: "https://stale-legacy.invalid")
        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        for capabilities: Set<BackendCapability> in [[], [.liveActivities]] {
            viewModel.backendConnection = BackendConnection(
                descriptor: .init(id: "injected", name: "Injected", version: "1"), capabilities: capabilities,
                projects: backend, sessions: backend, chat: backend, models: backend, events: backend
            )
            await assertFacadeStartIsNoOp(viewModel)
        }
        viewModel.backendConnection = nil
        await assertFacadeStartIsNoOp(viewModel)
        XCTAssertEqual(backend.projectLoads, 0)
        XCTAssertTrue(backend.listScopes.isEmpty)
        XCTAssertEqual(backend.transcriptLoads, 0)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testVerifiedV2FactoryEnablesLiveActivitiesAndUnresolvedFallbackDoesNot() {
        let config = OpenCodeServerConfig(baseURL: "https://owner.invalid", apiPreference: .v2)
        let model = AppViewModel()
        model.config = .init(baseURL: "https://stale.invalid", apiPreference: .legacy)
        model.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true)
        model.backendConnection = OpenCodeBackendFactory(client: .init(config: config), eventManager: model.eventManager)
            .makeConnection(profile: .v2, version: "0.0.0-next-17155", healthy: true)
        XCTAssertTrue(model.liveActivityFacade.supportsLiveActivities)
        XCTAssertTrue(model.chatFacade.supportsTalkLiveActivities)
        XCTAssertTrue(model.sessionListFacade.snapshot.supportsLiveActivities)
        XCTAssertTrue(model.activityFacade.allowsLiveActivities)
        XCTAssertEqual(model.liveActivityFacade.owner, .init(profile: .v2, serverID: config.recentServerID))
        model.backendConnection?.close()
        XCTAssertFalse(model.liveActivityFacade.supportsLiveActivities)
        model.backendConnection = nil
        XCTAssertFalse(model.liveActivityFacade.supportsLiveActivities)
    }

    func testFacadeLegacyRequiresCapabilityAndOpenConnectionAndUsesOwnerConfig() async throws {
        let backend = HomeTestBackend()
        let viewModel = AppViewModel()
        viewModel.config = .init(baseURL: "https://stale-legacy.invalid")
        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        let ownerConfig = OpenCodeServerConfig(baseURL: "https://owner.invalid", username: "owner")
        let adapter = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: ownerConfig), profile: .legacy)
        for capabilities: Set<BackendCapability> in [[], [.liveActivities]] {
            let connection = BackendConnection(
                descriptor: .init(id: "legacy", name: "Legacy", version: "1"), capabilities: capabilities,
                projects: adapter, sessions: backend, chat: backend, models: backend, events: backend
            )
            viewModel.backendConnection = connection
            if capabilities.isEmpty {
                await assertFacadeStartIsNoOp(viewModel)
                continue
            }
            var requests: [LiveActivityStartRequest] = []
            let facade = LiveActivityFacade(viewModel: viewModel, requestOrUpdate: { requests.append($0) })
            let session = backend.storedSessions[0]
            viewModel.errorMessage = "Previous error"
            await facade.start(session: session)
            XCTAssertNil(viewModel.errorMessage)
            XCTAssertTrue(facade.isActive(sessionID: session.id))
            XCTAssertNotNil(viewModel.liveActivityStore.lastState(for: session.id))

            viewModel.activeLiveActivitySessionIDs = []
            viewModel.liveActivityAutoStartByScope[viewModel.currentProjectPreferenceScopeKey] = true
            viewModel.errorMessage = "Keep auto-start error"
            await facade.autoStartIfEnabled(session: session)
            await facade.autoStartIfEnabled(session: session)
            XCTAssertEqual(requests.count, 2)
            XCTAssertEqual(viewModel.errorMessage, "Keep auto-start error")
            let request = try XCTUnwrap(requests.first)
            XCTAssertEqual(request.serverBaseURL, ownerConfig.baseURL)
            XCTAssertEqual(request.serverUsername, ownerConfig.username)
            XCTAssertEqual(request.credentialID, ownerConfig.recentServerID)
            XCTAssertEqual(request.sessionID, session.id)
            XCTAssertEqual(request.directory, session.directory)

            viewModel.activeLiveActivitySessionIDs = []
            viewModel.liveActivityStore.setLastState(nil, for: session.id)
            connection.close()
            await assertFacadeStartIsNoOp(viewModel)
        }
    }

    func testFacadePreservesAppleIntelligenceManualStartButNotAutoStart() async {
        let viewModel = AppViewModel()
        viewModel.config = .init(baseURL: "https://saved.invalid", apiPreference: .v2)
        viewModel.connectionStore.applyAppleIntelligenceMode()
        viewModel.liveActivityAutoStartByScope[viewModel.currentProjectPreferenceScopeKey] = true
        var requests: [LiveActivityStartRequest] = []
        let facade = LiveActivityFacade(viewModel: viewModel, requestOrUpdate: { requests.append($0) })
        let session = HomeTestBackend().storedSessions[0]

        await facade.autoStartIfEnabled(session: session)
        XCTAssertTrue(requests.isEmpty)
        await facade.start(session: session)
        XCTAssertEqual(requests.count, 1)
        XCTAssertTrue(facade.isActive(sessionID: session.id))
    }

    func testFacadePreservesLegacyStartBeforeConnectionOwnership() async {
        let viewModel = AppViewModel()
        viewModel.config = .init(baseURL: "https://legacy.invalid", apiPreference: .legacy)
        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        viewModel.liveActivityAutoStartByScope[viewModel.currentProjectPreferenceScopeKey] = true
        var requests: [LiveActivityStartRequest] = []
        let facade = LiveActivityFacade(viewModel: viewModel, requestOrUpdate: { requests.append($0) })
        let session = HomeTestBackend().storedSessions[0]

        await facade.start(session: session)
        viewModel.activeLiveActivitySessionIDs = []
        await facade.autoStartIfEnabled(session: session)

        XCTAssertEqual(requests.count, 2)
        XCTAssertEqual(requests.first?.serverBaseURL, viewModel.config.baseURL)
        XCTAssertNil(viewModel.backendConnection)
    }

    private func assertFacadeStartIsNoOp(
        _ viewModel: AppViewModel, file: StaticString = #filePath, line: UInt = #line
    ) async {
        var requests: [LiveActivityStartRequest] = []
        let facade = LiveActivityFacade(viewModel: viewModel, requestOrUpdate: { requests.append($0) })
        let session = HomeTestBackend().storedSessions[0]
        viewModel.liveActivityAutoStartByScope[viewModel.currentProjectPreferenceScopeKey] = true
        viewModel.errorMessage = "Keep existing error"

        await facade.start(session: session)
        await facade.toggle(session: session)
        await facade.autoStartIfEnabled(session: session)

        XCTAssertTrue(requests.isEmpty, file: file, line: line)
        XCTAssertTrue(viewModel.activeLiveActivitySessionIDs.isEmpty, file: file, line: line)
        XCTAssertNil(viewModel.liveActivityStore.lastState(for: session.id), file: file, line: line)
        XCTAssertEqual(viewModel.errorMessage, "Keep existing error", file: file, line: line)
    }
#endif

#if canImport(ActivityKit) && os(iOS)
    func testLastStateCanBeStoredAndCleared() {
        let store = LiveActivityStore()
        let state = OpenCodeChatActivityAttributes.ContentState(
            status: "Working",
            latestSnippet: "Running tests",
            transcriptLines: [],
            updatedAt: Date(timeIntervalSince1970: 100),
            pendingInteractionKind: nil,
            interactionID: nil,
            interactionTitle: nil,
            interactionSummary: nil,
            questionOptionLabels: [],
            canReplyToQuestionInline: false
        )

        store.setLastState(state, for: "ses_1")
        XCTAssertEqual(store.lastState(for: "ses_1"), state)

        store.setLastState(nil, for: "ses_1")
        XCTAssertNil(store.lastState(for: "ses_1"))
    }
#endif
}

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
@MainActor
private final class LiveActivityRestoreFixture {
    let model: AppViewModel
    let backend = HomeTestBackend()
    let saved = OpenCodeServerConfig(baseURL: "https://restored-owner.invalid", username: "owner", apiPreference: .automatic)
    let foreign = OpenCodeServerConfig(baseURL: "https://unrelated.invalid", username: "owner", apiPreference: .automatic)
    let profile: OpenCodeProfileIdentity
    let transport: URLSession
    var facade: LiveActivityFacade!
    var records: [LiveActivityRecord] = []
    var requests: [LiveActivityStartRequest] = []
    var updated: [String] = []
    var ended: [String] = []
    var connections: [OpenCodeServerConfig] = []
    var navigations: [OpenCodeSession] = []
    var canonicalReads = 0
    var didUpdate: (() -> Void)?
    var sessionID: String { backend.storedSessions[0].id }

    init(profile: OpenCodeProfileIdentity = .v2, missingProfile: Bool = false, backendFactory: (any BackendFactory)? = nil) {
        model = AppViewModel(backendFactory: backendFactory)
        self.profile = profile
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LiveActivityRestoreNetworkProtocol.self]
        transport = URLSession(configuration: configuration)
        model.backendConnection = nil
        model.connectionAttemptID = nil
        model.connectionStore.resetToDisconnected()
        model.config = foreign
        model.recentServerConfigs = [saved, foreign]
        let attributes = OpenCodeChatActivityAttributes(sessionID: sessionID, sessionTitle: "Persisted title",
            credentialID: saved.recentServerID, serverBaseURL: saved.baseURL, serverUsername: saved.username,
            directory: "/home-project", workspaceID: nil, profile: missingProfile ? nil : profile.rawValue)
        records = [.init(id: "restored-os-id", attributes: attributes,
            state: .init(status: "Live", latestSnippet: "Persisted text", transcriptLines: [], updatedAt: .now,
                pendingInteractionKind: nil, interactionID: nil, interactionTitle: nil, interactionSummary: nil,
                questionOptionLabels: [], canReplyToQuestionInline: false))]
        facade = LiveActivityFacade(viewModel: model, requestOrUpdate: { [weak self] in
            self?.requests.append($0)
            XCTFail("Restoration must not request a new OS activity")
        }, activityRecords: { [weak self] in self?.records ?? [] }, updateActivity: { [weak self] identity, id, state in
            guard let self, let index = records.firstIndex(where: { $0.attributes.matches(identity, activityID: id, actualActivityID: $0.id) }) else {
                XCTFail("Update did not target an owned OS record")
                return
            }
            updated.append(records[index].id)
            records[index] = .init(id: records[index].id, attributes: records[index].attributes, state: state)
            didUpdate?()
        }, endActivity: { [weak self] identity, id, _, _ in
            guard let self, let index = records.firstIndex(where: { $0.attributes.matches(identity, activityID: id, actualActivityID: $0.id) }) else {
                XCTFail("End did not target an owned OS record")
                return
            }
            ended.append(records.remove(at: index).id)
        })
        model.liveActivityFacade = facade
        facade.connectForRestoration = { [weak self] config in
            guard let self else { return }
            connections.append(config)
            install(config: config)
        }
        facade.navigateForRestoration = { [weak self] session in self?.navigations.append(session) }
        backend.beforeSessionFetch = { [weak self] in self?.canonicalReads += 1 }
    }

    deinit { transport.invalidateAndCancel() }

    func install(config: OpenCodeServerConfig? = nil) {
        let config = config ?? saved
        facade.connectionWillStart(config: config)
        model.backendConnection?.close()
        model.backendConnection = nil
        model.config = config
        model.directoryStoreRegistry.reset()
        let adapter = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: config, session: transport),
            profile: profile == .v2 ? .v2 : .legacy)
        model.backendConnection = BackendConnection(descriptor: .init(id: "restore-test", name: "Restore", version: "next"),
            capabilities: [.liveActivities, .interactions], projects: adapter, sessions: backend, chat: backend, models: backend, events: backend)
        if profile == .v2 { model.connectionStore.applySuccessfulV2Connection(version: "next", healthy: true) }
        else { model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true) }
        model.connectionStore.finishConnecting()
        model.connectionAttemptID = nil
        model.reconcileLiveActivities()
    }

    func url(action: [URLQueryItem] = []) throws -> URL {
        let attributes = try XCTUnwrap(records.first?.attributes)
        let url = try XCTUnwrap(OpenCodeChatActivityDeepLink.openAppURL(sessionID: attributes.sessionID,
            directory: attributes.directory, workspaceID: attributes.workspaceID,
            owner: attributes.identity?.owner, activityID: "restored-os-id"))
        if action.isEmpty { return url }
        var components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        components.queryItems = (components.queryItems ?? []).filter { $0.name != "action" } + action
        return try XCTUnwrap(components.url)
    }
}

@MainActor
private struct LiveActivityFailingConnectionFactory: BackendFactory {
    func connect() async throws -> BackendConnection { throw URLError(.cannotConnectToHost) }
}

private final class LiveActivityRestoreNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("A rejected restoration must not perform interaction reads or replies")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() {}
}
#endif

private final class LiveActivityTransportProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.handler?(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 204, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
