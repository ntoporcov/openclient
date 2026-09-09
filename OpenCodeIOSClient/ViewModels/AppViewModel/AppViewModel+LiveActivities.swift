import Foundation

extension AppViewModel {
    func toggleLiveActivity(for session: OpenCodeSession) async {
        await liveActivityFacade.toggle(session: session)
    }

    func startLiveActivity(for session: OpenCodeSession, userVisibleErrors: Bool = true) async {
        await liveActivityFacade.start(session: session, userVisibleErrors: userVisibleErrors)
    }

    func maybeAutoStartLiveActivity(for session: OpenCodeSession) async {
        await liveActivityFacade.autoStartIfEnabled(session: session)
    }

    func reconcileLiveActivities() {
        liveActivityFacade.reconcile()
    }

    func scheduleLiveActivityPreviewRefreshIfNeeded(for sessionID: String?) {
        liveActivityFacade.scheduleCanonicalHydrationIfNeeded(sessionID: sessionID)
    }

    func stopLiveActivity(for session: OpenCodeSession, immediate: Bool = false) async {
        await liveActivityFacade.stop(sessionID: session.id, immediate: immediate)
    }

    func stopLiveActivity(for sessionID: String, immediate: Bool = false) async {
        await liveActivityFacade.stop(sessionID: sessionID, immediate: immediate)
    }

    nonisolated static func shouldScheduleLiveActivityRefresh(
        pendingRefreshExists: Bool,
        immediate: Bool,
        endIfIdle: Bool
    ) -> Bool {
        !pendingRefreshExists && !immediate && !endIfIdle
    }

    func refreshLiveActivityIfNeeded(
        for sessionID: String? = nil,
        endIfIdle: Bool = false,
        immediate: Bool = false
    ) {
        liveActivityFacade.refresh(sessionID: sessionID, endIfIdle: endIfIdle, immediate: immediate)
    }

    func handleLiveActivityURL(_ url: URL) async {
        await liveActivityFacade.handleDeepLink(url)
    }

    func isLiveActivityActive(for session: OpenCodeSession) -> Bool {
        liveActivityFacade.isActive(sessionID: session.id)
    }

    #if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
    func liveActivityTranscriptLines(for session: OpenCodeSession) -> [OpenCodeChatActivityLine] {
        liveActivityFacade.transcriptLines(for: session)
    }
    #endif

    func openLiveActivitySession(
        _ deepLink: LiveActivityDeepLink,
        lifetime: LiveActivityStore.Lifetime,
        isCurrentRequest: @MainActor () -> Bool
    ) async {
        guard isCurrentRequest(), let connection = backendConnection,
              let adapter = connection.openCodeCompatibility else { return }
        let navigationGeneration = sessionNavigationGeneration
        guard let scope = liveActivityFacade.restorationScope(for: deepLink) else { return }
        let client = adapter.client
        func isCurrent() -> Bool {
            isCurrentRequest() && isCurrentBackendConnection(connection)
                && liveActivityFacade.currentLifetime == lifetime && sessionNavigationGeneration == navigationGeneration
        }
        do {
            // OS attributes locate a session; they never seed canonical navigation or authorize a reply.
            let session = try await connection.sessions.session(id: deepLink.sessionID, scope: scope)
            guard isCurrent(), liveActivityFacade.matchesRestoredSession(session, link: deepLink) else { return }
            let requestDirectory = lifetime.owner.profile == .legacy && session.projectID == "global" ? nil : session.directory
            switch deepLink.action {
            case .open:
                break
            case let .permission(requestID, reply):
                guard ["once", "always", "reject"].contains(reply) else { return }
                let permissions: [OpenCodePermission]
                if lifetime.owner.profile == .v2 {
                    permissions = try await client.listV2SessionPermissions(sessionID: session.id)
                } else {
                    permissions = try await client.listPermissions(directory: requestDirectory, workspaceID: session.workspaceID)
                }
                guard isCurrent(), permissions.contains(where: { $0.id == requestID && $0.sessionID == session.id }) else { return }
                if lifetime.owner.profile == .v2 {
                    try await client.replyToV2Permission(sessionID: session.id, requestID: requestID, reply: reply)
                } else {
                    try await client.replyToPermission(requestID: requestID, reply: reply, directory: requestDirectory, workspaceID: session.workspaceID)
                }
            case let .question(requestID, answer):
                guard lifetime.owner.profile == .legacy else { return }
                let questions = try await client.listQuestions(directory: requestDirectory, workspaceID: session.workspaceID)
                guard isCurrent(), questions.contains(where: { $0.id == requestID && $0.sessionID == session.id }) else { return }
                try await client.replyToQuestion(requestID: requestID, answers: [[answer]], directory: requestDirectory, workspaceID: session.workspaceID)
            }
            guard isCurrent() else { return }
            if let navigate = liveActivityFacade.navigateForRestoration {
                await navigate(session)
                return
            }
            // Commit the explicit route synchronously while the request still owns this lifetime.
            currentProject = projects.first { $0.id == session.projectID }
                ?? session.directory.flatMap(projectContainingDirectory)
            selectedProjectContentTab = .sessions
            prepareDirectorySelection(session.directory)
            upsertVisibleSession(session)
            chatDetailPresentationRequest &+= 1
            await selectSession(session)
        } catch {
            guard isCurrent() else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func projectContainingDirectory(_ directory: String) -> OpenCodeProject? {
        let key = workspaceKey(directory)
        return projects.first { project in
            guard project.id != "global" else { return false }
            if workspaceKey(project.worktree) == key { return true }
            return project.sandboxes?.contains { workspaceKey($0) == key } == true
        }
    }
}
