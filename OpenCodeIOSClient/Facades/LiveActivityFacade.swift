import Combine
import Foundation

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit
#endif

@MainActor
final class LiveActivityFacade: ObservableObject {
    private static let refreshDelay: Duration = .milliseconds(350)

    private unowned let viewModel: AppViewModel
    private weak var liveActivityBackgroundBridge: LiveActivityBackgroundBridge?
    private var observations: Set<AnyCancellable> = []
    struct PendingDeepLink {
        let id = UUID()
        let link: LiveActivityDeepLink
        let config: OpenCodeServerConfig
        var operationID: UUID?
    }
    private(set) var pendingDeepLink: PendingDeepLink?
    var connectForRestoration: (@MainActor (OpenCodeServerConfig) async -> Void)?
    var navigateForRestoration: (@MainActor (OpenCodeSession) async -> Void)?
    #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
    private var activityRecords: @MainActor () -> [LiveActivityRecord] = { LiveActivityCoordinator.records() }
    private var updateActivity: @MainActor (OpenCodeLiveActivityIdentity, String?, OpenCodeChatActivityAttributes.ContentState) async -> Void = {
        await LiveActivityCoordinator.update(identity: $0, activityID: $1, state: $2)
    }
    private var endActivity: @MainActor (OpenCodeLiveActivityIdentity, String?, OpenCodeChatActivityAttributes.ContentState, Bool) async -> Void = {
        await LiveActivityCoordinator.end(identity: $0, activityID: $1, state: $2, immediate: $3)
    }
    private var requestOrUpdate: @MainActor (LiveActivityStartRequest) async throws -> Void = {
        try await LiveActivityCoordinator.requestOrUpdate($0)
    }

    convenience init(
        viewModel: AppViewModel,
        requestOrUpdate: @escaping @MainActor (LiveActivityStartRequest) async throws -> Void,
        activityRecords: @escaping @MainActor () -> [LiveActivityRecord] = { LiveActivityCoordinator.records() },
        updateActivity: @escaping @MainActor (OpenCodeLiveActivityIdentity, String?, OpenCodeChatActivityAttributes.ContentState) async -> Void = {
            await LiveActivityCoordinator.update(identity: $0, activityID: $1, state: $2)
        },
        endActivity: @escaping @MainActor (OpenCodeLiveActivityIdentity, String?, OpenCodeChatActivityAttributes.ContentState, Bool) async -> Void = {
            await LiveActivityCoordinator.end(identity: $0, activityID: $1, state: $2, immediate: $3)
        }
    ) {
        self.init(viewModel: viewModel)
        self.requestOrUpdate = requestOrUpdate
        self.activityRecords = activityRecords
        self.updateActivity = updateActivity
        self.endActivity = endActivity
    }
    #endif

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        Publishers.MergeMany([
            viewModel.liveActivityStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.directoryStoreRegistry.objectWillChange.eraseToAnyPublisher(),
            viewModel.sessionListStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.sessionInteractionStore.objectWillChange.eraseToAnyPublisher(),
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)
        viewModel.$backendConnection.dropFirst().sink { [weak self] connection in
            guard let self, let connection, let pending = pendingDeepLink else { return }
            guard let adapter = connection.openCodeCompatibility,
                  adapter.profile.rawValue == pending.link.owner?.profile.rawValue,
                  Self.sameDestination(adapter.client.config, pending.config) else {
                pendingDeepLink = nil
                return
            }
        }.store(in: &observations)
    }

    private static func sameDestination(_ lhs: OpenCodeServerConfig, _ rhs: OpenCodeServerConfig) -> Bool {
        lhs.trimmedBaseURL == rhs.trimmedBaseURL && lhs.trimmedUsername == rhs.trimmedUsername
            && lhs.apiPreference == rhs.apiPreference
    }

    func connectionWillStart(config: OpenCodeServerConfig) {
        guard let pending = pendingDeepLink else { return }
        if Self.sameDestination(config, pending.config) {
            pendingDeepLink?.operationID = nil
        } else {
            pendingDeepLink = nil
        }
    }

    func discardPendingDeepLink() { pendingDeepLink = nil }

    func savedDestination(for link: LiveActivityDeepLink) -> OpenCodeServerConfig? {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let owner = link.owner else { return nil }
        if case .question = link.action, owner.profile != .legacy { return nil }
        guard let attributes = restorationAttributes(for: link),
              LiveActivityCoordinator.normalizedDirectory(attributes.directory) == LiveActivityCoordinator.normalizedDirectory(link.directory),
              attributes.workspaceID == link.workspaceID else { return nil }
        let saved = viewModel.recentServerConfigs.filter {
            $0.recentServerID == owner.serverID && $0.trimmedBaseURL == attributes.serverBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
                && $0.trimmedUsername == attributes.serverUsername.trimmingCharacters(in: .whitespacesAndNewlines)
                && ($0.apiPreference == .automatic || $0.apiPreference.rawValue == owner.profile.rawValue)
        }
        guard saved.count == 1 else { return nil }
        return saved.first
        #else
        return nil
        #endif
    }

    func restorationScope(for link: LiveActivityDeepLink) -> BackendScope? {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let attributes = restorationAttributes(for: link) else { return nil }
        return .init(projectID: attributes.projectID, directory: attributes.requestDirectory, workspaceID: attributes.workspaceID)
        #else
        return nil
        #endif
    }

    func matchesRestoredSession(_ session: OpenCodeSession, link: LiveActivityDeepLink) -> Bool {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let attributes = restorationAttributes(for: link), session.id == attributes.sessionID,
              session.workspaceID == attributes.workspaceID,
              attributes.projectID == nil || attributes.projectID == session.projectID else { return false }
        if attributes.projectID == nil, attributes.directory == nil {
            // Old legacy global activities omitted location. This is evidence of global
            // scope only after a canonical read, never a wildcard for another project.
            return attributes.identity?.owner.profile == .legacy && session.projectID == "global"
        }
        return attributes.directory == session.directory
        #else
        return false
        #endif
    }

    #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
    private func restorationAttributes(for link: LiveActivityDeepLink) -> OpenCodeChatActivityAttributes? {
        guard let owner = link.owner else { return nil }
        let records = activityRecords().filter {
            $0.attributes.matches(owner.session(link.sessionID), activityID: link.activityID, actualActivityID: $0.id)
        }
        guard records.count == 1 else { return nil }
        return records.first?.attributes
    }
    #endif

    func handleDeepLink(_ url: URL) async {
        guard !Task.isCancelled else { return }
        pendingDeepLink = nil
        guard let link = LiveActivityCoordinator.deepLink(from: url), let saved = savedDestination(for: link) else { return }
        pendingDeepLink = PendingDeepLink(link: link, config: saved)
        let pendingID = pendingDeepLink?.id
        if viewModel.connectionStore.isLoading || (viewModel.connectionAttemptID != nil
            && (!viewModel.isConnected || viewModel.connectionAttemptTask != nil)) {
            // The connection completion path drains this request. Never hijack another attempt.
            if !Self.sameDestination(viewModel.config, saved) { pendingDeepLink = nil }
            return
        }
        if !viewModel.isConnected || !accepts(link) || !Self.sameDestination(viewModel.config, saved) {
            guard viewModel.backendFactory == nil || connectForRestoration != nil else {
                pendingDeepLink = nil
                return
            }
            if let connectForRestoration { await connectForRestoration(saved) }
            else { await viewModel.connect(to: saved) }
        }
        guard pendingDeepLink?.id == pendingID else { return }
        await resumePendingDeepLink()
    }

    func resumePendingDeepLink() async {
        guard let pending = pendingDeepLink, pending.operationID == nil,
              !viewModel.connectionStore.isLoading else { return }
        guard viewModel.isConnected, let lifetime = currentLifetime,
              accepts(pending.link), Self.sameDestination(viewModel.config, pending.config),
              let saved = savedDestination(for: pending.link), Self.sameDestination(saved, pending.config),
              let connection = viewModel.backendConnection,
              let adapter = connection.openCodeCompatibility, Self.sameDestination(adapter.client.config, saved) else {
            pendingDeepLink = nil
            return
        }
        let operation = UUID()
        pendingDeepLink?.operationID = operation
        defer {
            if pendingDeepLink?.id == pending.id, pendingDeepLink?.operationID == operation { pendingDeepLink = nil }
        }
        await viewModel.openLiveActivitySession(pending.link, lifetime: lifetime) { [weak self] in
            guard let self else { return false }
            return pendingDeepLink?.id == pending.id && pendingDeepLink?.operationID == operation
                && isCurrent(lifetime) && accepts(pending.link)
                && viewModel.isConnected && !viewModel.connectionStore.isLoading
                && Self.sameDestination(viewModel.config, pending.config)
                && savedDestination(for: pending.link).map { Self.sameDestination($0, pending.config) } == true
        }
    }

    func attachLiveActivityBackgroundBridge(_ bridge: LiveActivityBackgroundBridge) {
        liveActivityBackgroundBridge = bridge
    }

    func armBackgroundBridge(sessionID: String) -> LiveActivityBackgroundBridge.Intent? {
        guard let lifetime = currentLifetime, startConfig != nil else { return nil }
        liveActivityBackgroundBridge?.bind(lifetime)
        return liveActivityBackgroundBridge?.arm(sessionID: sessionID)
    }

    func consumeBackgroundEvent(_ event: OpenCodeTypedEvent, lifetime: LiveActivityStore.Lifetime?) {
        liveActivityBackgroundBridge?.consume(event, lifetime: lifetime)
    }

    func consumeBackgroundEvent(_ event: OpenCodeV2ManagedEvent, lifetime: LiveActivityStore.Lifetime?) {
        guard let sessionID = event.sessionID else { return }
        if event.type == "session.deleted" {
            liveActivityBackgroundBridge?.cancel(sessionID: sessionID, reason: "Session deleted", lifetime: lifetime)
            Task { [weak self] in
                guard let self, let lifetime, isCurrent(lifetime) else { return }
                await stop(sessionID: sessionID, immediate: true)
            }
        } else if event.isExecutionTerminal {
            liveActivityBackgroundBridge?.consume(.sessionIdle(sessionID: sessionID), lifetime: lifetime)
        }
    }

    func accepts(_ deepLink: LiveActivityDeepLink) -> Bool {
        guard supportsLiveActivities, let owner, deepLink.owner == owner else { return false }
        // V2 forms are opened in the app, never converted to legacy question answers.
        if case .question = deepLink.action, owner.profile != .legacy { return false }
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        if let activityID = deepLink.activityID {
            return activityRecords().contains { $0.attributes.matches(owner.session(deepLink.sessionID), activityID: activityID, actualActivityID: $0.id) }
        }
        #endif
        return true
    }

    var owner: OpenCodeLiveActivityOwner? { currentLifetime?.owner }
    var supportsLiveActivities: Bool { currentLifetime != nil && startConfig != nil }

    var currentLifetime: LiveActivityStore.Lifetime? {
        if let connection = viewModel.backendConnection {
            guard !connection.isClosed, let compatibility = connection.openCodeCompatibility else { return nil }
            let profile: OpenCodeProfileIdentity = compatibility.profile == .v2 ? .v2 : .legacy
            return .init(owner: .init(profile: profile, serverID: compatibility.client.config.recentServerID),
                         connectionID: connection.id, generation: viewModel.directoryStoreRegistry.generation)
        }
        guard viewModel.isConnected || viewModel.isUsingAppleIntelligence,
              let config = startConfig else { return nil }
        return .init(owner: .init(profile: .legacy, serverID: config.recentServerID),
                     connectionID: nil, generation: viewModel.directoryStoreRegistry.generation)
    }

    private func isCurrent(_ lifetime: LiveActivityStore.Lifetime) -> Bool {
        !Task.isCancelled && currentLifetime == lifetime
    }

    var activeSessionIDs: Set<String> {
        guard let lifetime = currentLifetime, viewModel.liveActivityStore.lifetime == lifetime else { return [] }
        return viewModel.activeLiveActivitySessionIDs
    }

    func isActive(sessionID: String) -> Bool {
        activeSessionIDs.contains(sessionID)
    }

    func toggle(session: OpenCodeSession, reportError: (@MainActor (String?) -> Void)? = nil) async {
        if isActive(sessionID: session.id) {
            await stop(sessionID: session.id, immediate: true)
        } else {
            await start(session: session, reportError: reportError)
        }
    }

    func start(session: OpenCodeSession, userVisibleErrors: Bool = true, reportError: (@MainActor (String?) -> Void)? = nil) async {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let config = startConfig, let lifetime = currentLifetime else { return }
        viewModel.liveActivityStore.bind(lifetime)
        let operation = viewModel.liveActivityStore.beginOperation(sessionID: session.id)
        do {
            let state = state(for: session)
            try await requestOrUpdate(
                LiveActivityStartRequest(
                    sessionID: session.id,
                    sessionTitle: sessionTitle(for: session),
                    credentialID: config.recentServerID,
                    serverBaseURL: config.baseURL,
                    serverUsername: config.username,
                    directory: session.directory,
                    workspaceID: session.workspaceID,
                    state: state,
                    profile: lifetime.owner.profile,
                    activityID: viewModel.liveActivityStore.activityIDsBySessionID[session.id],
                    projectID: session.projectID
                )
            )
            guard isCurrent(lifetime), viewModel.liveActivityStore.owns(operation, sessionID: session.id, lifetime: lifetime) else { return }
            viewModel.activeLiveActivitySessionIDs.insert(session.id)
            viewModel.liveActivityStore.activityIDsBySessionID[session.id] = activityRecords().first { $0.attributes.identity == lifetime.owner.session(session.id) }?.id
            viewModel.liveActivityStore.setLastState(state, for: session.id)
            if userVisibleErrors {
                if let reportError { reportError(nil) }
                else { viewModel.errorMessage = nil }
            }
        } catch {
            guard isCurrent(lifetime), viewModel.liveActivityStore.owns(operation, sessionID: session.id, lifetime: lifetime) else { return }
            if userVisibleErrors {
                if let reportError { reportError(error.localizedDescription) }
                else { viewModel.errorMessage = error.localizedDescription }
            }
        }
        #endif
    }

    private var startConfig: OpenCodeServerConfig? {
        if let connection = viewModel.backendConnection {
            guard connection.openCodeCompatibility != nil,
                  let client = try? connection.requireOpenCodeClient(for: .liveActivities) else { return nil }
            return client.config
        }
        // Never redirect an injected backend to a saved OpenCode server.
        guard viewModel.backendFactory == nil,
              viewModel.backendMode != .serverV2,
              viewModel.connectionStore.apiProfile != .v2,
              viewModel.isUsingAppleIntelligence
                || viewModel.connectionStore.apiProfile == .legacy
                || viewModel.config.apiPreference == .legacy else { return nil }
        return viewModel.config
    }

    func autoStartIfEnabled(session: OpenCodeSession) async {
        guard viewModel.isConnected,
              !viewModel.isUsingAppleIntelligence,
              viewModel.isLiveActivityAutoStartEnabled else { return }
        guard !isActive(sessionID: session.id) else { return }
        await start(session: session, userVisibleErrors: false)
    }

    func reconcile() {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let lifetime = currentLifetime else { return }
        viewModel.liveActivityStore.reconcile(activityRecords().map { ($0.id, $0.attributes, $0.state) }, lifetime: lifetime)
        #endif
    }

    func stop(sessionID: String, immediate: Bool = false) async {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let lifetime = currentLifetime, viewModel.liveActivityStore.lifetime == lifetime else { return }
        let operation = viewModel.liveActivityStore.beginOperation(sessionID: sessionID)
        viewModel.liveActivityStore.cancelRefresh(for: sessionID)
        viewModel.liveActivityStore.cancelPreviewRefresh(for: sessionID)
        viewModel.activeLiveActivitySessionIDs.remove(sessionID)
        let session = sessionSnapshot(for: sessionID)
        if let finalState = session.map({ state(for: $0) }) ?? viewModel.liveActivityStore.lastState(for: sessionID) {
            await endActivity(lifetime.owner.session(sessionID), viewModel.liveActivityStore.activityIDsBySessionID[sessionID], finalState, immediate)
        }
        guard isCurrent(lifetime), viewModel.liveActivityStore.owns(operation, sessionID: sessionID, lifetime: lifetime) else { return }
        viewModel.activeLiveActivitySessionIDs.remove(sessionID)
        viewModel.liveActivityStore.activityIDsBySessionID[sessionID] = nil
        viewModel.liveActivityStore.setLastState(nil, for: sessionID)
        liveActivityBackgroundBridge?.cancel(sessionID: sessionID, reason: "Live Activity stopped", lifetime: lifetime)
        #endif
    }

    func stopAll(immediate: Bool = true) async {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        // Teardown may run after the connection has closed or its directory state
        // has reset. End only the captured OS IDs owned by the outgoing lifetime.
        guard let lifetime = viewModel.liveActivityStore.lifetime else { return }
        let activities = activityRecords().filter { $0.attributes.identity?.owner == lifetime.owner }
        let sessionIDs = viewModel.liveActivityStore.activeSessionIDs.union(activities.map(\.attributes.sessionID))
        let operations = Dictionary(uniqueKeysWithValues: sessionIDs.map { sessionID in
            viewModel.liveActivityStore.cancelRefresh(for: sessionID)
            viewModel.liveActivityStore.cancelPreviewRefresh(for: sessionID)
            return (sessionID, viewModel.liveActivityStore.beginOperation(sessionID: sessionID))
        })
        if isCurrent(lifetime) { viewModel.activeLiveActivitySessionIDs.subtract(sessionIDs) }
        for activity in activities {
            guard !Task.isCancelled else { return }
            await endActivity(lifetime.owner.session(activity.attributes.sessionID), activity.id, activity.state, immediate)
        }
        guard isCurrent(lifetime), viewModel.liveActivityStore.lifetime == lifetime else { return }
        for (sessionID, operation) in operations where viewModel.liveActivityStore.owns(operation, sessionID: sessionID, lifetime: lifetime) {
            viewModel.activeLiveActivitySessionIDs.remove(sessionID)
            viewModel.liveActivityStore.activityIDsBySessionID[sessionID] = nil
            viewModel.liveActivityStore.setLastState(nil, for: sessionID)
            liveActivityBackgroundBridge?.cancel(sessionID: sessionID, reason: "Live Activities stopped", lifetime: lifetime)
        }
        #endif
    }

    func refresh(sessionID: String? = nil, endIfIdle: Bool = false, immediate: Bool = false) {
        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let lifetime = currentLifetime, viewModel.liveActivityStore.lifetime == lifetime else { return }
        if let sessionID, !immediate, !endIfIdle {
            guard isActive(sessionID: sessionID) else { return }
            guard LiveActivitySnapshotBuilder.shouldScheduleRefresh(
                pendingRefreshExists: viewModel.liveActivityStore.hasPendingRefresh(for: sessionID),
                immediate: immediate,
                endIfIdle: endIfIdle
            ) else { return }
            viewModel.liveActivityStore.setRefreshTask(Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.refreshDelay)
                guard let self, isCurrent(lifetime) else { return }
                refresh(sessionID: sessionID, endIfIdle: endIfIdle, immediate: true)
                viewModel.liveActivityStore.clearRefreshTask(for: sessionID)
            }, for: sessionID)
            return
        }

        if sessionID == nil, !immediate, !endIfIdle {
            for activeSessionID in activeSessionIDs {
                refresh(sessionID: activeSessionID)
            }
            return
        }

        Task { @MainActor [weak self] in
            guard let self, isCurrent(lifetime) else { return }
            let targetSessionIDs = sessionID.map { [$0] } ?? Array(activeSessionIDs)
            for targetSessionID in targetSessionIDs {
                guard isCurrent(lifetime) else { return }
                guard isActive(sessionID: targetSessionID),
                      let session = sessionSnapshot(for: targetSessionID) else { continue }
                let state = state(for: session)
                let operation = viewModel.liveActivityStore.beginOperation(sessionID: targetSessionID)
                let activityID = viewModel.liveActivityStore.activityIDsBySessionID[targetSessionID]
                let status = viewModel.directoryStoreRegistry.snapshot(forSessionID: targetSessionID)?.status
                    ?? viewModel.sessionStatuses[targetSessionID]
                if endIfIdle && status == "idle" {
                    viewModel.activeLiveActivitySessionIDs.remove(targetSessionID)
                    await endActivity(lifetime.owner.session(targetSessionID), activityID, state, false)
                    guard isCurrent(lifetime), viewModel.liveActivityStore.owns(operation, sessionID: targetSessionID, lifetime: lifetime) else { return }
                    viewModel.activeLiveActivitySessionIDs.remove(targetSessionID)
                    viewModel.liveActivityStore.setLastState(nil, for: targetSessionID)
                    continue
                }
                if let previousState = viewModel.liveActivityStore.lastState(for: targetSessionID),
                   LiveActivitySnapshotBuilder.statesMatch(previousState, state) {
                    continue
                }
                await updateActivity(lifetime.owner.session(targetSessionID), activityID, state)
                guard isCurrent(lifetime), viewModel.liveActivityStore.owns(operation, sessionID: targetSessionID, lifetime: lifetime) else { return }
                viewModel.liveActivityStore.setLastState(state, for: targetSessionID)
            }
        }
        #endif
    }

    func consumeReducerEvent(
        _ event: OpenCodeTypedEvent,
        result: SessionEventResult,
        sessionID: String?,
        eventType: String
    ) {
        if case let .sessionDeleted(session) = event, isActive(sessionID: session.id) {
            let lifetime = currentLifetime
            Task { [weak self] in
                guard let self, let lifetime, isCurrent(lifetime) else { return }
                await stop(sessionID: session.id, immediate: true)
            }
            return
        }

        guard let sessionID, isActive(sessionID: sessionID) else { return }
        let interactionChanged: Bool
        switch result {
        case .permissionChanged, .questionChanged:
            interactionChanged = true
        default:
            interactionChanged = false
        }
        let messageChanged = EventSyncCoordinator.isLiveActivityMessageEventType(eventType)
        refresh(sessionID: sessionID, immediate: interactionChanged || messageChanged)

        if case .idle = result {
            scheduleCanonicalHydrationIfNeeded(sessionID: sessionID)
        }
    }

    func reducerDidCommit(sessionIDs: Set<String>) {
        for sessionID in sessionIDs where isActive(sessionID: sessionID) {
            refresh(sessionID: sessionID, immediate: true)
        }
    }

    func scheduleCanonicalHydrationIfNeeded(sessionID: String?) {
        guard viewModel.isConnected,
               !viewModel.isUsingAppleIntelligence,
              let sessionID,
              isActive(sessionID: sessionID),
              viewModel.selectedSession?.id != sessionID,
              let session = sessionSnapshot(for: sessionID) else { return }
        let targetGeneration = viewModel.directoryStoreRegistry.generation
        // V2 hydration stays in its revision-guarded runtime projection pipeline.
        guard let lifetime = currentLifetime, lifetime.owner.profile == .legacy else { return }
        let connection = viewModel.backendConnection
        let client = connection?.openCodeCompatibility?.client ?? viewModel.client

        viewModel.liveActivityStore.setPreviewRefreshTask(Task { @MainActor [weak self] in
            guard let self else { return }
            try? await Task.sleep(for: .milliseconds(350))
            guard isCurrent(lifetime) else { return }
            defer {
                if isCurrent(lifetime) { viewModel.liveActivityStore.clearPreviewRefreshTask(for: sessionID) }
            }
            do {
                let messages = try await client.listMessages(sessionID: session.id,
                    directory: session.projectID == "global" ? nil : session.directory)
                guard isCurrent(lifetime), viewModel.directoryStoreRegistry.generation == targetGeneration else { return }
                let owner = viewModel.directoryStoreRegistry.ownerStore(forSessionID: session.id)
                    ?? viewModel.directoryStoreRegistry.store(for: session.directory)
                owner.applyCanonicalMessages(messages, forSessionID: session.id)
                viewModel.chatStore.cacheMessages(messages, forSessionID: session.id)
                viewModel.refreshSessionPreview(for: session.id, messages: messages)
                refresh(sessionID: session.id)
            } catch {
                return
            }
        }, for: sessionID)
    }

    #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
    func transcriptLines(for session: OpenCodeSession) -> [OpenCodeChatActivityLine] {
        LiveActivitySnapshotBuilder.transcriptLines(for: snapshotInput(for: session))
    }

    private func state(for session: OpenCodeSession) -> OpenCodeChatActivityAttributes.ContentState {
        LiveActivitySnapshotBuilder.state(for: snapshotInput(for: session))
    }

    private func snapshotInput(for session: OpenCodeSession) -> LiveActivitySnapshotInput {
        let canonical = viewModel.directoryStoreRegistry.snapshot(forSessionID: session.id)
        let isSelected = viewModel.selectedSession?.id == session.id
        let canonicalMessages = canonical?.messages ?? []
        return LiveActivitySnapshotInput(
            session: session,
            sessionTitle: sessionTitle(for: session),
            selectedSessionID: viewModel.selectedSession?.id,
            selectedMessages: isSelected ? viewModel.messages : canonicalMessages,
            cachedMessages: canonicalMessages.isEmpty
                ? (viewModel.cachedMessagesBySessionID[session.id] ?? [])
                : canonicalMessages,
            sessionStatus: canonical?.status ?? viewModel.sessionStatuses[session.id],
            sessionPreviewText: viewModel.sessionPreviews[session.id]?.text,
            permissions: isSelected ? viewModel.permissions(for: session.id) : (canonical?.permissions ?? []),
            questions: isSelected ? viewModel.questions(for: session.id) : (canonical?.questions ?? []),
            profile: owner?.profile ?? .legacy,
            forms: (viewModel.directoryStoreRegistry.ownerStore(forSessionID: session.id)?.sessionFormStore.forms.values
                .filter { $0.sessionID == session.id } ?? []).sorted { $0.id < $1.id }
        )
    }
    #endif

    private func sessionTitle(for session: OpenCodeSession) -> String {
        let title = viewModel.childSessionTitle(for: session).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(localized: "Session") : title
    }

    private func sessionSnapshot(for sessionID: String) -> OpenCodeSession? {
        if let session = viewModel.directoryStoreRegistry.snapshot(forSessionID: sessionID)?.session
            ?? viewModel.session(matching: sessionID)
            ?? viewModel.sessions.first(where: { $0.id == sessionID })
            ?? (viewModel.selectedSession?.id == sessionID ? viewModel.selectedSession : nil) {
            return session
        }

        #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
        guard let owner, let record = activityRecords().first(where: {
            $0.attributes.matches(owner.session(sessionID), activityID: viewModel.liveActivityStore.activityIDsBySessionID[sessionID], actualActivityID: $0.id)
        }) else { return nil }
        let activitySnapshot = LiveActivitySessionSnapshot(sessionID: sessionID, sessionTitle: record.attributes.sessionTitle,
            workspaceID: record.attributes.workspaceID, directory: record.attributes.directory, projectID: record.attributes.projectID)
        return LiveActivityCoordinator.resolveSession(
            sessionID: sessionID,
            directory: nil,
            workspaceID: nil,
            knownSessions: [],
            selectedSession: nil,
            activitySnapshot: activitySnapshot
        ).session
        #else
        return nil
        #endif
    }
}
