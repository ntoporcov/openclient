import XCTest
@testable import OpenClient

@MainActor
final class OpenCodeLocalCacheIntegrationTests: XCTestCase {
    func testCachedPresentationAndReentrantCanonicalCompletionPresentOnlyOnce() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        model.localCacheRepository = repository
        try await repository.saveChatMessages([message], serverID: XCTUnwrap(model.localCacheNamespace), sessionID: session.id)
        _ = model.beginSessionNavigation(session)
        _ = URLProtocol.registerClass(LocalCacheWorkflowURLProtocol.self)
        defer {
            LocalCacheWorkflowURLProtocol.handler = nil
            URLProtocol.unregisterClass(LocalCacheWorkflowURLProtocol.self)
        }
        var reads = 0
        LocalCacheWorkflowURLProtocol.handler = { _ in
            reads += 1
            if reads == 1 {
                XCTAssertTrue(model.hasPresentableCachedV2Chat)
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.text.started","data":{"sessionID":"session-cache","assistantMessageID":"msg_live","ordinal":0}}"#))
                _ = model.chatStore.applyV2StreamEvent(event, sessionID: self.session.id)
                await model.reconcileV2TimelineFromEvent(sessionID: self.session.id)
                return (200, #"{"data":[{"id":"msg_stale","type":"user","text":"stale","time":{"created":1}}]}"#)
            }
            return (200, #"{"data":[{"id":"msg_canonical","type":"user","text":"canonical","time":{"created":1}}]}"#)
        }
        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
        XCTAssertEqual(model.messages.map(\.id), ["msg_canonical"])
        XCTAssertEqual(model.chatStore.preparedSessionID, session.id)
        for task in Array(model.localCacheWriteTasksByKey.values) { await task.value }
    }

    func testV2CachedPresentationSurvivesHTTPFailureWithoutPreparingOrValidatingHistory() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        model.currentProject = project
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        model.localCacheRepository = repository
        let namespace = try XCTUnwrap(model.localCacheNamespace)
        try await repository.saveChatMessages([message], serverID: namespace, sessionID: session.id)
        _ = model.beginSessionNavigation(session)
        _ = URLProtocol.registerClass(LocalCacheWorkflowURLProtocol.self)
        defer {
            LocalCacheWorkflowURLProtocol.handler = nil
            URLProtocol.unregisterClass(LocalCacheWorkflowURLProtocol.self)
        }
        LocalCacheWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/session-cache/message")
            XCTAssertEqual(model.messages, [self.message])
            XCTAssertNil(model.chatStore.preparedSessionID)
            XCTAssertNil(model.chatStore.cachedMessagesBySessionID[self.session.id])
            XCTAssertTrue(model.appShellFacade.canPresentSelectedSessionDetail)
            XCTAssertEqual(model.appShellFacade.detailRoute(isCompact: true), .chat(.init(sessionID: self.session.id, presentationRequest: 1)))
            return (503, "{}")
        }
        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.messages, [message])
        XCTAssertNil(model.chatStore.preparedSessionID)
        XCTAssertNil(model.chatStore.messageHistoryBySessionID[session.id])
        XCTAssertFalse(model.chatStore.hasOlderV2Messages(sessionID: session.id))
        XCTAssertFalse(model.areLocalChatMessagesFresh(sessionID: session.id))
        XCTAssertTrue(model.appShellFacade.canPresentSelectedSessionDetail)
        XCTAssertNotNil(model.errorMessage)

        // A reconnect/foreground read can run after initial hydration failed. Its
        // loading state must not erase the only displayable transcript on failure.
        await model.reconcileV2TimelineFromEvent(sessionID: session.id)
        XCTAssertEqual(model.messages, [message])
        XCTAssertNil(model.chatStore.preparedSessionID)
        XCTAssertTrue(model.appShellFacade.canPresentSelectedSessionDetail)

        LocalCacheWorkflowURLProtocol.handler = { _ in
            (200, #"{"data":[{"id":"msg_recovered","type":"user","text":"recovered","time":{"created":1}}]}"#)
        }
        await model.reconcileV2TimelineFromEvent(sessionID: session.id)
        XCTAssertEqual(model.messages.map(\.id), ["msg_recovered"])
        XCTAssertNil(model.errorMessage)
        for task in Array(model.localCacheWriteTasksByKey.values) { await task.value }
    }

    func testFailedCanonicalReadWhileDiskReadIsPendingDoesNotSuppressCachedPresentation() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        _ = model.beginSessionNavigation(session)
        let cached = OpenCodeCachedChatSnapshot(preparedMessages: .init(envelopes: [message], sessionID: session.id),
            todos: [], messagesRefreshedAt: nil, todosRefreshedAt: nil)
        let sessionID = session.id
        let forbidden = expectation(description: "Unexpected operation")
        forbidden.isInverted = true
        model.localCacheRepository = ForbiddenLocalCacheRepository(access: forbidden, chatLoad: { _, _ in
            await model.reconcileV2TimelineFromEvent(sessionID: sessionID)
            return cached
        })
        _ = URLProtocol.registerClass(LocalCacheWorkflowURLProtocol.self)
        defer {
            LocalCacheWorkflowURLProtocol.handler = nil
            URLProtocol.unregisterClass(LocalCacheWorkflowURLProtocol.self)
        }
        LocalCacheWorkflowURLProtocol.handler = { _ in (503, "{}") }
        let result = await model.hydrateChatFromLocalCache(session, navigationGeneration: model.sessionNavigationGeneration,
            expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertNotNil(result)
        XCTAssertEqual(model.messages, [message])
        XCTAssertNil(model.chatStore.preparedSessionID)
        XCTAssertTrue(model.appShellFacade.canPresentSelectedSessionDetail)
        await fulfillment(of: [forbidden], timeout: 0.01)
    }

    func testCanonicalRecoveryDoesNotClearAnUnrelatedErrorEvenWithIdenticalText() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        _ = model.beginSessionNavigation(session)
        _ = URLProtocol.registerClass(LocalCacheWorkflowURLProtocol.self)
        defer {
            LocalCacheWorkflowURLProtocol.handler = nil
            URLProtocol.unregisterClass(LocalCacheWorkflowURLProtocol.self)
        }
        LocalCacheWorkflowURLProtocol.handler = { _ in (503, "{}") }
        _ = await model.hydrateV2Transcript(for: session, navigationGeneration: model.sessionNavigationGeneration,
            expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        let unrelated = try XCTUnwrap(model.errorMessage)
        model.errorMessage = unrelated
        LocalCacheWorkflowURLProtocol.handler = { _ in
            (200, #"{"data":[{"id":"msg_recovered","type":"user","text":"recovered","time":{"created":1}}]}"#)
        }
        await model.reconcileV2TimelineFromEvent(sessionID: session.id)
        XCTAssertEqual(model.messages.map(\.id), ["msg_recovered"])
        XCTAssertEqual(model.errorMessage, unrelated)
    }

    func testSuccessfulEmptyCanonicalReadWhileDiskReadIsPendingStillWins() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        _ = model.beginSessionNavigation(session)
        let cached = OpenCodeCachedChatSnapshot(preparedMessages: .init(envelopes: [message], sessionID: session.id),
            todos: [], messagesRefreshedAt: nil, todosRefreshedAt: nil)
        let sessionID = session.id
        let forbidden = expectation(description: "Unexpected operation")
        forbidden.isInverted = true
        model.localCacheRepository = ForbiddenLocalCacheRepository(access: forbidden, chatLoad: { _, _ in
            await MainActor.run {
                _ = model.chatStore.applyInitialV2Transcript([], olderCursor: nil, sessionID: sessionID)
            }
            return cached
        })
        let result = await model.hydrateChatFromLocalCache(session, navigationGeneration: model.sessionNavigationGeneration,
            expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertNil(result)
        XCTAssertEqual(model.messages, [])
        XCTAssertEqual(model.chatStore.preparedSessionID, session.id)
        XCTAssertFalse(model.hasPresentableCachedV2Chat)
        await fulfillment(of: [forbidden], timeout: 0.01)
    }

    func testV2CanonicalReadPersistsOnlyAcceptedHTTPRowsNotOptimisticInputs() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        model.localCacheRepository = repository
        let namespace = try XCTUnwrap(model.localCacheNamespace)
        _ = model.beginSessionNavigation(session)
        let pending = OpenCodeMessageEnvelope.local(role: "user", text: "Not canonical",
            messageID: "msg_pending", sessionID: session.id, partID: "part_pending")
        XCTAssertTrue(model.chatStore.beginV2Prompt(pending, sessionID: session.id))
        _ = URLProtocol.registerClass(LocalCacheWorkflowURLProtocol.self)
        defer {
            LocalCacheWorkflowURLProtocol.handler = nil
            URLProtocol.unregisterClass(LocalCacheWorkflowURLProtocol.self)
        }
        var reads = 0
        LocalCacheWorkflowURLProtocol.handler = { _ in
            reads += 1
            if reads == 1 {
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.text.started","data":{"sessionID":"session-cache","assistantMessageID":"msg_live","ordinal":0}}"#))
                _ = model.chatStore.applyV2StreamEvent(event, sessionID: self.session.id)
                return (200, #"{"data":[{"id":"msg_stale","type":"user","text":"stale","time":{"created":1}}]}"#)
            }
            return (200, #"{"data":[{"id":"msg_canonical","type":"user","text":"canonical","time":{"created":1}}]}"#)
        }
        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertTrue(accepted)
        XCTAssertEqual(reads, 2)
        for task in Array(model.localCacheWriteTasksByKey.values) { await task.value }
        let cached = try await repository.loadChat(serverID: namespace, sessionID: session.id)
        XCTAssertEqual(cached?.messages.map(\.id), ["msg_canonical"])
        XCTAssertFalse(model.chatStore.cachedMessagesBySessionID[session.id]?.contains { $0.id == pending.id } == true)
        XCTAssertEqual(model.chatStore.submissionRecoveries[pending.id]?.message, pending)
    }

    func testCacheWithoutBackendRequiresLegacySourceOfTruth() {
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        viewModel.connectionStore.apiProfile = nil
        XCTAssertTrue(viewModel.usesLocalCache)

        viewModel.config.apiPreference = .automatic
        XCTAssertFalse(viewModel.usesLocalCache)
        viewModel.connectionStore.resolveAPIProfile(.legacy)
        XCTAssertTrue(viewModel.usesLocalCache)
        viewModel.connectionStore.resolveAPIProfile(.v2)
        XCTAssertFalse(viewModel.usesLocalCache)

        viewModel.config.apiPreference = .v2
        viewModel.connectionStore.apiProfile = nil
        XCTAssertFalse(viewModel.usesLocalCache)
        viewModel.connectionStore.resolveAPIProfile(.legacy)
        XCTAssertFalse(viewModel.usesLocalCache)

        viewModel.config.apiPreference = .legacy
        viewModel.connectionStore.applyCachedServerConnection()
        XCTAssertTrue(viewModel.usesLocalCache)
        viewModel.config.apiPreference = .automatic
        XCTAssertFalse(viewModel.usesLocalCache)
        viewModel.config.apiPreference = .legacy
        viewModel.connectionStore.applyAppleIntelligenceMode()
        XCTAssertFalse(viewModel.usesLocalCache)
    }

    func testV2WithoutCapableBackendNeverInvokesRepository() async {
        let access = expectation(description: "V2 must not access the legacy cache namespace")
        access.isInverted = true
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        viewModel.config.apiPreference = .automatic
        viewModel.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        viewModel.localCacheRepository = ForbiddenLocalCacheRepository(access: access)
        viewModel.selectedDirectory = session.directory
        viewModel.selectedSession = session

        let projects = await viewModel.loadCachedProjectsIfEnabled()
        let directory = await viewModel.hydrateDirectoryFromLocalCache(session.directory)
        let chat = await viewModel.hydrateChatFromLocalCache(session)
        XCTAssertNil(projects)
        XCTAssertNil(directory)
        XCTAssertNil(chat)

        viewModel.persistProjectsToLocalCache()
        viewModel.persistDirectoryToLocalCache(viewModel.directoryStore, directory: session.directory)
        viewModel.persistDirectoryToLocalCache(viewModel.directoryStore, directory: session.directory, marksValidated: false)
        viewModel.persistLoadedMessagesToLocalCache([message], sessionID: session.id)
        viewModel.persistLoadedTodosToLocalCache([todo], sessionID: session.id)
        viewModel.scheduleLocalChatCacheWrite(
            sessionID: session.id,
            store: viewModel.directoryStore,
            includesTodos: true,
            immediate: true
        )
        viewModel.removeSessionFromLocalCache(session.id)

        XCTAssertTrue(viewModel.localCacheWriteTasksByKey.isEmpty)
        XCTAssertFalse(viewModel.hasHydratedLocalChat(sessionID: session.id))
        XCTAssertFalse(viewModel.isLocalDirectoryCacheFresh(session.directory))
        XCTAssertFalse(viewModel.areLocalChatMessagesFresh(sessionID: session.id))
        XCTAssertFalse(viewModel.areLocalChatTodosFresh(sessionID: session.id))
        await fulfillment(of: [access], timeout: 0.05)
    }

    func testProductionV2UsesCapturedAutomaticProfileAndIsolatedCache() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        model.localCacheRepository = repository
        let raw = model.config.recentServerID
        let namespace = try XCTUnwrap(model.localCacheNamespace)
        XCTAssertNotEqual(namespace, raw)
        XCTAssertTrue(model.usesLocalCache)
        XCTAssertEqual(model.config.apiPreference, .automatic)
        try await repository.saveProjects([project], serverID: raw)
        let missing = await model.loadCachedProjectsIfEnabled()
        XCTAssertNil(missing)
        try await repository.saveProjects([project], serverID: namespace)
        try await repository.saveChatMessages([message], serverID: namespace, sessionID: session.id)
        model.selectedDirectory = session.directory
        model.selectedSession = session
        let projects = await model.loadCachedProjectsIfEnabled()
        let chat = await model.hydrateChatFromLocalCache(session)
        XCTAssertEqual(projects?.projects, [project])
        XCTAssertEqual(chat?.messages, [message])
        XCTAssertEqual(chat?.todos, [])
        XCTAssertFalse(model.areLocalChatMessagesFresh(sessionID: session.id))
        XCTAssertFalse(model.areLocalChatTodosFresh(sessionID: session.id))
        await model.clearLocalCache(serverID: raw)
        let legacyAfterClear = try await repository.loadProjects(serverID: raw)
        let v2AfterClear = try await repository.loadProjects(serverID: namespace)
        XCTAssertNil(legacyAfterClear)
        XCTAssertNil(v2AfterClear)
    }

    func testSuspendedReadIsRejectedAfterSameProfileConnectionReplacementOrProfileChange() async throws {
        for replacementProfile in [OpenCodeAPIProfile.v2, .legacy] {
            let model = AppViewModel()
            model.config = serverConfig
            model.config.apiPreference = .automatic
            model.backendConnection = cacheConnection(model, profile: .v2)
            let expectedNamespace = try XCTUnwrap(model.localCacheNamespace)
            let started = expectation(description: "Read suspended")
            let forbidden = expectation(description: "Unexpected repository operation")
            forbidden.isInverted = true
            let gate = LocalCacheReadGate()
            let snapshot = OpenCodeCachedProjectsSnapshot(projects: [project], refreshedAt: Date())
            model.localCacheRepository = ForbiddenLocalCacheRepository(access: forbidden, projectLoad: { namespace in
                XCTAssertEqual(namespace, expectedNamespace)
                return await gate.wait(started: started, snapshot: snapshot)
            })
            let read = Task { await model.loadCachedProjectsIfEnabled() }
            await fulfillment(of: [started], timeout: 1)
            model.backendConnection = cacheConnection(model, profile: replacementProfile)
            await gate.resume()
            let result = await read.value
            XCTAssertNil(result)
            await fulfillment(of: [forbidden], timeout: 0.01)
        }
    }

    func testSuspendedWriteKeepsCapturedProfileNamespace() async throws {
        let model = AppViewModel()
        model.config = serverConfig
        model.config.apiPreference = .automatic
        model.backendConnection = cacheConnection(model, profile: .v2)
        let namespace = try XCTUnwrap(model.localCacheNamespace)
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let started = expectation(description: "Write suspended")
        let finished = expectation(description: "Write finished")
        let forbidden = expectation(description: "Unexpected operation")
        forbidden.isInverted = true
        let gate = LocalCacheReadGate()
        model.localCacheRepository = ForbiddenLocalCacheRepository(access: forbidden, projectSave: { projects, serverID, refreshedAt, writtenAt in
            _ = await gate.wait(started: started, snapshot: .init(projects: projects, refreshedAt: refreshedAt))
            XCTAssertEqual(serverID, namespace)
            try? await repository.saveProjects(projects, serverID: serverID, refreshedAt: refreshedAt, writtenAt: writtenAt)
            finished.fulfill()
        })
        model.projects = [project]
        model.persistProjectsToLocalCache()
        await fulfillment(of: [started], timeout: 1)
        model.backendConnection = cacheConnection(model, profile: .legacy)
        await gate.resume()
        await fulfillment(of: [finished], timeout: 1)
        let legacy = try await repository.loadProjects(serverID: model.config.recentServerID)
        let v2 = try await repository.loadProjects(serverID: namespace)
        XCTAssertNil(legacy)
        XCTAssertEqual(v2?.projects, [project])
        await fulfillment(of: [forbidden], timeout: 0.01)
    }

    private func cacheConnection(_ model: AppViewModel, profile: OpenCodeAPIProfile) -> BackendConnection {
        OpenCodeBackendFactory(client: OpenCodeAPIClient(config: model.config), eventManager: model.eventManager)
            .makeConnection(profile: profile, version: "test", healthy: true)
    }

    func testV2CannotReadCollidingLegacyCacheAndResolvedLegacyStillCan() async throws {
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        viewModel.localCacheRepository = repository
        let legacyServerID = serverConfig.recentServerID
        try await repository.saveProjects([project], serverID: legacyServerID)
        try await repository.saveDirectorySessions([session], serverID: legacyServerID, directory: session.directory)
        try await repository.saveChatMessages([message], serverID: legacyServerID, sessionID: session.id)
        try await repository.saveTodos([todo], serverID: legacyServerID, sessionID: session.id)

        viewModel.config.apiPreference = .automatic
        viewModel.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        XCTAssertEqual(viewModel.config.recentServerID, legacyServerID)
        viewModel.selectedDirectory = session.directory
        viewModel.selectedSession = session
        let v2Projects = await viewModel.loadCachedProjectsIfEnabled()
        let v2Directory = await viewModel.hydrateDirectoryFromLocalCache(session.directory)
        let v2Chat = await viewModel.hydrateChatFromLocalCache(session)
        XCTAssertNil(v2Projects)
        XCTAssertNil(v2Directory)
        XCTAssertNil(v2Chat)

        viewModel.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        let legacyProjects = await viewModel.loadCachedProjectsIfEnabled()
        let legacyDirectory = await viewModel.hydrateDirectoryFromLocalCache(session.directory)
        let legacyChat = await viewModel.hydrateChatFromLocalCache(session)
        XCTAssertEqual(legacyProjects?.projects, [project])
        XCTAssertEqual(legacyDirectory?.sessions, [session])
        XCTAssertEqual(legacyChat?.messages, [message])
        XCTAssertEqual(legacyChat?.todos, [todo])
    }

    func testPersistentCacheHydratesWithoutAUserPreference() async throws {
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        viewModel.localCacheRepository = repository
        try await repository.saveProjects([project], serverID: serverConfig.recentServerID)

        let snapshot = await viewModel.loadCachedProjectsIfEnabled()

        XCTAssertEqual(snapshot?.projects, [project])
    }

    func testDirectoryAndChatCacheHydrateThroughExistingStores() async throws {
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        viewModel.localCacheRepository = repository

        try await repository.saveDirectorySessions(
            [session],
            serverID: serverConfig.recentServerID,
            directory: session.directory
        )
        try await repository.saveChatMessages(
            [message],
            serverID: serverConfig.recentServerID,
            sessionID: session.id
        )
        try await repository.saveTodos(
            [todo],
            serverID: serverConfig.recentServerID,
            sessionID: session.id
        )

        viewModel.selectedDirectory = session.directory
        let directorySnapshot = await viewModel.hydrateDirectoryFromLocalCache(session.directory)
        viewModel.selectedSession = session
        let chatSnapshot = await viewModel.hydrateChatFromLocalCache(session)

        XCTAssertEqual(directorySnapshot?.sessions, [session])
        XCTAssertEqual(viewModel.directoryStore.sessions, [session])
        XCTAssertEqual(chatSnapshot?.messages, [message])
        XCTAssertEqual(viewModel.directoryStore.syncState.messageEnvelopes(forSessionID: session.id), [message])
        XCTAssertEqual(viewModel.directoryStore.syncState.todosBySessionID[session.id], [todo])
    }

    func testProjectNavigationHydratesCachedSessionsBeforeTheProjectRouteIsExposed() async throws {
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        viewModel.localCacheRepository = repository
        try await repository.saveDirectorySessions(
            [session],
            serverID: serverConfig.recentServerID,
            directory: project.worktree
        )

        _ = await viewModel.prepareProjectNavigation(project)

        XCTAssertEqual(viewModel.selectedDirectory, project.worktree)
        XCTAssertEqual(viewModel.directoryStore.sessions, [session])
        XCTAssertFalse(viewModel.isLoadingSessions)
    }

    func testSelectionPreparationExposesChatBeforeHydratingDisk() async throws {
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        viewModel.localCacheRepository = repository
        try await repository.saveChatMessages(
            [message],
            serverID: serverConfig.recentServerID,
            sessionID: session.id
        )
        viewModel.selectedDirectory = session.directory
        viewModel.allSessions = [session]

        let ticket = viewModel.sessionListFacade.beginSelection(session)
        XCTAssertEqual(
            viewModel.appShellFacade.detailRoute(isCompact: true),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: 0))
        )

        let prepared = await viewModel.sessionListFacade.prepareSelectionForNavigation(ticket)

        XCTAssertTrue(prepared)
        XCTAssertEqual(viewModel.messages, [message])
        XCTAssertEqual(
            viewModel.appShellFacade.detailRoute(isCompact: true),
            .chat(AppShellChatRoute(sessionID: session.id, presentationRequest: 0))
        )
    }

    func testOlderSelectionTicketCannotPrepareAfterNewerNavigationStarts() async throws {
        let viewModel = AppViewModel()
        viewModel.config = serverConfig
        viewModel.localCacheRepository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        let newerSession = OpenCodeSession(
            id: "session-newer",
            title: "Newer Session",
            workspaceID: nil,
            directory: session.directory,
            projectID: session.projectID,
            parentID: nil
        )
        viewModel.selectedDirectory = session.directory
        viewModel.allSessions = [session, newerSession]

        let olderTicket = viewModel.sessionListFacade.beginSelection(session)
        _ = viewModel.sessionListFacade.beginSelection(newerSession)

        let prepared = await viewModel.sessionListFacade.prepareSelectionForNavigation(olderTicket)

        XCTAssertFalse(prepared)
        XCTAssertEqual(viewModel.selectedSession?.id, newerSession.id)
    }

    private var serverConfig: OpenCodeServerConfig {
        OpenCodeServerConfig(
            name: "Cache Test",
            baseURL: "https://cache.example",
            username: "opencode",
            password: "password",
            apiPreference: .legacy
        )
    }

    private var project: OpenCodeProject {
        OpenCodeProject(
            id: "project-cache",
            worktree: "/project-cache",
            vcs: "git",
            name: "Cache",
            sandboxes: nil,
            icon: nil,
            time: nil
        )
    }

    private var session: OpenCodeSession {
        OpenCodeSession(
            id: "session-cache",
            title: "Cached Session",
            workspaceID: nil,
            directory: "/project-cache",
            projectID: "project-cache",
            parentID: nil
        )
    }

    private var message: OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope.local(
            role: "assistant",
            text: "Loaded from SwiftData",
            messageID: "message-cache",
            sessionID: session.id,
            partID: "part-cache"
        )
    }

    private var todo: OpenCodeTodo {
        OpenCodeTodo(content: "Verify local cache", status: "in_progress", priority: "high")
    }
}

private struct ForbiddenLocalCacheRepository: OpenCodeLocalCacheRepository {
    let access: XCTestExpectation
    var projectLoad: (@Sendable (String) async -> OpenCodeCachedProjectsSnapshot?)? = nil
    var projectSave: (@Sendable ([OpenCodeProject], String, Date, Date) async -> Void)? = nil
    var chatLoad: (@Sendable (String, String) async -> OpenCodeCachedChatSnapshot?)? = nil

    func loadProjects(serverID: String) async throws -> OpenCodeCachedProjectsSnapshot? {
        if let projectLoad { return await projectLoad(serverID) }
        access.fulfill()
        return nil
    }

    func saveProjects(_ projects: [OpenCodeProject], serverID: String, refreshedAt: Date, writtenAt: Date) async throws {
        if let projectSave { return await projectSave(projects, serverID, refreshedAt, writtenAt) }
        access.fulfill()
    }

    func loadDirectorySessions(serverID: String, directory: String?) async throws -> OpenCodeCachedDirectorySessionsSnapshot? {
        access.fulfill()
        return nil
    }

    func saveDirectorySessions(_ sessions: [OpenCodeSession], serverID: String, directory: String?, refreshedAt: Date, writtenAt: Date) async throws {
        access.fulfill()
    }

    func saveDirectoryMetadata(statuses: [String: String], permissions: [OpenCodePermission], questions: [OpenCodeQuestionRequest], serverID: String, directory: String?, refreshedAt: Date, writtenAt: Date) async throws {
        access.fulfill()
    }

    func loadChat(serverID: String, sessionID: String) async throws -> OpenCodeCachedChatSnapshot? {
        if let chatLoad { return await chatLoad(serverID, sessionID) }
        access.fulfill()
        return nil
    }

    func saveChatMessages(_ messages: [OpenCodeMessageEnvelope], serverID: String, sessionID: String, refreshedAt: Date, writtenAt: Date, coverage: OpenCodeLocalCacheTranscriptCoverage) async throws {
        access.fulfill()
    }

    func saveTodos(_ todos: [OpenCodeTodo], serverID: String, sessionID: String, refreshedAt: Date, writtenAt: Date) async throws {
        access.fulfill()
    }

    func removeSession(serverID: String, sessionID: String, removedAt: Date) async throws {
        access.fulfill()
    }

    func clear(serverID: String) async throws {
        access.fulfill()
    }
}

private actor LocalCacheReadGate {
    private var continuation: CheckedContinuation<OpenCodeCachedProjectsSnapshot?, Never>?
    private var snapshot: OpenCodeCachedProjectsSnapshot?

    func wait(started: XCTestExpectation, snapshot: OpenCodeCachedProjectsSnapshot) async -> OpenCodeCachedProjectsSnapshot? {
        self.snapshot = snapshot
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            started.fulfill()
        }
    }

    func resume() {
        continuation?.resume(returning: snapshot)
        continuation = nil
    }
}

private final class LocalCacheWorkflowURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?

    private struct Delivery: @unchecked Sendable {
        let loader: LocalCacheWorkflowURLProtocol
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "cache.example" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, body) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch {
                delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error)
            }
        }
    }

    override func stopLoading() {}
}
