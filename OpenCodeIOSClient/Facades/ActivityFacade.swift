import Combine
import Foundation

@MainActor
final class ActivityFacade: ObservableObject {
    struct ProjectFilterSnapshot: Identifiable, Equatable {
        let id: String
        let title: String
        let icon: OpenCodeProject.Icon?
        let usesGlobalAvatar: Bool
    }

    struct ToolSnapshot: Identifiable, Equatable {
        let id: String
        let tool: String
        let title: String
        let detail: String?
    }

    struct RowSnapshot: Identifiable, Equatable {
        let recent: RecentProjectSession
        let projectID: String
        let projectIcon: OpenCodeProject.Icon?
        let usesGlobalProjectAvatar: Bool
        let needsInput: Bool
        let isWorking: Bool
        let statusTitle: String
        let latestUserText: String?
        let latestAssistantText: String?
        let runningTools: [ToolSnapshot]
        let updatedAt: Date?
        let latestUserMessageAt: Date?
        let pendingInteractionCount: Int
        let completedTodoCount: Int
        let todoCount: Int
        let isLiveActivityActive: Bool
        let isHydrating: Bool
        let hydrationGeneration: Int

        var id: String { recent.id }
    }

    struct Snapshot: Equatable {
        static let empty = Snapshot(
            projects: [],
            needsInputRows: [],
            workingRows: [],
            recentRows: [],
            isLoading: false,
            isReadOnly: false,
            showsLastUserMessage: true,
            selectedSessionID: nil
        )

        let projects: [ProjectFilterSnapshot]
        let needsInputRows: [RowSnapshot]
        let workingRows: [RowSnapshot]
        let recentRows: [RowSnapshot]
        let isLoading: Bool
        let isReadOnly: Bool
        let showsLastUserMessage: Bool
        var selectedSessionID: String?

        var isEmpty: Bool { needsInputRows.isEmpty && workingRows.isEmpty && recentRows.isEmpty }

        var placementSignature: String {
            [
                "input:\(needsInputRows.map(\.id).joined(separator: ","))",
                "working:\(workingRows.map(\.id).joined(separator: ","))",
                "recent:\(recentRows.map(\.id).joined(separator: ","))",
            ].joined(separator: "|")
        }
    }

    private struct DirectoryMetadataResult: Sendable {
        let statuses: [String: String]?
        let permissions: [OpenCodePermission]?
        let questions: [OpenCodeQuestionRequest]?
        var forms: [OpenCodeV2Form]? = nil
        var statusRevision: UInt? = nil
        var permissionRevision: UInt? = nil
        var questionRevision: UInt? = nil
    }

    private struct CachedChatHydrationResult: Sendable {
        let session: OpenCodeSession
        let snapshot: OpenCodeCachedChatSnapshot?
    }

    // These copy-on-write values deliberately exclude transcript text. Comparing them
    // keeps interactions and lifecycle changes off the slower preview refresh path.
    private struct DirectoryPresentationMetadata: Equatable {
        let sessions: [OpenCodeSession]
        let statuses: [String: String]
        let syncStatuses: [String: String]
        let todos: [String: [OpenCodeTodo]]
        let permissions: [String: [OpenCodePermission]]
        let questions: [String: [OpenCodeQuestionRequest]]
        let forms: [BackendFormKey: BackendForm]
    }

    private struct PresentationMetadata: Equatable {
        let directories: [ObjectIdentifier: DirectoryPresentationMetadata]
        let scopes: [BackendScope]
        let projects: [OpenCodeProject]
        let recentSessions: [String: [OpenCodeSession]]
        let hiddenIDs: Set<String>
        let liveActivityIDs: Set<String>
        let lifecycleRevisions: [String: UInt]
        let selectedSessionID: String?
        let isReadOnly: Bool
        let showsLastUserMessage: Bool
        let isLoadingRecentSessions: Bool
    }

    private struct PreviewKey: Hashable {
        let sessionID: String
        let role: String
    }

    private struct CachedPreview {
        let messageID: String
        let textParts: [String]
        let text: String?
    }

    private struct InteractionKey: Hashable {
        let ownerID: ObjectIdentifier
        let sessionID: String
    }

    @Published private(set) var snapshot = Snapshot.empty

    var sessionSwitcherCandidates: [OpenCodeSession] {
        recentChatRows.map(\.recent.session)
    }

    private var recentChatRows: [RowSnapshot] {
        let now = Date()
        let calendar = Calendar.autoupdatingCurrent
        let hiddenIDs = viewModel.hiddenProjectActionSessionIDs
        var seenIDs = Set<String>()
        return snapshot.recentRows.filter {
            ActivityRecentBucket.bucket(for: $0.updatedAt, now: now, calendar: calendar) == .recent
        }.filter { row in
            let session = row.recent.session
            return session.isRootSession && !session.isArchived && !hiddenIDs.contains(session.id)
                && !viewModel.directoryStoreRegistry.isV2SessionDeleted(session.id)
                && seenIDs.insert(session.id).inserted
        }
    }

    func sessionSwitcherTarget(id: String) -> OpenCodeSession? {
        guard !viewModel.directoryStoreRegistry.isV2SessionDeleted(id),
              let row = (snapshot.needsInputRows + snapshot.workingRows + snapshot.recentRows)
                .first(where: { $0.recent.session.id == id }) else { return nil }
        let target = session(
            viewModel.directoryStoreRegistry.session(matching: id) ?? row.recent.session,
            preservingAttributionFrom: row.recent.session
        )
        guard target.isRootSession, !target.isArchived, !viewModel.isActionSession(target) else { return nil }
        return target
    }

    private unowned let viewModel: AppViewModel
    private weak var liveActivityBackgroundBridge: LiveActivityBackgroundBridge?
    private var observations: Set<AnyCancellable> = []
    private var monitoredStoreObservations: Set<AnyCancellable> = []
    private var monitoredStoreIDs: Set<ObjectIdentifier> = []
    private var snapshotRefreshTask: Task<Void, Never>?
    private var previewRefreshTask: Task<Void, Never>?
    private var lastSnapshotRefresh = ContinuousClock.now
    private var presentationMetadata: PresentationMetadata?
    private var cachedPreviews: [PreviewKey: CachedPreview] = [:]
    private var cachedInteractionCounts: [InteractionKey: (permissions: Int, questions: Int)] = [:]
    private var preparationTask: Task<Void, Never>?
    private var isPreparing = false
    private var hasCompletedInitialCacheHydration = false
    private var hydratingSessionIDs: Set<String> = []
    private var hydratedSessionIDs: Set<String> = []
    private var hydrationGeneration = 0
    private var directoryMetadataTasks: [String: Task<DirectoryMetadataResult, Never>] = [:]
    private let preloadQueue = RecentChatPreloadQueue()
    private var preloadAttemptedIDs: Set<String> = []
    private var preparedConnectionID: UUID?
    private var hasCompletedPreparation = false

    // Status hydration is still an OpenCode compatibility service, not a core backend contract.
    var isAvailable: Bool {
        viewModel.isBrowsingLocalCache || viewModel.compatibilityClient(for: .interactions) != nil
    }
    var allowsLiveActivities: Bool {
        !viewModel.isBrowsingLocalCache && viewModel.liveActivityFacade.supportsLiveActivities
    }
    var allowsNewTalk: Bool { viewModel.projectFacade.allowsNewTalk }

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        snapshot = makeSnapshot()
        presentationMetadata = makePresentationMetadata()

        Publishers.MergeMany([
            viewModel.sessionListStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.projectActionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.projectStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.liveActivityStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.appCustomizationStore.objectWillChange.eraseToAnyPublisher(),
        ])
        .receive(on: DispatchQueue.main)
        .sink { [weak self] _ in
            self?.scheduleSnapshotRefresh()
        }
        .store(in: &observations)

        bindMonitoredStores()
    }

    func attachLiveActivityBackgroundBridge(_ bridge: LiveActivityBackgroundBridge) {
        liveActivityBackgroundBridge = bridge
    }

    func prepareForPresentation(force: Bool = false) async {
        guard isAvailable else { return }
        let connectionID = viewModel.backendConnection?.id
        if !force, let preparationTask {
            await preparationTask.value
            await preloadQueue.waitUntilIdle()
            return
        }
        if !force, hasCompletedPreparation, preparedConnectionID == connectionID {
            refreshSnapshot()
            await preloadQueue.waitUntilIdle()
            return
        }

        preloadQueue.cancelAll()
        preloadAttemptedIDs = []
        hasCompletedPreparation = false
        hydrationGeneration &+= 1
        let generation = hydrationGeneration
        preparationTask?.cancel()
        hydratedSessionIDs = []
        hydratingSessionIDs = []
        directoryMetadataTasks.values.forEach { $0.cancel() }
        directoryMetadataTasks = [:]
        isPreparing = true
        refreshSnapshot()
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await hydrateFromLocalCache()
            guard generation == hydrationGeneration, !Task.isCancelled else { return }
            hasCompletedInitialCacheHydration = true
            bindMonitoredStores()
            refreshSnapshot()

            await viewModel.loadRecentProjectSessionsAcrossProjects()
            guard generation == hydrationGeneration, !Task.isCancelled,
                  viewModel.isConnected,
                  let connection = try? viewModel.requireBackendConnection() else {
                refreshSnapshot()
                return
            }

            let candidates = recentCandidates()
            for candidate in candidates {
                _ = viewModel.directoryStoreRegistry
                    .store(for: monitoringDirectory(for: candidate.session))
                    .upsertSessions([candidate.session])
            }
            bindMonitoredStores()
            refreshSnapshot()

            for scope in viewModel.homeSessionScopes {
                let store = viewModel.directoryStoreRegistry.store(for: scope.directory)
                let statusRevision = store.statusRevision
                let permissionRevision = store.permissionRevision
                let questionRevision = store.questionRevision
                let metadata = await directoryMetadata(directory: scope.directory, connection: connection)
                guard viewModel.isCurrentBackendConnection(connection), generation == hydrationGeneration,
                      viewModel.directoryStoreRegistry.key(for: store) != nil else { return }
                // Active or blocked sessions can be older than the first recent-session page.
                let pendingIDs = Set(metadata.statuses?.filter { $0.value != "idle" }.map(\.key) ?? [])
                    .union(metadata.permissions?.map(\.sessionID) ?? [])
                    .union(metadata.forms?.map(\.sessionID) ?? [])
                    .union(metadata.questions?.map(\.sessionID) ?? [])
                var sessionsToDiscover = Array(pendingIDs).sorted()
                var discoveredIDs: Set<String> = []
                while let id = sessionsToDiscover.popLast() {
                    guard discoveredIDs.insert(id).inserted,
                          !viewModel.directoryStoreRegistry.isV2SessionDeleted(id) else { continue }
                    if let session = viewModel.directoryStoreRegistry.snapshot(forSessionID: id)?.session {
                        if let parentID = session.parentID, !discoveredIDs.contains(parentID) {
                            sessionsToDiscover.append(parentID)
                        }
                        continue
                    }
                    let lifecycleRevision = viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: id)
                    guard let session = try? await connection.sessions.session(id: id, scope: scope) else { continue }
                    guard viewModel.isCurrentBackendConnection(connection), generation == hydrationGeneration else { return }
                    guard viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: id) == lifecycleRevision,
                          !viewModel.directoryStoreRegistry.isV2SessionDeleted(id), project(for: session) != nil else { continue }
                    let directory = monitoringDirectory(for: session)
                    _ = viewModel.directoryStoreRegistry.store(for: directory).upsertSessions([session])
                    let recent = viewModel.sessionListStore.recentSessionsByDirectory[SessionListStore.recentDirectoryKey(directory)] ?? []
                    viewModel.sessionListStore.setRecentSessions(recent.filter { $0.id != id } + [session], for: directory)
                    if let parentID = session.parentID, !discoveredIDs.contains(parentID) {
                        sessionsToDiscover.append(parentID)
                    }
                }
                applyMetadata(metadata, to: store, statusRevision: statusRevision,
                    permissionRevision: permissionRevision, questionRevision: questionRevision)
            }
            bindMonitoredStores()
        }
        preparationTask = task
        await task.value
        guard generation == hydrationGeneration, viewModel.backendConnection?.id == connectionID else { return }
        preparationTask = nil
        isPreparing = false
        hasCompletedPreparation = true
        preparedConnectionID = connectionID
        refreshSnapshot()
        await preloadQueue.waitUntilIdle()
        if generation == hydrationGeneration { refreshSnapshot() }
    }

    func resetForConnectionChange() {
        hydrationGeneration &+= 1
        preparationTask?.cancel()
        preparationTask = nil
        preloadQueue.cancelAll()
        preloadAttemptedIDs = []
        hydratedSessionIDs = []
        hydratingSessionIDs = []
        directoryMetadataTasks.values.forEach { $0.cancel() }
        directoryMetadataTasks = [:]
        snapshotRefreshTask?.cancel()
        snapshotRefreshTask = nil
        previewRefreshTask?.cancel()
        previewRefreshTask = nil
        presentationMetadata = nil
        cachedPreviews = [:]
        cachedInteractionCounts = [:]
        monitoredStoreObservations.removeAll()
        monitoredStoreIDs = []
        preparedConnectionID = nil
        hasCompletedPreparation = false
        hasCompletedInitialCacheHydration = false
        isPreparing = false
        snapshot = .empty
    }

    private func scheduleRecentPreloads() {
        guard hasCompletedPreparation, !isPreparing, viewModel.isConnected,
              preparedConnectionID == viewModel.backendConnection?.id else { return }
        for row in recentChatRows where !hydratedSessionIDs.contains(row.recent.session.id) {
            guard preloadAttemptedIDs.insert(row.recent.session.id).inserted else { continue }
            preloadQueue.enqueue(id: row.recent.session.id) { [weak self] in
                await self?.performHydration(row)
            }
        }
    }

    private func hydrateFromLocalCache() async {
        guard viewModel.config.hasCredentials, let serverID = viewModel.localCacheNamespace else { return }
        let connectionID = viewModel.backendConnection?.id
        let generation = hydrationGeneration
        let directories = viewModel.projectCoordinator.recentSessionDirectories(
            projects: viewModel.projects,
            currentProject: viewModel.currentProject,
            selectedDirectory: viewModel.selectedDirectory
        )
        for directory in directories {
            _ = await viewModel.hydrateDirectoryFromLocalCache(directory)
        }

        // V2 disk transcripts are display-only and are hydrated by the selected chat,
        // never seeded into the canonical cache used by the event reducer.
        guard !OpenCodeLocalCacheIdentity.isV2(serverID) else { return }

        let candidates = recentCandidates()
        guard !candidates.isEmpty else { return }
        let repository = viewModel.localCacheRepository
        let registryGeneration = viewModel.directoryStoreRegistry.generation
        guard !Task.isCancelled, generation == hydrationGeneration,
              viewModel.localCacheNamespace == serverID, viewModel.backendConnection?.id == connectionID else { return }

        for candidate in candidates {
            _ = viewModel.directoryStoreRegistry
                .store(for: monitoringDirectory(for: candidate.session))
                .upsertSessions([candidate.session])
        }
        bindMonitoredStores()

        await withTaskGroup(of: CachedChatHydrationResult.self) { group in
            for candidate in candidates {
                let session = candidate.session
                group.addTask {
                    let snapshot = try? await repository.loadChat(
                        serverID: serverID,
                        sessionID: session.id
                    )
                    return CachedChatHydrationResult(session: session, snapshot: snapshot)
                }
            }

            for await result in group {
                guard !Task.isCancelled,
                       generation == hydrationGeneration,
                       viewModel.localCacheNamespace == serverID,
                       viewModel.backendConnection?.id == connectionID,
                       viewModel.directoryStoreRegistry.generation == registryGeneration,
                       !viewModel.directoryStoreRegistry.isV2SessionDeleted(result.session.id),
                       let snapshot = result.snapshot else { continue }
                guard let store = viewModel.directoryStoreRegistry.existingStore(for: monitoringDirectory(for: result.session)),
                      store.sessions.contains(where: { $0.id == result.session.id }) else { continue }

                if store.syncStore.messageCount(forSessionID: result.session.id) == 0,
                   !snapshot.preparedMessages.messages.isEmpty || snapshot.messagesRefreshedAt != nil {
                    store.applyCachedMessageState(snapshot.preparedMessages, forSessionID: result.session.id)
                }
                if store.syncState.todosBySessionID[result.session.id] == nil,
                   !snapshot.todos.isEmpty || snapshot.todosRefreshedAt != nil {
                    store.applyTodos(snapshot.todos, forSessionID: result.session.id)
                }
            }
        }
    }

    func prepareSelection(_ row: RowSnapshot) {
        viewModel.prepareRecentProjectSessionSelection(row.recent)
        if snapshot.selectedSessionID != viewModel.selectedSession?.id {
            snapshot.selectedSessionID = viewModel.selectedSession?.id
        }
    }

    var selectionContextID: String {
        "\(viewModel.backendConnection?.id.uuidString ?? "")|\(viewModel.directoryStoreRegistry.generation)|\(viewModel.sessionNavigationGeneration)"
    }

    func canSelect(_ row: RowSnapshot, context: String) -> Bool {
        selectionContextID == context && !row.recent.session.isArchived
            && !viewModel.directoryStoreRegistry.isV2SessionDeleted(row.recent.session.id)
            && (snapshot.needsInputRows + snapshot.workingRows + snapshot.recentRows).contains { $0.id == row.id }
    }

    func open(_ row: RowSnapshot) async {
        await viewModel.openRecentProjectSession(row.recent)
    }

    func delete(_ row: RowSnapshot) async {
        guard !viewModel.isBrowsingLocalCache else { return }
        let lifetime = viewModel.liveActivityFacade.currentLifetime
        if await viewModel.deleteSession(row.recent.session) {
            liveActivityBackgroundBridge?.cancel(sessionID: row.recent.session.id, reason: "Session deleted", lifetime: lifetime)
        }
    }

    func rename(_ row: RowSnapshot, title: String) async {
        guard !viewModel.isBrowsingLocalCache else { return }
        await viewModel.renameSession(row.recent.session, title: title)
    }

    func toggleLiveActivity(_ row: RowSnapshot) async {
        guard allowsLiveActivities else { return }
        await viewModel.liveActivityFacade.toggle(session: row.recent.session)
    }

    func presentNewChat() {
        viewModel.projectFacade.presentNewChat()
    }

    func presentNewTalk() {
        viewModel.projectFacade.presentNewTalk()
    }

    var showsLastUserMessage: Bool {
        viewModel.appCustomizationStore.showsActivityLastUserMessage
    }

    func setShowsLastUserMessage(_ shows: Bool) {
        viewModel.appCustomizationStore.setShowsActivityLastUserMessage(shows)
        refreshSnapshot()
    }

    func hydrateIfNeeded(_ row: RowSnapshot) async {
        guard row.hydrationGeneration == hydrationGeneration,
              !hydratedSessionIDs.contains(row.recent.session.id) else { return }
        await preloadQueue.request(id: row.recent.session.id) { [weak self] in
            await self?.performHydration(row)
        }
        if row.hydrationGeneration == hydrationGeneration { refreshSnapshot() }
    }

    private func performHydration(_ row: RowSnapshot) async {
        let session = row.recent.session
        guard !Task.isCancelled, row.hydrationGeneration == hydrationGeneration,
              !hydratedSessionIDs.contains(session.id),
              hydratingSessionIDs.insert(session.id).inserted else { return }
        scheduleSnapshotRefresh()
        defer {
            if row.hydrationGeneration == hydrationGeneration {
                hydratingSessionIDs.remove(session.id)
                scheduleSnapshotRefresh()
            }
        }

        guard isAvailable, viewModel.isConnected,
              let connection = try? viewModel.requireBackendConnection(),
              let client = try? connection.requireOpenCodeClient(for: .interactions) else { return }
        let directory = monitoringDirectory(for: session)
        let store = viewModel.directoryStoreRegistry.store(for: directory)
        let permissionRevision = store.permissionRevision
        let questionRevision = store.questionRevision
        let statusRevision = store.statusRevision
        let lifecycleRevision = viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id)
        let streamRevision = viewModel.chatStore.v2StreamRevision(sessionID: session.id)
        let previousMessages = store.syncState.messageEnvelopes(forSessionID: session.id)
        let previousCachedMessages = viewModel.chatStore.cachedMessagesBySessionID[session.id]
        let previousTodos = store.syncState.todosBySessionID[session.id]
        let previousSession = store.sessions.first { $0.id == session.id }
        let registryGeneration = viewModel.directoryStoreRegistry.generation
        let scope = BackendScope(projectID: project(for: session)?.id, directory: directory, workspaceID: session.workspaceID)
        let isV2 = connection.openCodeCompatibility?.profile == .v2

        async let canonicalSession = try? await connection.sessions.session(id: session.id, scope: scope)
        async let messages = try? await connection.chat.transcript(sessionID: session.id, scope: scope, cursor: nil, limit: 20)
        async let todos: [OpenCodeTodo]? = isV2 ? nil : try? await client.getTodos(sessionID: session.id)
        async let metadata = directoryMetadata(directory: directory, connection: connection)
        let result = await (canonicalSession, messages, todos, metadata)

        guard !Task.isCancelled, row.hydrationGeneration == hydrationGeneration else { return }
        guard viewModel.isCurrentBackendConnection(connection),
               row.hydrationGeneration == hydrationGeneration,
               viewModel.directoryStoreRegistry.generation == registryGeneration,
              viewModel.directoryStoreRegistry.v2LifecycleRevision(sessionID: session.id) == lifecycleRevision,
              !viewModel.directoryStoreRegistry.isV2SessionDeleted(session.id),
              viewModel.directoryStoreRegistry.key(for: store) != nil else { return }
        let currentSession = store.sessions.first { $0.id == session.id }
        guard currentSession?.isArchived != true,
              currentSession?.isRootSession != false,
              !viewModel.hiddenProjectActionSessionIDs.contains(session.id),
              previousSession == nil || currentSession != nil,
              currentSession?.directory == previousSession?.directory,
              currentSession?.workspaceID == previousSession?.workspaceID,
              currentSession?.projectID == previousSession?.projectID else { return }
        if let canonicalSession = result.0 {
            let attributed = self.session(canonicalSession, preservingAttributionFrom: session)
            guard monitoringDirectory(for: attributed) == directory,
                  attributed.isRootSession,
                  attributed.projectID == session.projectID,
                  attributed.workspaceID == session.workspaceID else { return }
        }
        let isForeground = viewModel.selectedSession?.id == session.id || viewModel.windowSessionInterests.values.contains(session.id)
        if let canonicalSession = result.0, currentSession == previousSession, !isForeground {
            _ = store.upsertSessions([canonicalSession])
        }
        guard result.0?.isArchived != true else { return }
        var appliedTranscript = false
        if let page = result.1, result.0 != nil, !isForeground,
           viewModel.chatStore.v2StreamRevision(sessionID: session.id) == streamRevision,
           viewModel.chatStore.cachedMessagesBySessionID[session.id] == previousCachedMessages,
           store.syncState.messageEnvelopes(forSessionID: session.id) == previousMessages {
            let mergedMessages = isV2
                ? ChatStore.mergingPreloadedV2Page(page.messages, into: previousMessages, hasOlder: page.olderCursor != nil)
                : ChatStore.mergingCanonicalMessagePage(page.messages, into: previousMessages)
            if isV2 {
                store.applyV2Messages(mergedMessages, forSessionID: session.id)
                viewModel.inferFunAndGames(from: mergedMessages, forSessionID: session.id)
            } else {
                store.applyCanonicalMessages(mergedMessages, forSessionID: session.id)
            }
            viewModel.refreshSessionPreview(for: session.id, messages: mergedMessages)
            viewModel.chatStore.cachePreloadedMessages(mergedMessages, forSessionID: session.id, preservingOrder: isV2)
            viewModel.persistLoadedMessagesToLocalCache(isV2 ? page.messages : mergedMessages, sessionID: session.id,
                coverage: isV2 ? .newestPage(hasOlder: page.olderCursor != nil) : .partial)
            appliedTranscript = true
        }
        if let todos = result.2, !isForeground, store.syncState.todosBySessionID[session.id] == previousTodos {
            store.applyTodos(todos, forSessionID: session.id)
            viewModel.persistLoadedTodosToLocalCache(todos, sessionID: session.id)
        }
        applyMetadata(result.3, to: store, statusRevision: statusRevision,
            permissionRevision: permissionRevision, questionRevision: questionRevision)
        viewModel.liveActivityFacade.reducerDidCommit(sessionIDs: [session.id])
        if result.3.statuses != nil || result.3.permissions != nil || result.3.questions != nil {
            viewModel.persistDirectoryToLocalCache(
                store,
                directory: directory,
                marksValidated: result.3.statuses != nil
                    && result.3.permissions != nil
                    && result.3.questions != nil
            )
        }
        if appliedTranscript { hydratedSessionIDs.insert(session.id) }
    }

    private func directoryMetadata(directory: String?, connection: BackendConnection) async -> DirectoryMetadataResult {
        let key = "\(connection.id)|\(hydrationGeneration)|\(DirectoryStoreRegistry.key(for: directory))"
        if let task = directoryMetadataTasks[key] {
            return await task.value
        }

        guard let client = try? connection.requireOpenCodeClient(for: .interactions) else {
            return DirectoryMetadataResult(statuses: nil, permissions: nil, questions: nil)
        }
        let isV2 = connection.openCodeCompatibility?.profile == .v2
        let owner = viewModel.directoryStoreRegistry.store(for: directory)
        let revisions = (owner.statusRevision, owner.permissionRevision, owner.questionRevision)
        let task = Task {
            if isV2 {
                async let statuses = try? await client.listV2SessionStatuses()
                async let permissions = try? await client.listV2PendingPermissions(directory: directory)
                async let forms = try? await client.listV2PendingForms(directory: directory)
                return await DirectoryMetadataResult(
                    statuses: statuses,
                    permissions: permissions,
                    questions: nil,
                    forms: forms,
                    statusRevision: revisions.0, permissionRevision: revisions.1, questionRevision: revisions.2
                )
            }
            async let statuses = try? await client.listSessionStatuses(directory: directory)
            async let permissions = try? await client.listPermissions(directory: directory)
            async let questions = try? await client.listQuestions(directory: directory)
            return await DirectoryMetadataResult(
                statuses: statuses,
                permissions: permissions,
                questions: questions,
                statusRevision: revisions.0, permissionRevision: revisions.1, questionRevision: revisions.2
            )
        }
        directoryMetadataTasks[key] = task
        let result = await task.value
        return result
    }

    private func applyMetadata(
        _ metadata: DirectoryMetadataResult, to store: DirectoryStore,
        statusRevision: UInt, permissionRevision: UInt, questionRevision: UInt
    ) {
        let knownSessionIDs = Set(store.sessions.map(\.id))
        let requestedStatusRevision = metadata.statusRevision ?? statusRevision
        let requestedPermissionRevision = metadata.permissionRevision ?? permissionRevision
        let requestedQuestionRevision = metadata.questionRevision ?? questionRevision
        if let statuses = metadata.statuses {
            store.applyV2ActiveStatuses(statuses, requestedAtRevision: requestedStatusRevision)
        }
        if let permissions = metadata.permissions {
            _ = store.applyPermissions(permissions.filter { knownSessionIDs.contains($0.sessionID) }, ifUnchangedSince: requestedPermissionRevision)
        }
        if let forms = metadata.forms, store.questionRevision == requestedQuestionRevision {
            let sessionIDs = knownSessionIDs
                .union(store.v2FormsByID.values.map(\.sessionID))
            for id in sessionIDs {
                store.applyV2SessionInteractions(sessionID: id,
                    permissions: store.syncState.permissionsBySessionID[id] ?? [], forms: forms.filter { knownSessionIDs.contains($0.sessionID) },
                    permissionRevisionAtRequestStart: store.permissionRevision,
                    questionRevisionAtRequestStart: store.questionRevision)
            }
        } else if let questions = metadata.questions {
            _ = store.applyQuestions(questions.filter { knownSessionIDs.contains($0.sessionID) }, ifUnchangedSince: requestedQuestionRevision)
        }
    }

    private func recentCandidates() -> [RecentProjectSession] {
        let hiddenIDs = viewModel.hiddenProjectActionSessionIDs
        let recent = viewModel.sessionListStore.recentProjectSessions(
            projects: viewModel.projects,
            previews: viewModel.sessionPreviews,
            statuses: [:],
            hiddenActionSessionIDs: hiddenIDs,
            limit: Int.max
        )
        var candidates = Dictionary(recent.map { ($0.session.id, $0) }, uniquingKeysWith: { first, _ in first })
        for scope in viewModel.homeSessionScopes {
            guard let store = viewModel.directoryStoreRegistry.existingStore(for: scope.directory),
                  let project = viewModel.projects.first(where: { $0.id == scope.projectID }) else { continue }
            for session in store.sessions where session.isRootSession && !session.isArchived {
                let attributed = candidates[session.id].map { self.session(session, preservingAttributionFrom: $0.session) } ?? session
                candidates[session.id] = RecentProjectSession(session: attributed, projectTitle: projectTitle(project),
                    preview: viewModel.sessionPreviews[session.id], isBusy: false)
            }
        }
        return candidates.values.filter {
            !hiddenIDs.contains($0.session.id) && !viewModel.directoryStoreRegistry.isV2SessionDeleted($0.session.id)
        }
    }

    private func makeSnapshot() -> Snapshot {
        let rows = recentCandidates().map(makeRow)
        let sessionIDs = Set(rows.map { $0.recent.session.id })
        cachedPreviews = cachedPreviews.filter { sessionIDs.contains($0.key.sessionID) }
        cachedInteractionCounts = cachedInteractionCounts.filter { sessionIDs.contains($0.key.sessionID) }
        let sortedRows = rows.sorted { lhs, rhs in
            if lhs.needsInput != rhs.needsInput { return lhs.needsInput }
            if lhs.isWorking != rhs.isWorking { return lhs.isWorking }
            let lhsTime = lhs.latestUserMessageAt?.timeIntervalSince1970 ?? 0
            let rhsTime = rhs.latestUserMessageAt?.timeIntervalSince1970 ?? 0
            if lhsTime != rhsTime { return lhsTime > rhsTime }
            return lhs.id < rhs.id
        }

        return Snapshot(
            projects: projectFilters(rows: sortedRows),
            needsInputRows: sortedRows.filter(\.needsInput),
            workingRows: sortedRows.filter { !$0.needsInput && $0.isWorking },
            recentRows: sortedRows.filter { !$0.needsInput && !$0.isWorking },
            isLoading: !hasCompletedInitialCacheHydration
                || ((isPreparing || viewModel.sessionListStore.isLoadingRecentProjectSessions) && sortedRows.isEmpty),
            isReadOnly: viewModel.isBrowsingLocalCache,
            showsLastUserMessage: viewModel.appCustomizationStore.showsActivityLastUserMessage,
            selectedSessionID: viewModel.selectedSession?.id
        )
    }

    private func makeRow(_ candidate: RecentProjectSession) -> RowSnapshot {
        let owner = viewModel.directoryStoreRegistry.ownerStore(forSessionID: candidate.session.id)
        let storedSession = owner?.sessions.first { $0.id == candidate.session.id }
            ?? (owner?.selectedSession?.id == candidate.session.id ? owner?.selectedSession : nil)
        let session = session(storedSession ?? candidate.session, preservingAttributionFrom: candidate.session)
        let status = owner?.sessionStatuses[session.id] ?? owner?.syncState.sessionStatusesBySessionID[session.id]
        let messages = owner?.syncState.messagesBySessionID[session.id] ?? []
        let latestUserMessage = messages.last { $0.role?.lowercased() == "user" }
        let isWorking = status.map { $0 != "idle" } ?? false
        let liveRecent = RecentProjectSession(
            session: session,
            projectTitle: candidate.projectTitle,
            preview: candidate.preview,
            isBusy: isWorking
        )
        let latestUserText = latestText(in: messages, owner: owner, sessionID: session.id, role: "user")
        let latestAssistantText = latestText(in: messages, owner: owner, sessionID: session.id, role: "assistant") ?? candidate.preview?.text
        let lastPart = messages.last.flatMap { owner?.syncState.partsByMessageID[$0.id]?.last }
        let runningTools = runningToolSnapshots(part: lastPart, messageID: messages.last?.id)
        let todos = owner?.syncState.todosBySessionID[session.id] ?? []
        let project = project(for: session)
        let interactionOwner = owner
            ?? viewModel.directoryStoreRegistry.existingStore(for: monitoringDirectory(for: session))
        let counts = interactionCounts(sessionID: session.id, owner: interactionOwner)
        let questionCount = counts.questions
        let permissionCount = counts.permissions
        let pendingInteractionCount = permissionCount + questionCount

        return RowSnapshot(
            recent: liveRecent,
            projectID: project?.id ?? (session.isGlobalScopeSession ? "global" : session.projectID ?? session.directory ?? "global"),
            projectIcon: project?.icon,
            usesGlobalProjectAvatar: project?.id == "global" || session.isGlobalScopeSession,
            needsInput: pendingInteractionCount > 0,
            isWorking: isWorking,
            statusTitle: statusTitle(
                status: status,
                permissionCount: permissionCount,
                questionCount: questionCount
            ),
            latestUserText: latestUserText,
            latestAssistantText: latestAssistantText,
            runningTools: runningTools,
            updatedAt: dateFromMilliseconds(session.time?.updated ?? session.time?.created) ?? candidate.preview?.date,
            latestUserMessageAt: dateFromMilliseconds(
                latestUserMessage?.time?.created
                    ?? latestUserMessage?.time?.updated
                    ?? session.time?.created
            ),
            pendingInteractionCount: pendingInteractionCount,
            completedTodoCount: todos.lazy.filter { $0.status == "completed" }.count,
            todoCount: todos.count,
            isLiveActivityActive: viewModel.liveActivityFacade.isActive(sessionID: session.id),
            isHydrating: hydratingSessionIDs.contains(session.id),
            hydrationGeneration: hydrationGeneration
        )
    }

    private func projectFilters(rows: [RowSnapshot]) -> [ProjectFilterSnapshot] {
        var filters = viewModel.projects.map { project in
            ProjectFilterSnapshot(
                id: project.id,
                title: projectTitle(project),
                icon: project.icon,
                usesGlobalAvatar: project.id == "global"
            )
        }
        var knownIDs = Set(filters.map(\.id))
        for row in rows where knownIDs.insert(row.projectID).inserted {
            filters.append(
                ProjectFilterSnapshot(
                    id: row.projectID,
                    title: row.recent.projectTitle,
                    icon: row.projectIcon,
                    usesGlobalAvatar: row.usesGlobalProjectAvatar
                )
            )
        }
        return filters.sorted { lhs, rhs in
            if lhs.id == "global" { return true }
            if rhs.id == "global" { return false }
            return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
        }
    }

    private func projectTitle(_ project: OpenCodeProject) -> String {
        if let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if project.id == "global" { return String(localized: "Global") }
        let title = URL(fileURLWithPath: project.worktree).lastPathComponent
        return title.isEmpty ? project.id : title
    }

    private func project(for session: OpenCodeSession) -> OpenCodeProject? {
        if session.projectID == "global" {
            return viewModel.projects.first { $0.id == "global" }
        }
        if let directory = session.directory,
           let project = viewModel.projects.first(where: { $0.worktree == directory }) {
            return project
        }
        if let projectID = session.projectID,
           let project = viewModel.projects.first(where: { $0.id == projectID }) {
            return project
        }
        guard let directory = session.directory else {
            return viewModel.projects.first(where: { $0.id == "global" })
        }
        return viewModel.projects.first { ($0.sandboxes ?? []).contains(directory) }
    }

    private func monitoringDirectory(for session: OpenCodeSession) -> String? {
        let resolvedProject = project(for: session)
        return resolvedProject?.id == "global" ? nil : session.directory
    }

    private func session(_ session: OpenCodeSession, preservingAttributionFrom candidate: OpenCodeSession) -> OpenCodeSession {
        guard candidate.projectID == "global", session.projectID != "global" else { return session }
        var attributed = OpenCodeSession(
            id: session.id,
            title: session.title,
            workspaceID: session.workspaceID,
            directory: session.directory,
            projectID: "global",
            parentID: session.parentID
        )
        attributed.time = session.time
        return attributed
    }

    private func latestText(in messages: [OpenCodeMessage], owner: DirectoryStore?, sessionID: String, role: String) -> String? {
        let key = PreviewKey(sessionID: sessionID, role: role)
        for message in messages.reversed() where message.role?.lowercased() == role {
            let parts = owner?.syncState.partsByMessageID[message.id] ?? []
            var textParts = parts.filter { $0.type == "text" }.compactMap(\.text)
            if textParts.isEmpty { textParts = parts.filter { $0.type == "reasoning" }.compactMap(\.text) }
            guard !textParts.isEmpty else { continue }
            if let cached = cachedPreviews[key], cached.messageID == message.id, cached.textParts == textParts {
                if let text = cached.text { return text }
                continue
            }
            let text = opencodePreviewText(textParts.joined(separator: " "), limit: nil)
            cachedPreviews[key] = CachedPreview(messageID: message.id, textParts: textParts, text: text)
            if let text { return text }
        }
        return nil
    }

    private func interactionCounts(sessionID: String, owner: DirectoryStore?) -> (permissions: Int, questions: Int) {
        guard let owner else { return (0, 0) }
        let key = InteractionKey(ownerID: ObjectIdentifier(owner), sessionID: sessionID)
        if let cached = cachedInteractionCounts[key] { return cached }
        let forms = SessionInteractionStore.forms(forSessionTreeRootID: sessionID, sessions: owner.sessions,
            forms: Array(owner.sessionFormStore.forms.values))
        let formKeys = Set(forms.map(\.key))
        let questions = SessionInteractionStore.questions(forSessionTreeRootID: sessionID, sessions: owner.sessions,
            questionsBySessionID: owner.syncState.questionsBySessionID)
            .filter { !formKeys.contains(.init(sessionID: $0.sessionID, formID: $0.id)) }.count + forms.count
        let permissions = SessionInteractionStore.permissions(forSessionTreeRootID: sessionID, sessions: owner.sessions,
            permissionsBySessionID: owner.syncState.permissionsBySessionID).count
        cachedInteractionCounts[key] = (permissions, questions)
        return (permissions, questions)
    }

    private func runningToolSnapshots(part: OpenCodePart?, messageID: String?) -> [ToolSnapshot] {
        guard let part,
              let tool = part.tool,
              isRunningToolStatus(part.state?.status) else { return [] }
        return [
            ToolSnapshot(
                id: part.id ?? part.callID ?? "\(messageID ?? ""):\(tool)",
                tool: tool,
                title: toolTitle(part: part, tool: tool),
                detail: toolDetail(part.state?.input)
            ),
        ]
    }

    private func isRunningToolStatus(_ status: String?) -> Bool {
        switch status?.lowercased() {
        case "running", "pending", "in_progress":
            return true
        default:
            return false
        }
    }

    private func toolTitle(part: OpenCodePart, tool: String) -> String {
        if let title = part.state?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            return title
        }
        return String(localized: "Running \(tool.replacingOccurrences(of: "_", with: " ").capitalized)")
    }

    private func toolDetail(_ input: OpenCodeToolInput?) -> String? {
        [
            input?.description,
            input?.command,
            input?.path,
            input?.filePath,
            input?.query,
            input?.pattern,
            input?.url,
        ]
        .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        .first { !$0.isEmpty }
    }

    private func statusTitle(status: String?, permissionCount: Int, questionCount: Int) -> String {
        if permissionCount + questionCount > 0 { return String(localized: "Needs input") }
        switch status {
        case "busy":
            return String(localized: "Working")
        case "retry":
            return String(localized: "Retrying")
        case .some(let status) where status != "idle":
            return String(localized: "Working")
        default:
            return String(localized: "Idle")
        }
    }

    private func dateFromMilliseconds(_ value: Double?) -> Date? {
        value.map { Date(timeIntervalSince1970: $0 / 1_000) }
    }

    private func bindMonitoredStores() {
        let keys = Set(viewModel.homeSessionScopes.map { DirectoryStoreRegistry.key(for: $0.directory) })
            .union(recentCandidates().map { DirectoryStoreRegistry.key(for: monitoringDirectory(for: $0.session)) })
        let stores = keys.compactMap { key in
            viewModel.directoryStoreRegistry.existingStore(
                for: DirectoryStoreRegistry.directory(forKey: key)
            )
        }
        let ids = Set(stores.map(ObjectIdentifier.init))
        guard ids != monitoredStoreIDs else { return }
        monitoredStoreIDs = ids
        monitoredStoreObservations.removeAll()
        for store in stores {

            store.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
                .store(in: &monitoredStoreObservations)
            store.syncStore.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.scheduleSnapshotRefresh() }
                .store(in: &monitoredStoreObservations)
        }
    }

    private func scheduleSnapshotRefresh() {
        guard snapshotRefreshTask == nil else { return }
        snapshotRefreshTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, !Task.isCancelled else { return }
            snapshotRefreshTask = nil
            let metadata = makePresentationMetadata()
            let metadataChanged = metadata != presentationMetadata
            let remaining = Duration.milliseconds(200) - lastSnapshotRefresh.duration(to: .now)
            if metadataChanged || remaining <= .zero {
                refreshSnapshot()
            } else if previewRefreshTask == nil {
                // A throttle with a trailing refresh, not a debounce: continuous tokens
                // cannot indefinitely postpone the latest preview or its final text.
                previewRefreshTask = Task { @MainActor [weak self] in
                    try? await Task.sleep(for: remaining)
                    guard let self, !Task.isCancelled else { return }
                    previewRefreshTask = nil
                    refreshSnapshot()
                }
            }
        }
    }

    private func makePresentationMetadata() -> PresentationMetadata {
        let directories = Dictionary(uniqueKeysWithValues: viewModel.directoryStoreRegistry.allStores.map { store in
            (ObjectIdentifier(store), DirectoryPresentationMetadata(sessions: store.sessions,
                statuses: store.sessionStatuses, syncStatuses: store.syncState.sessionStatusesBySessionID,
                todos: store.syncState.todosBySessionID, permissions: store.syncState.permissionsBySessionID,
                questions: store.syncState.questionsBySessionID, forms: store.sessionFormStore.forms))
        })
        return PresentationMetadata(directories: directories, scopes: viewModel.homeSessionScopes,
            projects: viewModel.projects, recentSessions: viewModel.sessionListStore.recentSessionsByDirectory,
            hiddenIDs: viewModel.hiddenProjectActionSessionIDs, liveActivityIDs: viewModel.activeLiveActivitySessionIDs,
            lifecycleRevisions: viewModel.directoryStoreRegistry.v2LifecycleSnapshot,
            selectedSessionID: viewModel.selectedSession?.id, isReadOnly: viewModel.isBrowsingLocalCache,
            showsLastUserMessage: viewModel.appCustomizationStore.showsActivityLastUserMessage,
            isLoadingRecentSessions: viewModel.sessionListStore.isLoadingRecentProjectSessions)
    }

    private func refreshSnapshot() {
        previewRefreshTask?.cancel()
        previewRefreshTask = nil
        lastSnapshotRefresh = .now
        let metadata = makePresentationMetadata()
        // Also rebind on a trailing or synchronous refresh. Either can run before
        // the coalesced notification for a newly discovered directory.
        if metadata != presentationMetadata { bindMonitoredStores() }
        if metadata.directories != presentationMetadata?.directories { cachedInteractionCounts = [:] }
        presentationMetadata = metadata
        let nextSnapshot = makeSnapshot()
        if snapshot != nextSnapshot {
            snapshot = nextSnapshot
        }
        scheduleRecentPreloads()
    }
}
