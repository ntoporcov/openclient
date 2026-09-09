import Foundation

private extension ContinuousClock.Instant {
    var elapsedMilliseconds: Double {
        let duration = self.duration(to: ContinuousClock.now)
        return Double(duration.components.seconds) * 1_000 + Double(duration.components.attoseconds) / 1e15
    }
}

private extension Duration {
    var elapsedMilliseconds: Int {
        let components = self.components
        return Int(Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15)
    }
}

final class OpenCodeEventInterestSnapshot: @unchecked Sendable {
    private struct Snapshot {
        var selectedSessionID: String?
        var activeChatSessionID: String?
        var windowSessionIDs: Set<String> = []
    }

    private let lock = NSLock()
    private var snapshot = Snapshot()

    func update(selectedSessionID: String?, activeChatSessionID: String?, windowSessionIDs: Set<String> = []) {
        lock.lock()
        snapshot = Snapshot(selectedSessionID: selectedSessionID, activeChatSessionID: activeChatSessionID, windowSessionIDs: windowSessionIDs)
        lock.unlock()
    }

    func shouldDeliverToMainActor(_ managed: OpenCodeManagedEvent) -> Bool {
        guard EventSyncCoordinator.isLiveActivityMessageEventType(managed.envelope.type) else {
            return true
        }

        guard let sessionID = Self.sessionID(for: managed.typed) else {
            return true
        }

        lock.lock()
        let current = snapshot
        lock.unlock()

        return sessionID == current.activeChatSessionID || sessionID == current.selectedSessionID || current.windowSessionIDs.contains(sessionID)
    }

    private static func sessionID(for event: OpenCodeTypedEvent) -> String? {
        switch event {
        case let .sessionCreated(session), let .sessionUpdated(session), let .sessionDeleted(session):
            return session.id
        case let .sessionStatus(sessionID, _), let .sessionIdle(sessionID), let .sessionDiff(sessionID, _), let .todoUpdated(sessionID, _), let .messageRemoved(sessionID, _), let .messagePartDelta(sessionID, _, _, _, _), let .permissionReplied(sessionID, _, _), let .questionReplied(sessionID, _), let .questionRejected(sessionID, _):
            return sessionID
        case let .sessionError(sessionID, _):
            return sessionID
        case let .messageUpdated(info):
            return info.sessionID
        case let .messagePartUpdated(part):
            return part.sessionID
        case let .permissionAsked(permission):
            return permission.sessionID
        case let .questionAsked(question):
            return question.sessionID
        default:
            return nil
        }
    }
}

extension AppViewModel {
    private static let shortStreamDeltaCoalescingInterval: Duration = .milliseconds(80)
    private static let mediumStreamDeltaCoalescingInterval: Duration = .milliseconds(120)
    private static let longStreamDeltaCoalescingInterval: Duration = .milliseconds(180)
    private static let veryLongStreamDeltaCoalescingInterval: Duration = .milliseconds(260)
    private static let burstFlushEventCount = 8
    private static let burstFlushCharacterCount = 64
    private static let immediateBurstFlushEventCount = 16
    private static let immediateBurstFlushCharacterCount = 128
    private static let burstFlushMinimumAgeMS = 40

    var isCapturingStreamingDiagnostics: Bool {
        isShowingDebugProbe || isRunningDebugProbe
    }

    func setComposerStreamingFocus(_ isFocused: Bool) {
        guard isComposerStreamingFocused != isFocused else { return }
        isComposerStreamingFocused = isFocused

        if !isFocused {
            flushBufferedTranscript(reason: "composer blur")
        }
    }

    func updateEventInterestSnapshot() {
        eventInterestSnapshot.update(
            selectedSessionID: selectedSession?.id,
            activeChatSessionID: activeChatSessionID,
            windowSessionIDs: Set(windowSessionInterests.values)
        )
    }

    func flushBufferedTranscript(reason: String) {
        flushPendingTranscriptEvents(reason: reason)
    }

    func startDebugProbe() async {
        guard let selectedSession else { return }

        stopDebugProbeStreams()
        debugProbeLog = []
        isRunningDebugProbe = true
        appendDebugLog("probe started for \(selectedSession.id)")
        stopEventStream()
        startEventStream()
        appendDebugLog("probe using shared app event stream")
        appendDebugLog("probe prompt: \(debugProbePrompt)")
        await sendMessage(debugProbePrompt, in: selectedSession, userVisible: true)
    }

    func copyDebugProbeLog() -> String {
        debugProbeLog.joined(separator: "\n")
    }

    func presentDebugProbe() {
        isShowingDebugProbe = true
    }

    func startEventStream() {
        if let backendConnection {
            startBackendEventStream(backendConnection)
            return
        }
        guard backendFactory == nil else { return }
        if connectionStore.apiProfile == .v2 {
            startV2EventStream()
            return
        }
        stopEventStream()
        let client = self.client
        updateEventInterestSnapshot()
        lastStreamEventAt = .now
        debugLastEventSummary = "stream starting"
        appendDebugLog("stream start global")
        let streamGeneration = eventManager.generation &+ 1
        let activityLifetime = liveActivityFacade.currentLifetime
        eventManager.start(
            client: client,
            onStatus: { [weak self] status in
                await MainActor.run {
                    guard self?.eventManager.generation == streamGeneration else { return }
                    self?.debugLastEventSummary = status
                    self?.appendDebugLog(status)
                }
            },
            onRawLine: nil,
            onDroppedEvent: { [weak self] message in
                await MainActor.run {
                    guard self?.eventManager.generation == streamGeneration else { return }
                    self?.appendDebugLog(message)
                }
            },
            onEvent: { [weak self] managed in
                await MainActor.run {
                    guard let self, self.eventManager.generation == streamGeneration else { return }
                    self.liveActivityFacade.consumeBackgroundEvent(managed.typed, lifetime: activityLifetime)
                    if self.shouldLogEventDetails(for: managed.envelope.type) {
                        self.appendDebugLog("event \(managed.envelope.type): \(managed.directory)")
                    }
                    self.handleManagedEvent(managed)
                }
            }
        )
    }

    func startV2EventStream() {
        if let backendConnection {
            startBackendEventStream(backendConnection)
            return
        }
        guard backendFactory == nil else { return }
        stopEventStream()
        let client = self.client
        lastStreamEventAt = .now
        debugLastEventSummary = "stream v2 starting"
        appendDebugLog("stream start v2")
        let streamGeneration = eventManager.generation &+ 1
        let activityLifetime = liveActivityFacade.currentLifetime
        eventManager.startV2(
            client: client,
            onStatus: { [weak self] status in
                await MainActor.run {
                    guard let self, !Task.isCancelled, self.eventManager.generation == streamGeneration else { return }
                    self.debugLastEventSummary = status
                    self.appendDebugLog(status)
                    if status == "stream v2 reconnecting" {
                        self.v2TimelineReconcileTask?.cancel()
                        self.v2TimelineReconcileTask = nil
                        self.v2TimelineReconcileGeneration &+= 1
                    }
                    if status.hasPrefix("stream open") {
                        self.directoryStoreRegistry.requestV2Reconciliation(reconnect: true)
                        self.scheduleV2TimelineReconciliation(immediate: true)
                    }
                }
            },
            onDroppedEvent: { [weak self] message in
                await MainActor.run {
                    guard self?.eventManager.generation == streamGeneration else { return }
                    self?.appendDebugLog(message)
                }
            },
            onEvent: { [weak self] event in
                await MainActor.run {
                    guard !Task.isCancelled, self?.eventManager.generation == streamGeneration else { return }
                    self?.liveActivityFacade.consumeBackgroundEvent(event, lifetime: activityLifetime)
                    self?.handleV2Event(event)
                }
            }
        )
    }

    private func startBackendEventStream(_ connection: BackendConnection) {
        stopEventStream()
        guard isCurrentBackendConnection(connection) else { return }
        let activityLifetime = liveActivityFacade.currentLifetime
        updateEventInterestSnapshot()
        lastStreamEventAt = .now
        if let source = connection.events as? OpenCodeBackendEventSource {
            source.legacyEvent = { [weak self, weak connection] event in
                guard let self, let connection, self.isCurrentBackendConnection(connection) else { return }
                self.liveActivityFacade.consumeBackgroundEvent(event.typed, lifetime: activityLifetime)
                self.handleManagedEvent(event)
            }
            source.v2Event = { [weak self, weak connection] event in
                guard let self, let connection, self.isCurrentBackendConnection(connection) else { return }
                self.liveActivityFacade.consumeBackgroundEvent(event, lifetime: activityLifetime)
                self.handleV2Event(event)
            }
        }
        let stream = connection.eventStream()
        backendEventTask = Task { [weak self, weak connection] in
            for await event in stream {
                guard let self, let connection, self.isCurrentBackendConnection(connection) else { return }
                self.handleBackendEvent(event)
            }
        }
    }

    func handleBackendEvent(_ event: BackendEvent) {
        switch event {
        case let .status(status):
            if status.hasPrefix("stream open") { globalFormsFacade.reconnect() }
            debugLastEventSummary = status
            appendDebugLog(status)
            if connectionStore.apiProfile == .v2 {
                if status == "stream v2 reconnecting" {
                    v2TimelineReconcileTask?.cancel()
                    v2TimelineReconcileTask = nil
                    v2TimelineReconcileGeneration &+= 1
                }
                if status.hasPrefix("stream open") {
                    directoryStoreRegistry.requestV2Reconciliation(reconnect: true)
                    scheduleV2TimelineReconciliation(immediate: true)
                }
            }
        case let .diagnostic(message):
            appendDebugLog(message)
        case let .actionSignal(signal):
            guard let connection = backendConnection, let commands = connection.commands else { return }
            projectActionCoordinator.receive(signal, backendID: connection.descriptor.id, contractID: commands.actionContractID)
        case let .sessionForm(directory, event):
            guard isConnected, backendConnection?.sessionForms != nil, event.sessionID != "global" else { return }
            let owner = directoryStoreRegistry.ownerStore(forSessionID: event.sessionID) ?? directoryStoreRegistry.store(for: directory)
            owner.applySessionFormEvent(event)
            liveActivityFacade.reducerDidCommit(sessionIDs: [event.sessionID])
            if case .created = event { handleBackendEvent(.actionSignal(.needsAttention(sessionID: event.sessionID))) }
        case let .globalForm(location, event):
            globalFormsFacade.receive(location: location, event: event)
        case let .mutation(directory, typed):
            guard isConnected else { return }
            do {
                let managed = try BackendMutationBridge.managed(directory: directory, event: typed)
                let targets = directorySyncFacade.targetStores(for: managed, selectedSessionID: selectedSession?.id,
                    selectedSessionDirectory: selectedSession?.directory, effectiveSelectedDirectory: effectiveSelectedDirectory,
                    activeLiveActivitySessionIDs: [])
                guard confirmRoutedPromptAdmission(managed, targets: targets) else { return }
                var reducedProjects = projects
                var reducedCurrentProject = currentProject
                if eventSyncCoordinator.applyGlobalEvent(managed, projects: &reducedProjects, currentProject: &reducedCurrentProject) != nil {
                    projects = reducedProjects
                    currentProject = reducedCurrentProject
                    return
                }
                // Same directory routing and reducers, without legacy polling/cache/optional-feature side effects.
                let applications = directorySyncFacade.apply(
                    managed, activeState: directoryEventState(), selectedSessionID: selectedSession?.id,
                    selectedSessionDirectory: selectedSession?.directory, effectiveSelectedDirectory: effectiveSelectedDirectory,
                    activeLiveActivitySessionIDs: [],
                    scopedSessions: { [sessionListStore] in sessionListStore.sessions($0, scopedTo: $1) }
                )
                if let active = applications.first(where: { $0.store === directoryStore }) {
                    objectWillChange.send()
                    applyDirectoryEventState(active.application.state, to: active.store, appliesToStore: false)
                }
                reconcileCommittedSubmissionPresentations(managed, stores: applications.map(\.store))
                lastStreamEventAt = .now
            } catch {
                appendDebugLog("drop backend mutation: \(error)")
            }
        }
    }

    func handleV2Event(_ event: OpenCodeV2ManagedEvent) {
        guard connectionStore.apiProfile == .v2 else { return }
        lastStreamEventAt = .now
        debugLastEventSummary = event.type
        if shouldLogEventDetails(for: event.type) {
            appendDebugLog("v2 event \(event.type)")
        }

        if terminalFacade.consumeV2(event) || configurationsFacade.consumeV2(event) { return }

        directoryStoreRegistry.recordV2LifecycleEvent(event)
        if event.type == "project.directories.updated", let id = event.data.objectValue?["projectID"]?.literalStringValue,
           let connection = backendConnection {
            Task { [weak self] in
                guard let self, self.isCurrentBackendConnection(connection) else { return }
                await self.refreshProjectWorktreeInventory(projectID: id)
            }
            return
        }
        if event.type.hasPrefix("project.") || event.type.hasPrefix("worktree.") {
            directoryStoreRegistry.requestV2Reconciliation(reconnect: true)
            scheduleV2TimelineReconciliation()
        }
        guard let sessionID = event.sessionID else { return }
        guard event.type == "session.deleted" || !directoryStoreRegistry.isV2SessionDeleted(sessionID) else { return }
        let wasSelected = selectedSession?.id == sessionID
        let owner = directoryStoreRegistry.targetStore(forV2Event: event)
        let known = directoryStoreRegistry.session(matching: sessionID) != nil
        let scopeChanged = directoryStoreRegistry.ownerStore(forSessionID: sessionID).map { $0 !== owner } ?? false
        if event.type == "session.deleted" {
            removeSessionFromLocalCache(sessionID)
            removeWidgetSessionSnapshot(for: sessionID)
            for store in directoryStoreRegistry.stores(containingSessionID: sessionID) {
                store.removeV2Session(sessionID: sessionID)
            }
            chatStore.clearCachedMessages(forSessionID: sessionID)
            if wasSelected { chatStore.clearActiveTranscript() }
            removePinnedSessionIDFromAllScopes(sessionID)
            removeSessionPreview(for: sessionID)
            sessionListStore.removeRecentSession(sessionID: sessionID)
        } else {
            if event.type == "session.moved", let previous = directoryStoreRegistry.session(matching: sessionID) {
                owner.insertV2Session(previous)
                for old in directoryStoreRegistry.stores(containingSessionID: sessionID) where old !== owner {
                    owner.applyV2Messages(old.syncState.messageEnvelopes(forSessionID: sessionID), forSessionID: sessionID)
                    if let status = old.sessionStatuses[sessionID] { owner.applySessionStatus(status, forSessionID: sessionID) }
                    old.removeV2Session(sessionID: sessionID)
                }
                if wasSelected, owner !== directoryStore { chatStore.clearActiveTranscript() }
            }
            _ = owner.applyV2Event(event)
            if wasSelected, event.type == "session.execution.failed" {
                errorMessage = event.data.objectValue?["error"]?.objectValue?["message"]?.literalStringValue
            }
            let projected = chatStore.applyV2StreamEvent(event, sessionID: sessionID)
            if let inputID = event.inputID, let connection = backendConnection,
               chatStore.submissionRecoveries[inputID]?.phase == .admitted
                || chatStore.submissionRecoveries[inputID]?.phase == .cancelled
                || chatStore.canonicalSubmissionSessions[inputID] == sessionID {
                connectionStore.clearPromptError(connectionID: connection.id, sessionID: sessionID, messageID: inputID)
                if chatStore.submissionRecoveries[inputID]?.phase == .admitted {
                    chatStore.applyPromptAdmission(.admitted, messageID: inputID, connectionID: connection.id)
                } else if let canonical = chatStore.cachedMessagesBySessionID[sessionID]?.first(where: { $0.id == inputID }) {
                    confirmCanonicalPromptAdmission(canonical.info, connectionID: connection.id)
                }
            }
            if projected {
                owner.applyV2Messages(chatStore.cachedMessagesBySessionID[sessionID] ?? [], forSessionID: sessionID)
            } else {
                owner.applyV2Messages(chatStore.withoutRecoveryMessages(owner.syncState.messageEnvelopes(forSessionID: sessionID),
                    sessionID: sessionID), forSessionID: sessionID)
            }
            finishTranscriptCommit(in: owner, sessionID: sessionID)
            let requiresProjection = event.isExecutionTerminal || !known || scopeChanged
                || chatStore.isHydratingV2Transcript(sessionID: sessionID)
                || event.type == "session.forked" || event.type == "session.moved"
                || event.type == "session.inbox.delivered"
                || event.type == "session.agent.selected" || event.type == "session.model.selected"
                || event.type.hasPrefix("session.compaction.") || event.type.hasPrefix("session.shell.")
                || event.type == "session.synthetic" || event.type == "session.skill.activated"
                || event.type == "session.instructions.updated"
                || (!projected && event.affectsTranscript)
            if requiresProjection, sessionID != "global" {
                directoryStoreRegistry.requestV2Reconciliation(sessionID: sessionID)
                scheduleV2TimelineReconciliation()
            }
        }
        if let selected = selectedSession {
            sessionInteractionStore.applySelectedSession(sessionID: selected.id, sessions: directoryStore.sessions, syncState: directoryStore.syncState)
        } else if wasSelected {
            _ = sessionInteractionStore.applyVisibleInteractions(todos: [], permissions: [], questions: [])
        }
        sessionListFacade.invalidateWorkspaceSnapshot()
        liveActivityFacade.reducerDidCommit(sessionIDs: [sessionID])
        objectWillChange.send()
    }

    func scheduleV2InteractionRefresh(for sessionID: String) {
        directoryStoreRegistry.requestV2Reconciliation(sessionID: sessionID)
        scheduleV2TimelineReconciliation()
    }

    func scheduleV2TimelineReconciliation(immediate: Bool = false) {
        guard connectionStore.apiProfile == .v2 else { return }
        if directoryStoreRegistry.v2PendingSessionIDs.isEmpty,
           let sessionID = selectedSession?.id {
            directoryStoreRegistry.requestV2Reconciliation(sessionID: sessionID)
        }
        isV2TimelineReconcilePending = true
        guard v2TimelineReconcileTask == nil else { return }
        v2TimelineReconcileGeneration &+= 1
        let generation = v2TimelineReconcileGeneration
        v2TimelineReconcileTask?.cancel()
        v2TimelineReconcileTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.v2TimelineReconcileGeneration == generation {
                    self.v2TimelineReconcileTask = nil
                }
            }
            if !immediate {
                try? await Task.sleep(for: .milliseconds(180))
            }
            let registryGeneration = self.directoryStoreRegistry.generation
            while !Task.isCancelled, self.directoryStoreRegistry.generation == registryGeneration {
                self.isV2TimelineReconcilePending = false
                let request = self.directoryStoreRegistry.takeV2Reconciliation()
                if request.reconnect { await self.hydrateV2ReconnectState() }
                for sessionID in request.sessionIDs.sorted() {
                    guard !Task.isCancelled, self.directoryStoreRegistry.generation == registryGeneration else { return }
                    await self.reconcileV2KnownSession(sessionID: sessionID)
                }
                guard self.isV2TimelineReconcilePending || !self.directoryStoreRegistry.v2PendingSessionIDs.isEmpty else { return }
                try? await Task.sleep(for: .milliseconds(180))
            }
        }
    }

    private func hydrateV2ReconnectState() async {
        guard let connection = backendConnection else { return }
        let generation = directoryStoreRegistry.generation
        await terminalFacade.refreshAfterEventReconnect()
        guard !Task.isCancelled, directoryStoreRegistry.generation == generation else { return }
        await configurationsFacade.refreshAfterEventReconnect()
        guard !Task.isCancelled, directoryStoreRegistry.generation == generation else { return }
        if let projectID = currentProject?.id { await refreshProjectWorktreeInventory(projectID: projectID) }
        guard !Task.isCancelled, directoryStoreRegistry.generation == generation else { return }
        let projectRevision = directoryStoreRegistry.v2ProjectRevision
        do {
            let bootstrap = try await client.bootstrapV2Projects()
            guard !Task.isCancelled, directoryStoreRegistry.generation == generation else { return }
            if directoryStoreRegistry.v2ProjectRevision == projectRevision {
                projectStore.defaultServerDirectory = bootstrap.selectedDirectory
                projects = projectCoordinator.bootstrapProjects(bootstrap.projects, currentProject: bootstrap.currentProject)
                    .map { projectStore.preservingSelectedDirectory($0, connectionID: connection.id) }
                if let selected = currentProject, let updated = projects.first(where: { $0.id == selected.id }) {
                    currentProject = updated
                }
                persistProjectsToLocalCache()
            }
        } catch {
            if !Task.isCancelled { appendDebugLog("v2 project reconciliation failed: \(error.localizedDescription)") }
        }
        for store in directoryStoreRegistry.allStores {
            guard !Task.isCancelled, directoryStoreRegistry.generation == generation else { return }
            guard let key = directoryStoreRegistry.key(for: store) else { continue }
            let directory = DirectoryStoreRegistry.directory(forKey: key)
            let snapshot = directoryStoreRegistry.v2LifecycleSnapshot
            let sessionsBeforeRequest = store.sessions
            do {
                let projectID = key == DirectoryStoreRegistry.globalKey ? "global" : store.sessions.first?.projectID ?? "global"
                let page = try await client.listV2Sessions(projectID: projectID, directory: directory, roots: false)
                guard !Task.isCancelled, directoryStoreRegistry.generation == generation else { return }
                let unchanged = directoryStoreRegistry.unchangedV2Sessions(page.sessions, since: snapshot)
                store.applyV2DiscoveredSessions(unchanged, ifUnchangedSince: sessionsBeforeRequest)
                for session in unchanged {
                    guard isCurrentBackendConnection(connection), directoryStoreRegistry.generation == generation else { return }
                    directoryStoreRegistry.requestV2Reconciliation(sessionID: session.id)
                    await funAndGamesFacade.reconcileSetup(for: session.id)
                }
            } catch {
                if !Task.isCancelled { appendDebugLog("v2 directory reconciliation failed: \(error.localizedDescription)") }
            }
        }
        let stores = directoryStoreRegistry.allStores.map { ($0, $0.statusRevision) }
        let lifecycleSnapshot = directoryStoreRegistry.v2LifecycleSnapshot
        do {
            let statuses = try await client.listV2SessionStatuses()
            guard !Task.isCancelled, directoryStoreRegistry.generation == generation else { return }
            for (store, revision) in stores {
                store.applyV2ActiveStatuses(statuses, requestedAtRevision: revision)
            }
            for id in statuses.keys where directoryStoreRegistry.ownerStore(forSessionID: id) == nil
                && !directoryStoreRegistry.isV2SessionDeleted(id)
                && directoryStoreRegistry.v2LifecycleRevision(sessionID: id) == (lifecycleSnapshot[id] ?? 0) {
                directoryStoreRegistry.store(for: nil).applySessionStatus(statuses[id] ?? "busy", forSessionID: id)
                directoryStoreRegistry.requestV2Reconciliation(sessionID: id)
            }
        } catch {
            if !Task.isCancelled { appendDebugLog("v2 active hydration failed: \(error.localizedDescription)") }
        }
    }

    private func reconcileV2KnownSession(sessionID: String) async {
        let client = client
        let registryGeneration = directoryStoreRegistry.generation
        let originalOwner = directoryStoreRegistry.ownerStore(forSessionID: sessionID)
        let originalSession = directoryStoreRegistry.session(matching: sessionID)
        let lifecycleRevision = directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID)
        do {
            let session = try await client.getV2Session(sessionID: sessionID)
            guard !Task.isCancelled, directoryStoreRegistry.generation == registryGeneration,
                  directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision,
                  directoryStoreRegistry.session(matching: sessionID) == originalSession else { return }
            let owner = directoryStoreRegistry.targetStore(forV2Session: session)
            owner.insertV2Session(session)
            if let parent = session.parentID { handleBackendEvent(.actionSignal(.sessionParent(sessionID: session.id, parentID: parent))) }
            applyV2SessionConfiguration(session)
            if let originalOwner, originalOwner !== owner {
                if selectedSession?.id == sessionID { chatStore.clearActiveTranscript() }
                if let status = originalOwner.sessionStatuses[sessionID] { owner.applySessionStatus(status, forSessionID: sessionID) }
                originalOwner.removeV2Session(sessionID: sessionID)
            }
            let permissionRevision = owner.permissionRevision
            let questionRevision = owner.questionRevision
            do {
                async let permissions = client.listV2SessionPermissions(sessionID: sessionID)
                async let forms = client.listV2SessionForms(sessionID: sessionID)
                let (loadedPermissions, loadedForms) = try await (permissions, forms)
                guard !Task.isCancelled, directoryStoreRegistry.generation == registryGeneration,
                      directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision,
                      owner.sessions.first(where: { $0.id == sessionID }) == session else { return }
                owner.applyV2SessionInteractions(sessionID: sessionID, permissions: loadedPermissions, forms: loadedForms,
                    permissionRevisionAtRequestStart: permissionRevision, questionRevisionAtRequestStart: questionRevision)
                liveActivityFacade.reducerDidCommit(sessionIDs: [sessionID])
                if selectedSession?.id == sessionID {
                    sessionInteractionStore.applySelectedSession(sessionID: sessionID, sessions: owner.sessions, syncState: owner.syncState)
                }
            } catch {
                guard !Task.isCancelled, directoryStoreRegistry.generation == registryGeneration else { return }
                appendDebugLog("v2 interaction reconciliation failed: \(error.localizedDescription)")
            }
            guard !Task.isCancelled, directoryStoreRegistry.generation == registryGeneration,
                   directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision,
                   owner.sessions.first(where: { $0.id == sessionID }) == session else { return }
            await reconcileV2TimelineFromEvent(sessionID: sessionID)
        } catch OpenCodeAPIError.httpError(404, _) {
            // Only GET Session.Info proves deletion. A missing subresource does not.
            guard !Task.isCancelled, directoryStoreRegistry.generation == registryGeneration,
                  directoryStoreRegistry.v2LifecycleRevision(sessionID: sessionID) == lifecycleRevision,
                  directoryStoreRegistry.session(matching: sessionID) == originalSession else { return }
            originalOwner?.removeV2Session(sessionID: sessionID)
            directoryStoreRegistry.markV2SessionDeleted(sessionID)
            chatStore.clearCachedMessages(forSessionID: sessionID)
            if chatStore.preparedSessionID == sessionID { chatStore.clearActiveTranscript() }
        } catch {
            if !Task.isCancelled { appendDebugLog("v2 session reconciliation failed: \(error.localizedDescription)") }
        }
    }

    func stopEventStream() {
        backendEventTask?.cancel()
        backendEventTask = nil
        backendConnection?.stopEvents()
        flushPendingTranscriptEvents(reason: "stream stop")
        reloadTask?.cancel()
        reloadTask = nil
        eventManager.stop()
        eventStreamRestartTask?.cancel()
        eventStreamRestartTask = nil
        v2TimelineReconcileTask?.cancel()
        v2TimelineReconcileTask = nil
        v2InteractionRefreshTask?.cancel()
        v2InteractionRefreshTask = nil
        v2TimelineReconcileGeneration &+= 1
        isV2TimelineReconcilePending = false
        debugLastEventSummary = "stream stopped"
        appendDebugLog("stream stopped")
    }

    func startDebugProbeStreams() {
        guard backendFactory == nil || backendConnection?.openCodeCompatibility != nil else { return }
        let client = self.client
        guard let urls = try? client.eventURLs(directory: streamDirectory) else { return }

        for url in urls {
            let label = probeLabel(for: url)
            let task = Task.detached(priority: .background) { [weak self] in
                await OpenCodeEventStream.consume(
                    client: client,
                    url: url,
                    onStatus: { status in
                        await MainActor.run {
                            self?.appendDebugLog("probe \(label) \(status)")
                        }
                    },
                    onRawLine: { line in
                        await MainActor.run {
                            self?.appendDebugLog("probe \(label) raw \(Self.debugRawLine(line))")
                        }
                    },
                    onEvent: { event in
                        await MainActor.run {
                            self?.appendDebugLog("probe \(label) event \(event.type): \(String(event.data.prefix(180)))")
                        }
                    }
                )
            }
            debugProbeStreamTasks.append(task)
        }
    }

    func stopDebugProbeStreams() {
        debugProbeStreamTasks.forEach { $0.cancel() }
        debugProbeStreamTasks.removeAll()
    }

    func handleManagedEvent(_ managed: OpenCodeManagedEvent) {
        guard eventSyncCoordinator.shouldProcessEvent(isConnected: isConnected) else { return }
        guard backendConnection?.openCodeCompatibility?.profile != .v2 else { return }

        if shouldLogEventDetails(for: managed.envelope.type) {
            appendDebugLog(eventScopeSummary(for: managed))
            appendDebugLog(eventIdentitySummary(for: managed.envelope))
        }

        var reducedProjects = projects
        var reducedCurrentProject = currentProject
        if let globalAction = eventSyncCoordinator.applyGlobalEvent(
            managed,
            projects: &reducedProjects,
            currentProject: &reducedCurrentProject
        ) {
            if reducedProjects != projects {
                projects = reducedProjects
            }
            if reducedCurrentProject != currentProject {
                currentProject = reducedCurrentProject
            }
            persistProjectsToLocalCache()
            switch globalAction {
            case .applied:
                break
            case .refreshProjectsAndSessions:
                Task { [weak self] in
                    try? await self?.refreshProjects()
                    try? await self?.reloadSessions()
                }
            }
            return
        }

        if handleWorktreeLifecycleEvent(managed) {
            return
        }

        if terminalFacade.consume(managed) {
            return
        }

        let targetStores = directorySyncFacade.targetStores(
            for: managed,
            selectedSessionID: selectedSession?.id,
            selectedSessionDirectory: selectedSession?.directory,
            effectiveSelectedDirectory: effectiveSelectedDirectory,
            activeLiveActivitySessionIDs: activeLiveActivitySessionIDs
        )
        guard !targetStores.isEmpty else {
            appendDebugLog("drop \(managed.envelope.type): scope mismatch \(managed.directory) selected=\(debugDirectoryLabel(effectiveSelectedDirectory)) stream=\(debugDirectoryLabel(streamDirectory)) session=\(debugSessionLabel(selectedSession))")
            return
        }
        guard confirmRoutedPromptAdmission(managed, targets: targetStores) else { return }
        let updatesActiveStore = targetStores.contains { $0 === directoryStore }

        if eventAffectsActiveSession(managed) {
            lastStreamEventAt = .now
        }

        if isLiveActivityMessageEvent(managed.envelope.type) || managed.envelope.type == "session.idle" {
            markChatBreadcrumb(
                "event \(managed.envelope.type)",
                sessionID: managedEventSessionID(for: managed),
                messageID: managed.envelope.properties.messageID ?? managed.envelope.properties.part?.messageID ?? managed.envelope.properties.info?.id,
                partID: managed.envelope.properties.partID ?? managed.envelope.properties.part?.id
            )
        }

        if updatesActiveStore, enqueueSelectedTranscriptEventIfNeeded(managed) {
            return
        }

        if updatesActiveStore, shouldFlushPendingTranscriptEvents(before: managed) {
            flushPendingTranscriptEvents(reason: "before \(managed.envelope.type)")
        }

        if case let .sessionError(sessionID, message) = managed.typed {
            if let sessionID {
                for store in targetStores {
                    store.sessionStatuses[sessionID] = "idle"
                    store.syncState.sessionStatusesBySessionID[sessionID] = "idle"
                }
            }
            if sessionID == nil || sessionID == selectedSession?.id {
                errorMessage = message ?? String(localized: "Session error")
            }
            debugLastEventSummary = message.map { "session error: \($0)" } ?? "session error"
            appendDebugLog(debugLastEventSummary)
            stopStreamingDiagnostics()
            return
        }

        let payload = managed.envelope
        let currentSelectedSession = selectedSession
        let eventSessionID = managedEventSessionID(for: managed)

        if inferFunAndGames(from: managed.typed) {
            appendDebugLog("fun games inferred session=\(eventSessionID ?? "nil")")
        }

        let applications = directorySyncFacade.apply(
            managed,
            activeState: directoryEventState(),
            selectedSessionID: selectedSession?.id,
            selectedSessionDirectory: selectedSession?.directory,
            effectiveSelectedDirectory: effectiveSelectedDirectory,
            activeLiveActivitySessionIDs: activeLiveActivitySessionIDs,
            scopedSessions: { [sessionListStore] sessions, directory in
                sessionListStore.sessions(sessions, scopedTo: directory)
            }
        )
        if let activeApplication = applications.first(where: { $0.store === directoryStore }) {
            if activeApplication.changedStore {
                objectWillChange.send()
            }
            applyDirectoryEventState(
                activeApplication.application.state,
                to: activeApplication.store,
                appliesToStore: false,
                updatesSelectedMessages: payload.type != "message.part.delta" || eventAffectsActiveSession(managed)
            )
        }
        if updatesActiveStore, managed.envelope.type == "message.part.updated" {
            flushPendingTranscriptEvents(reason: "after \(managed.envelope.type)")
        }
        reconcileCommittedSubmissionPresentations(managed, stores: applications.map(\.store))
        let result = applications.first(where: { $0.store === directoryStore })?.application.result
            ?? applications.last?.application.result
            ?? .ignored("no target store")

        switch result {
        case let .message(reason):
            if updatesActiveStore, let currentSelectedSession, shouldRefreshSessionPreview(for: currentSelectedSession.id, eventType: payload.type) {
                refreshSessionPreview(for: currentSelectedSession.id, messages: messages)
            }
            if updatesActiveStore, let currentSelectedSession,
               payload.type == "message.updated",
               payload.properties.info?.role == "user",
               payload.properties.info?.sessionID == currentSelectedSession.id {
                syncComposerSelections(for: currentSelectedSession)
            }
            debugLastEventSummary = debugSummary(for: payload)
            appendDebugLog(debugSummary(for: payload))
            appendDebugLog("apply \(payload.type): \(reason) count \(messages.count)")

            if payload.type == "message.part.updated",
               payload.properties.part?.type == "step-finish" {
                appendDebugLog("step finish")
                stopStreamingDiagnostics()
            }

            triggerStreamPartHapticIfNeeded(for: managed)
        case .sessionChanged:
            appendDebugLog("session changed")
        case .todoChanged:
            appendDebugLog("todo changed")
        case .permissionChanged:
            appendDebugLog("permission changed")
        case .questionChanged:
            appendDebugLog("question changed")
        case .statusChanged:
            appendDebugLog("status changed")
        case .idle:
            appendDebugLog("session idle")
            markChatBreadcrumb("session idle", sessionID: eventSessionID)
            stopStreamingDiagnostics()
            if updatesActiveStore, eventSessionID == currentSelectedSession?.id, let currentSelectedSession {
                refreshSessionPreview(for: currentSelectedSession.id, messages: messages)
                scheduleReload(for: currentSelectedSession)
            }
        case let .ignored(reason):
            appendDebugLog("drop \(payload.type): \(reason)")
        }

        switch managed.typed {
        case let .sessionDeleted(session):
            removePinnedSessionIDFromAllScopes(session.id)
            removeSessionPreview(for: session.id)
            sessionListStore.removeRecentSession(sessionID: session.id)
        case let .vcsBranchUpdated(branch):
            projectFilesStore.applyBranchUpdate(branch)
            projectFilesFacade.refreshFromEvent()
        case let .fileWatcherUpdated(file):
            projectFilesFacade.handleFileWatcherUpdate(file)
        default:
            break
        }

        persistManagedEventToLocalCache(
            managed,
            applications: applications,
            sessionID: eventSessionID
        )

        liveActivityFacade.consumeReducerEvent(
            managed.typed,
            result: result,
            sessionID: eventSessionID,
            eventType: payload.type
        )
    }

    private func handleWorktreeLifecycleEvent(_ managed: OpenCodeManagedEvent) -> Bool {
        switch managed.typed {
        case let .worktreeReady(name, branch):
            objectWillChange.send()
            recordWorktreeReadiness(directory: managed.directory, error: nil)
            appendDebugLog("worktree ready dir=\(managed.directory) name=\(name) branch=\(branch)")
            Task { [weak self] in
                await self?.refreshWorkspaceSessions(directory: managed.directory)
            }
            return true
        case let .worktreeFailed(message):
            objectWillChange.send()
            recordWorktreeReadiness(directory: managed.directory, error: message)
            appendDebugLog("worktree failed dir=\(managed.directory) message=\(message)")
            return true
        default:
            return false
        }
    }

    private func shouldRefreshSessionPreview(for sessionID: String, eventType: String) -> Bool {
        guard eventType != "message.part.delta" else { return false }
        return sessionStatuses[sessionID] != "busy"
    }

    private func shouldLogEventDetails(for eventType: String) -> Bool {
        guard isCapturingStreamingDiagnostics else { return false }
        return eventType != "message.part.delta"
    }

    private func enqueueSelectedTranscriptEventIfNeeded(_ managed: OpenCodeManagedEvent) -> Bool {
        guard shouldBufferTranscriptEvent(managed) else {
            return false
        }

        let event = OpenCodePendingTranscriptEvent(
            typedEvent: managed.typed,
            eventType: managed.envelope.type,
            sessionID: managedEventSessionID(for: managed),
            messageID: managed.envelope.properties.messageID ?? managed.envelope.properties.part?.messageID ?? managed.envelope.properties.info?.id,
            partID: managed.envelope.properties.partID ?? managed.envelope.properties.part?.id,
            deltaCharacterCount: transcriptDeltaCharacterCount(for: managed),
            enqueuedAt: Date()
        )
        guard chatStore.enqueuePendingTranscriptEventIfAvailable(event, in: directoryStore.syncState) else {
            appendDebugLog("drop message.part.delta: missing canonical part")
            return true
        }
        triggerStreamPartHapticIfNeeded(for: managed)
        scheduleStreamDeltaFlush()
        flushBurstPendingTranscriptEventsIfNeeded()
        flushOverduePendingTranscriptEventsIfNeeded()
        return true
    }

    private func shouldBufferTranscriptEvent(_ managed: OpenCodeManagedEvent) -> Bool {
        return ChatStore.shouldBufferTranscriptEvent(
            managed.typed,
            selectedSessionID: selectedSession?.id,
            activeChatSessionID: activeChatSessionID
        )
    }

    private func shouldFlushPendingTranscriptEvents(before managed: OpenCodeManagedEvent) -> Bool {
        return chatStore.hasPendingTranscriptEvents
    }

    private func transcriptDeltaCharacterCount(for managed: OpenCodeManagedEvent) -> Int {
        guard case let .messagePartDelta(_, _, _, _, delta) = managed.typed else { return 0 }
        return delta.count
    }

    private func scheduleStreamDeltaFlush(rescheduling: Bool = false) {
        if rescheduling {
            streamDeltaFlushTask?.cancel()
            streamDeltaFlushTask = nil
        }

        guard streamDeltaFlushTask == nil else { return }

        let interval = streamDeltaCoalescingInterval()
        let inputs = chatStore.streamDeltaCoalescingInputLengths(syncState: directoryStore.syncState)
        streamDeltaScheduledIntervalMS = interval.elapsedMilliseconds
        streamDeltaScheduledActiveTextLength = inputs.activeTextLength
        streamDeltaScheduledPendingCharacterCount = inputs.pendingCharacterCount
        streamDeltaFlushGeneration &+= 1
        let generation = streamDeltaFlushGeneration

        streamDeltaFlushTask = Task.detached(priority: .userInitiated) { [weak self] in
            try? await Task.sleep(for: interval)
            guard !Task.isCancelled else { return }
            await self?.flushPendingTranscriptEventsIfCurrentTimer(generation: generation)
        }
    }

    private func streamDeltaCoalescingInterval() -> Duration {
        chatStore.streamDeltaCoalescingInterval(
            syncState: directoryStore.syncState,
            short: Self.shortStreamDeltaCoalescingInterval,
            medium: Self.mediumStreamDeltaCoalescingInterval,
            long: Self.longStreamDeltaCoalescingInterval,
            veryLong: Self.veryLongStreamDeltaCoalescingInterval
        )
    }

    private func flushOverduePendingTranscriptEventsIfNeeded() {
        guard let oldest = chatStore.pendingTranscriptOldestEnqueuedAt else { return }
        let intervalMS = streamDeltaScheduledIntervalMS ?? streamDeltaCoalescingInterval().elapsedMilliseconds
        guard intervalMS > 0 else { return }
        let waitMS = Int(Date().timeIntervalSince(oldest) * 1_000)
        guard waitMS >= intervalMS else { return }

        flushPendingTranscriptEvents(reason: "overdue")
    }

    private func flushBurstPendingTranscriptEventsIfNeeded() {
        let pendingEventCount = chatStore.pendingTranscriptEventCount
        let pendingCharacterCount = chatStore.pendingTranscriptCharacterCount
        guard pendingEventCount >= Self.burstFlushEventCount ||
            pendingCharacterCount >= Self.burstFlushCharacterCount else {
            return
        }

        if pendingEventCount < Self.immediateBurstFlushEventCount,
           pendingCharacterCount < Self.immediateBurstFlushCharacterCount,
           let oldest = chatStore.pendingTranscriptOldestEnqueuedAt {
            let waitMS = Int(Date().timeIntervalSince(oldest) * 1_000)
            guard waitMS >= Self.burstFlushMinimumAgeMS else { return }
        }

        flushPendingTranscriptEvents(reason: "burst")
    }

    private func flushPendingTranscriptEventsIfCurrentTimer(generation: Int) {
        guard streamDeltaFlushGeneration == generation else { return }
        flushPendingTranscriptEvents(reason: "timer")
    }

    private func flushPendingTranscriptEvents(reason: String) {
        streamDeltaFlushTask?.cancel()
        streamDeltaFlushTask = nil
        streamDeltaFlushGeneration &+= 1

        let now = Date()
        let pending = chatStore.drainAvailablePendingTranscriptEvents(in: directoryStore.syncState)
        guard let pending else { return }
        let events = pending.events
        let reducerEvents = pending.coalescedEvents
        guard !reducerEvents.isEmpty else {
            logStreamDeltaFlush(reason: reason, events: events, appliedCount: 0, coalescedCount: 0, flushedAt: now)
            return
        }

        let reduceStart = ContinuousClock.now
        let application = eventSyncCoordinator.applyDirectoryEvents(reducerEvents.map(\.typedEvent), to: directoryEventState())
        let reduceElapsedMS = reduceStart.elapsedMilliseconds
        let publishStart = ContinuousClock.now
        applyDirectoryEventState(application.state, updatesSelectedMessages: true)
        let publishElapsedMS = publishStart.elapsedMilliseconds

        liveActivityFacade.reducerDidCommit(sessionIDs: Set(events.compactMap(\.sessionID)))

        logStreamDeltaFlush(
            reason: reason,
            events: events,
            appliedCount: application.messageApplyCount,
            coalescedCount: reducerEvents.count,
            flushedAt: now,
            reduceElapsedMS: reduceElapsedMS,
            publishElapsedMS: publishElapsedMS
        )
    }

    func prepareForDirectoryStoreActivation() {
        flushPendingTranscriptEvents(reason: "directory switch")
        streamDeltaFlushTask?.cancel()
        streamDeltaFlushTask = nil
        streamDeltaFlushGeneration &+= 1
        pendingTranscriptEvents = []
    }

    private func directoryEventState() -> EventSyncCoordinator.DirectoryEventState {
        EventSyncCoordinator.DirectoryEventState(
            sessions: allSessions,
            selectedSession: selectedSession,
            sessionStatuses: sessionStatuses,
            syncState: directoryStore.syncState,
            messages: messages,
            todos: todos,
            permissions: permissions,
            questions: questions
        )
    }

    private func confirmRoutedPromptAdmission(_ event: OpenCodeManagedEvent, targets: [DirectoryStore]) -> Bool {
        let sessionID: String?
        switch event.typed {
        case let .messageUpdated(info): sessionID = info.sessionID
        case let .messagePartUpdated(part): sessionID = part.sessionID
        case let .messagePartDelta(id, _, _, _, _), let .messageRemoved(id, _): sessionID = id
        default: return true
        }
        guard let sessionID else { return true }
        guard !targets.isEmpty else { return false }
        if let owner = directoryStoreRegistry.ownerStore(forSessionID: sessionID) {
            let session = owner.sessions.first { $0.id == sessionID }
                ?? (owner.selectedSession?.id == sessionID ? owner.selectedSession : nil)
            // Project/global containers can own sessions whose actual location is a worktree.
            let directory = session.map { DirectoryStoreRegistry.key(for: $0.directory) }
                ?? directoryStoreRegistry.key(for: owner)
            guard targets.contains(where: { $0 === owner }),
                  event.directory == DirectoryStoreRegistry.globalKey
                    || directory == DirectoryStoreRegistry.key(for: event.directory) else { return false }
        }
        if case let .messageUpdated(info) = event.typed, let connection = backendConnection {
            confirmCanonicalPromptAdmission(info, connectionID: connection.id)
        }
        return true
    }

    private func reconcileCommittedSubmissionPresentations(_ event: OpenCodeManagedEvent, stores: [DirectoryStore]) {
        guard !stores.isEmpty else { return }
        if case let .messageRemoved(sessionID, messageID) = event.typed {
            chatStore.removeSubmissionPresentation(messageID: messageID, sessionID: sessionID)
        }
        guard let sessionID = eventSyncCoordinator.sessionID(for: event.typed) else { return }
        for store in stores {
            finishTranscriptCommit(in: store, sessionID: sessionID)
        }
    }

    /// Keep existing presentation owners on the same canonical snapshot before releasing the shared visual bridge.
    func finishTranscriptCommit(in source: DirectoryStore, sessionID: String,
                                completeInventory: [OpenCodeMessageEnvelope]? = nil) {
        guard directoryStoreRegistry.key(for: source) != nil else { return }
        let committed = source.syncState.messageEnvelopes(forSessionID: sessionID)
        if windowSessionInterests.values.contains(sessionID),
           let session = source.sessions.first(where: { $0.id == sessionID })
                ?? (source.selectedSession?.id == sessionID ? source.selectedSession : nil) {
            for target in directoryStoreRegistry.stores(containingSessionID: sessionID) where target !== source {
                guard let targetSession = target.sessions.first(where: { $0.id == sessionID })
                    ?? (target.selectedSession?.id == sessionID ? target.selectedSession : nil),
                    DirectoryStoreRegistry.key(for: targetSession.directory) == DirectoryStoreRegistry.key(for: session.directory),
                    targetSession.workspaceID == session.workspaceID else { continue }
                // The source has already reduced/ordered these envelopes. Never merge a local overlay here.
                target.applyV2Messages(committed, forSessionID: sessionID)
                if let status = source.sessionStatuses[sessionID] { target.applySessionStatus(status, forSessionID: sessionID) }
                if target === directoryStore, selectedSession?.id == sessionID {
                    chatStore.replaceActiveMessagesWithCanonical(committed)
                }
            }
        }
        let inventory = completeInventory.map { inventory in committed.filter { inventory.contains($0) } } ?? committed
        chatStore.retireSubmissionPresentations(in: inventory, sessionID: sessionID, completeInventory: completeInventory != nil)
    }

    private func applyDirectoryEventState(
        _ state: EventSyncCoordinator.DirectoryEventState,
        to targetStore: DirectoryStore? = nil,
        appliesToStore: Bool = true,
        updatesSelectedMessages: Bool = true
    ) {
        let targetStore = targetStore ?? directoryStore
        let targetDirectory = directoryStoreRegistry.key(for: targetStore)
            .flatMap(DirectoryStoreRegistry.directory(forKey:))
        let scopedSessions = sessionListStore.sessions(state.sessions, scopedTo: targetDirectory)
        if appliesToStore,
           targetStore.applyReducedEventState(state, scopedSessions: scopedSessions),
           targetStore === directoryStore {
            objectWillChange.send()
        }
        guard targetStore === directoryStore else { return }
        if sessionListStore.reconcileWorkspaceSessions(with: state.sessions) {
            objectWillChange.send()
        }
        if updatesSelectedMessages {
            let projectedMessages: [OpenCodeMessageEnvelope]
            if let selectedSessionID = state.selectedSession?.id,
               state.syncState.messagesBySessionID[selectedSessionID] != nil {
                projectedMessages = state.syncState.messageEnvelopes(forSessionID: selectedSessionID)
            } else {
                projectedMessages = state.messages
            }
            if projectedMessages != messages {
                chatStore.replaceActiveMessagesWithCanonical(projectedMessages)
            }
            if let sessionID = state.selectedSession?.id {
                finishTranscriptCommit(in: targetStore, sessionID: sessionID)
            }
        }
        let selectedSessionID = state.selectedSession?.id
        let visiblePermissions = selectedSessionID.map {
            SessionInteractionStore.permissions(
                forSessionTreeRootID: $0,
                sessions: state.sessions,
                permissionsBySessionID: state.syncState.permissionsBySessionID
            )
        } ?? []
        let visibleQuestions = selectedSessionID.map {
            SessionInteractionStore.questions(
                forSessionTreeRootID: $0,
                sessions: state.sessions,
                questionsBySessionID: state.syncState.questionsBySessionID
            )
        } ?? []
        if sessionInteractionStore.applyVisibleInteractions(
            todos: state.todos,
            permissions: visiblePermissions,
            questions: visibleQuestions
        ) {
            objectWillChange.send()
        }
    }

    private func logStreamDeltaFlush(
        reason: String,
        events: [OpenCodePendingTranscriptEvent],
        appliedCount: Int,
        coalescedCount: Int,
        flushedAt now: Date,
        reduceElapsedMS: Double? = nil,
        publishElapsedMS: Double? = nil
    ) {
        streamDeltaLastFlushAt = now
    }

    nonisolated static func shouldProcessLiveMessageEvent(
        eventType: String,
        eventSessionID: String?,
        activeChatSessionID: String?,
        activeLiveActivitySessionIDs: Set<String>,
        affectsSelectedTranscript: Bool
    ) -> Bool {
        guard isLiveActivityMessageEventType(eventType) else { return true }

        if let eventSessionID, activeLiveActivitySessionIDs.contains(eventSessionID) {
            return true
        }

        if let eventSessionID, eventSessionID == activeChatSessionID {
            return true
        }

        // Some removal events only carry message ids. Keep those when they match the selected transcript.
        if eventSessionID == nil, affectsSelectedTranscript {
            return true
        }

        return false
    }

    private func isLiveActivityMessageEvent(_ type: String) -> Bool {
        EventSyncCoordinator.isLiveActivityMessageEventType(type)
    }

    nonisolated private static func isLiveActivityMessageEventType(_ type: String) -> Bool {
        EventSyncCoordinator.isLiveActivityMessageEventType(type)
    }

    private func shouldApplyDirectoryEvent(from managed: OpenCodeManagedEvent) -> Bool {
        let eventDirectory = managed.directory
        let eventSessionID = managedEventSessionID(for: managed)

        return eventSyncCoordinator.shouldApplyDirectoryEvent(
            eventDirectory: eventDirectory,
            eventSessionID: eventSessionID,
            selectedSessionID: selectedSession?.id,
            selectedSessionDirectory: selectedSession?.directory,
            effectiveSelectedDirectory: effectiveSelectedDirectory,
            activeLiveActivitySessionIDs: activeLiveActivitySessionIDs
        )
    }

    private func managedEventSessionID(for managed: OpenCodeManagedEvent) -> String? {
        eventSyncCoordinator.sessionID(for: managed.typed)
    }

    private func triggerStreamPartHapticIfNeeded(for managed: OpenCodeManagedEvent) {
        guard shouldEmitStreamPartHaptic(for: managed) else { return }

        let now = Date()
        guard now >= nextStreamPartHapticAllowedAt else { return }

        OpenCodeHaptics.impact(.crisp)
        nextStreamPartHapticAllowedAt = now.addingTimeInterval(nextStreamPartHapticInterval())
    }

    private func shouldEmitStreamPartHaptic(for managed: OpenCodeManagedEvent) -> Bool {
        ChatStore.shouldEmitStreamPartHaptic(
            for: managed.typed,
            selectedSessionID: selectedSession?.id,
            activeChatSessionID: activeChatSessionID,
            messages: messages
        )
    }

    private func nextStreamPartHapticInterval() -> TimeInterval {
        if Double.random(in: 0 ... 1) < 0.18 {
            return Double.random(in: 0.12 ... 0.18)
        }

        return Double.random(in: 0.045 ... 0.085)
    }

    private func eventScopeSummary(for managed: OpenCodeManagedEvent) -> String {
        let selectedSessionID = selectedSession?.id ?? "nil"
        let payloadSessionID = managed.envelope.properties.sessionID ?? "nil"
        let payloadInfoSessionID = managed.envelope.properties.info?.sessionID ?? "nil"
        let partSessionID = managed.envelope.properties.part?.sessionID ?? "nil"
        return "scope event=\(managed.envelope.type) dir=\(managed.directory) selectedDir=\(debugDirectoryLabel(effectiveSelectedDirectory)) streamDir=\(debugDirectoryLabel(streamDirectory)) selectedSession=\(selectedSessionID) payloadSession=\(payloadSessionID) infoSession=\(payloadInfoSessionID) partSession=\(partSessionID)"
    }

    func debugDirectoryLabel(_ directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return "nil" }
        return directory
    }

    func debugSessionLabel(_ session: OpenCodeSession?) -> String {
        guard let session else { return "nil" }
        return "\(session.id)@\(debugDirectoryLabel(session.directory))"
    }

    private func eventAffectsActiveSession(_ managed: OpenCodeManagedEvent) -> Bool {
        eventSyncCoordinator.eventAffectsSelectedSession(
            managed.typed,
            selectedSessionID: selectedSession?.id,
            selectedMessages: messages,
            hasGitProject: hasGitProject
        )
    }

    func scheduleReload(for session: OpenCodeSession) {
        reloadTask?.cancel()

        reloadTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, self.isConnected else { return }
            self.markChatBreadcrumb("idle reconcile start", sessionID: session.id)
            do {
                try await self.loadMessages(for: session)
                self.markChatBreadcrumb("idle reconcile finish", sessionID: session.id)
            } catch {
                self.markChatBreadcrumb("idle reconcile error", sessionID: session.id)
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func stopStreamingDiagnostics() {
        isRunningDebugProbe = false
        stopDebugProbeStreams()
    }

    func debugSummary(for payload: OpenCodeEventEnvelope) -> String {
        switch payload.type {
        case "message.part.delta":
            let delta = payload.properties.delta ?? ""
            return "delta: \(delta)"
        case "message.part.updated":
            return "part: \(payload.properties.part?.type ?? "unknown")"
        case "message.updated":
            return "message: \(payload.properties.info?.role ?? "unknown")"
        default:
            return payload.type
        }
    }

    func currentAssistantTextLength() -> Int {
        chatStore.currentAssistantTextLength
    }

    func appendDebugLog(_ message: String) {
        guard isCapturingStreamingDiagnostics else { return }

        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        let stamped = "[\(formatter.string(from: Date()))] \(message)"
        debugProbeLog.append(stamped)
        if debugProbeLog.count > 400 {
            debugProbeLog.removeFirst(debugProbeLog.count - 400)
        }
#if DEBUG
        print("[OpenCodeDebug] \(stamped)")
#endif
    }

    func markChatBreadcrumb(
        _ event: String,
        sessionID: String? = nil,
        messageID: String? = nil,
        partID: String? = nil
    ) {
        guard isCapturingStreamingDiagnostics else { return }

        let breadcrumb = OpenCodeChatBreadcrumb(
            event: event,
            sessionID: sessionID,
            selectedSessionID: selectedSession?.id,
            directory: effectiveSelectedDirectory ?? streamDirectory,
            messageID: messageID,
            partID: partID,
            messageCount: messages.count,
            assistantTextLength: currentAssistantTextLength()
        )
        chatBreadcrumbs.append(breadcrumb)
        if chatBreadcrumbs.count > 80 {
            chatBreadcrumbs.removeFirst(chatBreadcrumbs.count - 80)
        }
        saveChatBreadcrumbs(chatBreadcrumbs)
    }

    func copyChatBreadcrumbs() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return chatBreadcrumbs.map { breadcrumb in
            [
                "[\(formatter.string(from: breadcrumb.createdAt))]",
                breadcrumb.event,
                "session=\(breadcrumb.sessionID ?? "nil")",
                "selected=\(breadcrumb.selectedSessionID ?? "nil")",
                "dir=\(breadcrumb.directory ?? "nil")",
                "message=\(breadcrumb.messageID ?? "nil")",
                "part=\(breadcrumb.partID ?? "nil")",
                "count=\(breadcrumb.messageCount)",
                "alen=\(breadcrumb.assistantTextLength)"
            ].joined(separator: " ")
        }.joined(separator: "\n")
    }

    func loadChatBreadcrumbs() -> [OpenCodeChatBreadcrumb] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.chatBreadcrumbs) else { return [] }
        return (try? JSONDecoder().decode([OpenCodeChatBreadcrumb].self, from: data)) ?? []
    }

    func saveChatBreadcrumbs(_ breadcrumbs: [OpenCodeChatBreadcrumb]) {
        guard let data = try? JSONEncoder().encode(breadcrumbs) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.chatBreadcrumbs)
    }

    func eventIdentitySummary(for payload: OpenCodeEventEnvelope) -> String {
        let infoID = payload.properties.info?.id ?? "nil"
        let infoRole = payload.properties.info?.role ?? "nil"
        let messageID = payload.properties.messageID ?? payload.properties.part?.messageID ?? "nil"
        let partID = payload.properties.partID ?? payload.properties.part?.id ?? "nil"
        let partType = payload.properties.part?.type ?? "nil"
        let sessionID = payload.properties.sessionID ?? payload.properties.info?.sessionID ?? payload.properties.part?.sessionID ?? "nil"
        return "event ids type=\(payload.type) session=\(sessionID) info=\(infoID):\(infoRole) message=\(messageID) part=\(partID):\(partType)"
    }

    func probeLabel(for url: URL) -> String {
        if url.path.contains("/global/") {
            return "global"
        }
        return "scoped"
    }

    static func debugRawLine(_ line: String) -> String {
        if line.isEmpty {
            return "<blank>"
        }
        return String(line.prefix(180))
    }
}
