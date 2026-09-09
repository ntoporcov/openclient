import Foundation

extension AppViewModel {
    var usesLocalCache: Bool {
        localCacheNamespace != nil
    }

    var localCacheNamespace: String? {
        guard backendFactory == nil, !isUsingAppleIntelligence else { return nil }
        if let backendConnection {
            guard !backendConnection.isClosed, backendConnection.capabilities.contains(.localCache),
                  let compatibility = backendConnection.openCodeCompatibility,
                  compatibility.client.config == config else { return nil }
            return OpenCodeLocalCacheIdentity.namespace(serverID: config.recentServerID, profile: compatibility.profile)
        }
        guard config.apiPreference != .v2 else { return nil }
        switch connectionStore.apiProfile {
        case .legacy:
            return config.recentServerID
        case .v2:
            return nil
        case nil:
            return config.apiPreference == .legacy && backendMode != .serverV2 ? config.recentServerID : nil
        }
    }

    var isBrowsingLocalCache: Bool {
        backendMode == .cachedServer
    }

    var hasPresentableCachedV2Chat: Bool {
        guard let namespace = localCacheNamespace, OpenCodeLocalCacheIdentity.isV2(namespace),
              let sessionID = selectedSession?.id,
              hasHydratedLocalChat(sessionID: sessionID), !chatStore.messages.isEmpty else { return false }
        return chatStore.messages.allSatisfy { $0.info.sessionID == sessionID }
    }

    func resetLocalCacheChatHydration(sessionID: String) {
        guard let namespace = localCacheNamespace else { return }
        localCacheHydratedChatKeys.remove(localCacheRuntimeKey(serverID: namespace, value: sessionID))
    }

    func resetLocalCacheRuntimeState() {
        localCacheWriteTasksByKey.values.forEach { $0.cancel() }
        localCacheWriteTasksByKey = [:]
        localCacheDirectoryRefreshedAtByKey = [:]
        localCacheMessageRefreshedAtByKey = [:]
        localCacheTodoRefreshedAtByKey = [:]
        localCacheHydratedChatKeys = []
        localCachePrefetchTasksByKey.values.forEach { $0.cancel() }
        localCachePrefetchTasksByKey = [:]
        localCachePrefetchedChatsByKey = [:]
        localCachePrefetchedChatKeys = []
    }

    func loadCachedProjectsIfEnabled() async -> OpenCodeCachedProjectsSnapshot? {
        guard usesLocalCache, config.hasCredentials else { return nil }
        guard let serverID = localCacheNamespace else { return nil }
        let connectionID = backendConnection?.id
        let snapshot = try? await localCacheRepository.loadProjects(serverID: serverID)
        guard !Task.isCancelled, localCacheNamespace == serverID, backendConnection?.id == connectionID else { return nil }
        return snapshot
    }

    func persistProjectsToLocalCache() {
        guard usesLocalCache, config.hasCredentials else { return }
        let repository = localCacheRepository
        guard let serverID = localCacheNamespace else { return }
        let snapshot = projects
        let writtenAt = Date()
        let connectionID = backendConnection?.id
        Task {
            guard localCacheNamespace == serverID, backendConnection?.id == connectionID else { return }
            try? await repository.saveProjects(
                snapshot,
                serverID: serverID,
                refreshedAt: writtenAt,
                writtenAt: writtenAt
            )
        }
    }

    @discardableResult
    func hydrateDirectoryFromLocalCache(_ directory: String?, workspaceID: String? = nil) async -> OpenCodeCachedDirectorySessionsSnapshot? {
        guard usesLocalCache, config.hasCredentials else { return nil }
        guard let serverID = localCacheNamespace else { return nil }
        let connectionID = backendConnection?.id
        let targetKey = DirectoryStoreRegistry.key(for: directory)
        let targetStore = directoryStoreRegistry.store(for: directory)
        let targetGeneration = directoryStoreRegistry.generation
        let initialSessions = targetStore.sessions
        let sessionRevision = targetStore.v2SessionRevision
        guard let snapshot = try? await localCacheRepository.loadDirectorySessions(
            serverID: serverID,
            directory: OpenCodeLocalCacheIdentity.directory(directory, workspaceID: workspaceID, namespace: serverID)
        ) else { return nil }
        guard !Task.isCancelled,
              usesLocalCache,
              localCacheNamespace == serverID,
              backendConnection?.id == connectionID,
              directoryStoreRegistry.generation == targetGeneration,
              directoryStoreRegistry.contains(targetStore, forKey: targetKey),
              targetStore.v2SessionRevision == sessionRevision,
              targetStore.sessions == initialSessions else { return nil }

        if initialSessions.isEmpty {
            let scopedSessions = sessionListStore.applyDirectoryReloadSessions(snapshot.sessions, scopedTo: directory)
            if targetStore.applyCachedSessions(scopedSessions), targetStore === directoryStore {
                objectWillChange.send()
            }
        }
        if let statuses = snapshot.statuses {
            _ = targetStore.applySessionStatuses(statuses)
        }
        if let permissions = snapshot.permissions {
            _ = targetStore.applyPermissions(permissions, ifUnchangedSince: targetStore.permissionRevision)
        }
        if let questions = snapshot.questions {
            _ = targetStore.applyQuestions(questions, ifUnchangedSince: targetStore.questionRevision)
        }
        localCacheDirectoryRefreshedAtByKey[localCacheRuntimeKey(serverID: serverID, value: targetKey)] = snapshot.refreshedAt
        return snapshot
    }

    func persistDirectoryToLocalCache(
        _ store: DirectoryStore,
        directory: String?,
        workspaceID: String? = nil,
        marksValidated: Bool = true
    ) {
        guard usesLocalCache, config.hasCredentials else { return }
        let repository = localCacheRepository
        guard let serverID = localCacheNamespace else { return }
        let cacheDirectory = OpenCodeLocalCacheIdentity.directory(directory, workspaceID: workspaceID, namespace: serverID)
        let sessions = store.sessions
        let statuses = store.sessionStatuses
        let permissions = store.syncState.permissionsBySessionID.values
            .flatMap { $0 }
            .sorted { $0.id < $1.id }
        let questions = store.syncState.questionsBySessionID.values
            .flatMap { $0 }
            .sorted { $0.id < $1.id }
        let runtimeKey = localCacheRuntimeKey(
            serverID: serverID,
            value: DirectoryStoreRegistry.key(for: directory)
        )
        let refreshedAt = marksValidated
            ? Date()
            : (localCacheDirectoryRefreshedAtByKey[runtimeKey] ?? .distantPast)
        let writtenAt = Date()
        let connectionID = backendConnection?.id
        if marksValidated {
            localCacheDirectoryRefreshedAtByKey[runtimeKey] = refreshedAt
        }
        Task {
            guard localCacheNamespace == serverID, backendConnection?.id == connectionID else { return }
            try? await repository.saveDirectorySessions(
                sessions,
                serverID: serverID,
                directory: cacheDirectory,
                refreshedAt: refreshedAt,
                writtenAt: writtenAt
            )
            guard localCacheNamespace == serverID, backendConnection?.id == connectionID,
                  !OpenCodeLocalCacheIdentity.isV2(serverID) else { return }
            try? await repository.saveDirectoryMetadata(
                statuses: statuses,
                permissions: permissions,
                questions: questions,
                serverID: serverID,
                directory: cacheDirectory,
                refreshedAt: refreshedAt,
                writtenAt: writtenAt
            )
        }
    }

    @discardableResult
    func hydrateChatFromLocalCache(
        _ session: OpenCodeSession,
        navigationGeneration: UInt? = nil,
        expectedDirectoryKey: String? = nil
    ) async -> OpenCodeCachedChatSnapshot? {
        guard usesLocalCache, config.hasCredentials else { return nil }
        guard let serverID = localCacheNamespace else { return nil }
        let connectionID = backendConnection?.id
        let targetStore = directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? directoryStore
        let targetGeneration = directoryStoreRegistry.generation
        let hadInitialMessages = targetStore.syncStore.messageCount(forSessionID: session.id) > 0
        let initialTodos = targetStore.syncState.todosBySessionID[session.id]
        let streamRevision = chatStore.v2StreamRevision(sessionID: session.id)
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
        let snapshot = await localChatSnapshot(
            serverID: serverID,
            sessionID: session.id,
            consumesPrefetch: true
        )

        guard !Task.isCancelled,
              usesLocalCache,
              localCacheNamespace == serverID,
              backendConnection?.id == connectionID,
              directoryStoreRegistry.generation == targetGeneration,
              directoryStoreRegistry.key(for: targetStore) != nil,
              chatStore.v2StreamRevision(sessionID: session.id) == streamRevision,
              directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycleRevision,
              navigationGeneration == nil || sessionNavigationGeneration == navigationGeneration,
              expectedDirectoryKey == nil || directoryStoreRegistry.activeKey == expectedDirectoryKey,
              selectedSession?.id == session.id else { return nil }
        let runtimeKey = localCacheRuntimeKey(serverID: serverID, value: session.id)
        let isV2 = OpenCodeLocalCacheIdentity.isV2(serverID)
        if !isV2 { localCacheHydratedChatKeys.insert(runtimeKey) }
        guard let snapshot else { return nil }
        let appliedMessages = !hadInitialMessages
            && targetStore.syncStore.messageCount(forSessionID: session.id) == 0
            && (!snapshot.preparedMessages.messages.isEmpty || snapshot.messagesRefreshedAt != nil)
        if appliedMessages {
            if isV2 {
                // Display only. Disk rows must not become canonical IDs, admission
                // evidence, a reconciliation anchor, or completed history.
                guard chatStore.preparedSessionID != session.id, chatStore.messages.isEmpty else { return nil }
                localCacheHydratedChatKeys.insert(runtimeKey)
                chatStore.messages = snapshot.preparedMessages.immediateMessages
                chatDetailPresentationRequest &+= 1
            } else {
                targetStore.applyCachedMessageState(snapshot.preparedMessages, forSessionID: session.id)
                chatStore.cacheMessages(snapshot.preparedMessages.immediateMessages, forSessionID: session.id)
            }
        }
        let appliedTodos = targetStore.syncState.todosBySessionID[session.id] == initialTodos
            && (!snapshot.todos.isEmpty || snapshot.todosRefreshedAt != nil)
        if appliedTodos {
            targetStore.applyTodos(snapshot.todos, forSessionID: session.id)
            sessionInteractionStore.applyTodos(
                snapshot.todos,
                forSessionID: session.id,
                selectedSessionID: selectedSession?.id
            )
        }

        if appliedMessages {
            localCacheMessageRefreshedAtByKey[runtimeKey] = snapshot.messagesRefreshedAt
        }
        if appliedTodos {
            localCacheTodoRefreshedAtByKey[runtimeKey] = snapshot.todosRefreshedAt
        }
        return snapshot
    }

    private func localChatSnapshot(
        serverID: String,
        sessionID: String,
        consumesPrefetch: Bool = false
    ) async -> OpenCodeCachedChatSnapshot? {
        guard localCacheNamespace == serverID else { return nil }
        let connectionID = backendConnection?.id
        let key = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        if let snapshot = localCachePrefetchedChatsByKey[key] {
            if consumesPrefetch {
                removePrefetchedChat(key)
            } else {
                touchPrefetchedChat(key)
            }
            return snapshot
        }

        let task: Task<OpenCodeCachedChatSnapshot?, Never>
        if let existingTask = localCachePrefetchTasksByKey[key] {
            task = existingTask
        } else {
            let repository = localCacheRepository
            task = Task {
                try? await repository.loadChat(serverID: serverID, sessionID: sessionID)
            }
            localCachePrefetchTasksByKey[key] = task
        }

        let snapshot = await task.value
        guard !task.isCancelled, localCacheNamespace == serverID, backendConnection?.id == connectionID else { return nil }
        localCachePrefetchTasksByKey[key] = nil
        if let snapshot, !consumesPrefetch {
            localCachePrefetchedChatsByKey[key] = snapshot
            touchPrefetchedChat(key)
        }
        return snapshot
    }

    private func touchPrefetchedChat(_ key: String) {
        localCachePrefetchedChatKeys.removeAll { $0 == key }
        localCachePrefetchedChatKeys.append(key)
        while localCachePrefetchedChatKeys.count > 1 {
            let removedKey = localCachePrefetchedChatKeys.removeFirst()
            localCachePrefetchedChatsByKey[removedKey] = nil
        }
    }

    private func removePrefetchedChat(_ key: String) {
        localCachePrefetchedChatsByKey[key] = nil
        localCachePrefetchedChatKeys.removeAll { $0 == key }
    }

    private func invalidatePrefetchedChat(serverID: String, sessionID: String) {
        let key = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        localCachePrefetchTasksByKey[key]?.cancel()
        localCachePrefetchTasksByKey[key] = nil
        removePrefetchedChat(key)
    }

    /// V2 callers pass the accepted, canonically ordered loaded transcript after
    /// their connection, lifecycle, stream revision, and canonical-read guards.
    func persistLoadedMessagesToLocalCache(
        _ messages: [OpenCodeMessageEnvelope], sessionID: String,
        coverage: OpenCodeLocalCacheTranscriptCoverage = .partial
    ) {
        guard usesLocalCache, config.hasCredentials else { return }
        let repository = localCacheRepository
        guard let serverID = localCacheNamespace else { return }
        invalidatePrefetchedChat(serverID: serverID, sessionID: sessionID)
        let runtimeKey = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        let refreshedAt = Date()
        let writtenAt = refreshedAt
        let connectionID = backendConnection?.id
        localCacheMessageRefreshedAtByKey[runtimeKey] = refreshedAt
        localCacheWriteTasksByKey[runtimeKey]?.cancel()
        localCacheWriteTasksByKey[runtimeKey] = Task {
            guard !Task.isCancelled else { return }
            guard localCacheNamespace == serverID, backendConnection?.id == connectionID else { return }
            try? await repository.saveChatMessages(
                messages,
                serverID: serverID,
                sessionID: sessionID,
                refreshedAt: refreshedAt,
                writtenAt: writtenAt,
                coverage: coverage
            )
        }
    }

    func persistLoadedTodosToLocalCache(_ todos: [OpenCodeTodo], sessionID: String) {
        guard usesLocalCache, config.hasCredentials else { return }
        let repository = localCacheRepository
        guard let serverID = localCacheNamespace, !OpenCodeLocalCacheIdentity.isV2(serverID) else { return }
        let runtimeKey = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        let refreshedAt = Date()
        let writtenAt = refreshedAt
        let connectionID = backendConnection?.id
        localCacheTodoRefreshedAtByKey[runtimeKey] = refreshedAt
        Task {
            guard localCacheNamespace == serverID, backendConnection?.id == connectionID else { return }
            try? await repository.saveTodos(
                todos,
                serverID: serverID,
                sessionID: sessionID,
                refreshedAt: refreshedAt,
                writtenAt: writtenAt
            )
        }
    }

    func scheduleLocalChatCacheWrite(
        sessionID: String,
        store: DirectoryStore,
        includesTodos: Bool,
        immediate: Bool = false
    ) {
        guard usesLocalCache, config.hasCredentials else { return }
        // V2 writes must come from canonical HTTP transcripts, not projected live state.
        guard let serverID = localCacheNamespace, !OpenCodeLocalCacheIdentity.isV2(serverID) else { return }
        invalidatePrefetchedChat(serverID: serverID, sessionID: sessionID)
        let runtimeKey = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        localCacheWriteTasksByKey[runtimeKey]?.cancel()
        let repository = localCacheRepository
        let syncState = store.syncState
        let messagesValidatedAt = localCacheMessageRefreshedAtByKey[runtimeKey] ?? .distantPast
        let todosValidatedAt = localCacheTodoRefreshedAtByKey[runtimeKey] ?? .distantPast
        let writtenAt = Date()
        let connectionID = backendConnection?.id

        localCacheWriteTasksByKey[runtimeKey] = Task.detached { [weak self] in
            if !immediate {
                try? await Task.sleep(for: .seconds(5))
            }
            guard !Task.isCancelled else { return }
            guard await MainActor.run(body: { [weak self] in
                self?.localCacheNamespace == serverID && self?.backendConnection?.id == connectionID
            }) else { return }
            let messages = syncState.messageEnvelopes(forSessionID: sessionID)
            let todos = syncState.todosBySessionID[sessionID] ?? []
            try? await repository.saveChatMessages(
                messages,
                serverID: serverID,
                sessionID: sessionID,
                refreshedAt: messagesValidatedAt,
                writtenAt: writtenAt
            )
            if includesTodos, !Task.isCancelled {
                try? await repository.saveTodos(
                    todos,
                    serverID: serverID,
                    sessionID: sessionID,
                    refreshedAt: todosValidatedAt,
                    writtenAt: writtenAt
                )
            }
            await MainActor.run { [weak self] in
                guard !Task.isCancelled else { return }
                self?.localCacheWriteTasksByKey[runtimeKey] = nil
            }
        }
    }

    func removeSessionFromLocalCache(_ sessionID: String) {
        guard usesLocalCache, config.hasCredentials else { return }
        let repository = localCacheRepository
        guard let serverID = localCacheNamespace else { return }
        invalidatePrefetchedChat(serverID: serverID, sessionID: sessionID)
        let runtimeKey = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        localCacheWriteTasksByKey[runtimeKey]?.cancel()
        localCacheWriteTasksByKey[runtimeKey] = nil
        localCacheMessageRefreshedAtByKey[runtimeKey] = nil
        localCacheTodoRefreshedAtByKey[runtimeKey] = nil
        localCacheHydratedChatKeys.remove(runtimeKey)
        let removedAt = Date()
        let connectionID = backendConnection?.id
        Task {
            guard localCacheNamespace == serverID, backendConnection?.id == connectionID else { return }
            try? await repository.removeSession(
                serverID: serverID,
                sessionID: sessionID,
                removedAt: removedAt
            )
        }
    }

    func persistManagedEventToLocalCache(
        _ managed: OpenCodeManagedEvent,
        applications: [DirectorySyncFacade.AppliedEvent],
        sessionID: String?
    ) {
        guard usesLocalCache else { return }

        switch managed.typed {
        case .sessionStatus,
             .sessionIdle,
             .permissionAsked,
             .permissionReplied,
             .questionAsked,
             .questionReplied,
             .questionRejected:
            for application in applications {
                let directory = directoryStoreRegistry.key(for: application.store)
                    .flatMap(DirectoryStoreRegistry.directory(forKey:))
                persistDirectoryToLocalCache(
                    application.store,
                    directory: directory,
                    marksValidated: false
                )
            }
        default:
            break
        }

        switch managed.typed {
        case let .sessionDeleted(session):
            removeSessionFromLocalCache(session.id)
        case let .sessionUpdated(session) where session.isArchived:
            removeSessionFromLocalCache(session.id)
        case .sessionCreated, .sessionUpdated:
            for application in applications {
                let directory = directoryStoreRegistry.key(for: application.store)
                    .flatMap(DirectoryStoreRegistry.directory(forKey:))
                persistDirectoryToLocalCache(
                    application.store,
                    directory: directory,
                    marksValidated: false
                )
            }
        case .messageUpdated,
             .messagePartUpdated,
             .messagePartDelta,
             .messageRemoved:
            guard OpenCodeLocalCacheEventWritePolicy.writesChatSnapshot(for: managed.typed) else { return }
            guard let sessionID else { return }
            for application in applications {
                scheduleLocalChatCacheWrite(
                    sessionID: sessionID,
                    store: application.store,
                    includesTodos: false
                )
            }
        case let .messagePartRemoved(messageID, _):
            for application in applications {
                guard let ownerSessionID = application.store.syncState.messagesBySessionID.first(where: { _, messages in
                    messages.contains { $0.id == messageID }
                })?.key else { continue }
                scheduleLocalChatCacheWrite(
                    sessionID: ownerSessionID,
                    store: application.store,
                    includesTodos: false
                )
            }
        case .todoUpdated:
            guard let sessionID else { return }
            for application in applications {
                scheduleLocalChatCacheWrite(
                    sessionID: sessionID,
                    store: application.store,
                    includesTodos: true
                )
            }
        case .sessionIdle:
            guard let sessionID else { return }
            for application in applications {
                scheduleLocalChatCacheWrite(
                    sessionID: sessionID,
                    store: application.store,
                    includesTodos: application.store.syncState.todosBySessionID[sessionID] != nil,
                    immediate: true
                )
            }
        default:
            break
        }
    }

    func isLocalDirectoryCacheFresh(_ directory: String?) -> Bool {
        guard let serverID = localCacheNamespace, !OpenCodeLocalCacheIdentity.isV2(serverID) else { return false }
        let key = localCacheRuntimeKey(
            serverID: serverID,
            value: DirectoryStoreRegistry.key(for: directory)
        )
        return OpenCodeLocalCacheFreshness.isFresh(localCacheDirectoryRefreshedAtByKey[key])
    }

    func areLocalChatMessagesFresh(sessionID: String) -> Bool {
        guard let serverID = localCacheNamespace, !OpenCodeLocalCacheIdentity.isV2(serverID) else { return false }
        let key = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        return OpenCodeLocalCacheFreshness.isFresh(localCacheMessageRefreshedAtByKey[key])
    }

    func areLocalChatTodosFresh(sessionID: String) -> Bool {
        guard let serverID = localCacheNamespace, !OpenCodeLocalCacheIdentity.isV2(serverID) else { return false }
        let key = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        return OpenCodeLocalCacheFreshness.isFresh(localCacheTodoRefreshedAtByKey[key])
    }

    func hasHydratedLocalChat(sessionID: String) -> Bool {
        guard let serverID = localCacheNamespace else { return false }
        let key = localCacheRuntimeKey(serverID: serverID, value: sessionID)
        return localCacheHydratedChatKeys.contains(key)
    }

    /// Forgetting a saved server clears both profiles without changing its identity.
    func clearLocalCache(serverID: String) async {
        let repository = localCacheRepository
        for profile in [OpenCodeAPIProfile.legacy, .v2] {
            try? await repository.clear(serverID: OpenCodeLocalCacheIdentity.namespace(serverID: serverID, profile: profile))
        }
    }

    private func localCacheRuntimeKey(serverID: String, value: String) -> String {
        "s\(serverID.utf8.count):\(serverID)s\(value.utf8.count):\(value):\(backendConnection?.id.uuidString ?? "offline")"
    }
}
