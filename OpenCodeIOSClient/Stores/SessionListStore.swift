import Combine
import Foundation

@MainActor
final class SessionListStore: ObservableObject {
    @Published var previews: [String: SessionPreview]
    @Published var pinnedSessionIDsByScope: [String: [String]]
    @Published var workspaceSessionsByDirectory: [String: OpenCodeWorkspaceSessionState]
    @Published var pendingActionRunsBySessionID: [String: PendingOpenCodeActionRun]

    init(
        previews: [String: SessionPreview] = [:],
        pinnedSessionIDsByScope: [String: [String]] = [:],
        workspaceSessionsByDirectory: [String: OpenCodeWorkspaceSessionState] = [:],
        pendingActionRunsBySessionID: [String: PendingOpenCodeActionRun] = [:]
    ) {
        self.previews = previews
        self.pinnedSessionIDsByScope = pinnedSessionIDsByScope
        self.workspaceSessionsByDirectory = workspaceSessionsByDirectory
        self.pendingActionRunsBySessionID = pendingActionRunsBySessionID
    }

    func setPreview(_ preview: SessionPreview, for sessionID: String) -> Bool {
        guard previews[sessionID] != preview else { return false }
        previews[sessionID] = preview
        return true
    }

    func removePreview(for sessionID: String) {
        previews[sessionID] = nil
    }

    func setPinnedSessionIDs(_ sessionIDs: [String], for scopeKey: String) {
        var deduplicated: [String] = []
        var seen = Set<String>()

        for sessionID in sessionIDs where seen.insert(sessionID).inserted {
            deduplicated.append(sessionID)
        }

        if deduplicated.isEmpty {
            pinnedSessionIDsByScope[scopeKey] = nil
        } else {
            pinnedSessionIDsByScope[scopeKey] = deduplicated
        }
    }

    func removePinnedSessionIDFromAllScopes(_ sessionID: String) -> Bool {
        var next = pinnedSessionIDsByScope

        for (key, ids) in pinnedSessionIDsByScope {
            let filtered = ids.filter { $0 != sessionID }
            if filtered.isEmpty {
                next[key] = nil
            } else {
                next[key] = filtered
            }
        }

        guard next != pinnedSessionIDsByScope else { return false }
        pinnedSessionIDsByScope = next
        return true
    }

    func session(matching sessionID: String, visibleSessions: [OpenCodeSession], selectedSession: OpenCodeSession?) -> OpenCodeSession? {
        if let selectedSession, selectedSession.id == sessionID {
            return selectedSession
        }

        if let session = visibleSessions.first(where: { $0.id == sessionID }) {
            return session
        }

        return workspaceSessionsByDirectory.values
            .lazy
            .flatMap(\.sessions)
            .first(where: { $0.id == sessionID })
    }

    func childSessions(for sessionID: String, visibleSessions: [OpenCodeSession]) -> [OpenCodeSession] {
        let workspaceChildren = workspaceSessionsByDirectory.values.flatMap(\.sessions).filter { $0.parentID == sessionID }
        if !workspaceChildren.isEmpty { return workspaceChildren }
        return visibleSessions.filter { $0.parentID == sessionID }
    }

    func setWorkspaceSessionState(_ state: OpenCodeWorkspaceSessionState, for directory: String) {
        workspaceSessionsByDirectory[directory] = state
    }

    func workspaceSessionState(for directory: String) -> OpenCodeWorkspaceSessionState {
        workspaceSessionsByDirectory[directory] ?? OpenCodeWorkspaceSessionState()
    }

    func increaseWorkspaceSessionLimit(for directory: String, by amount: Int) {
        var state = workspaceSessionState(for: directory)
        state.limit += amount
        workspaceSessionsByDirectory[directory] = state
    }

    func markWorkspaceSessionsLoading(for directory: String) -> OpenCodeWorkspaceSessionState? {
        var state = workspaceSessionState(for: directory)
        if state.isLoading { return nil }
        state.isLoading = true
        workspaceSessionsByDirectory[directory] = state
        return state
    }

    func finishWorkspaceSessionsLoading(_ loaded: [OpenCodeSession], estimatedTotal: Int, limit: Int, directory: String) {
        workspaceSessionsByDirectory[directory] = OpenCodeWorkspaceSessionState(
            isLoading: false,
            sessions: loaded,
            sessionTotal: estimatedTotal,
            limit: limit
        )
    }

    func failWorkspaceSessionsLoading(previousState: OpenCodeWorkspaceSessionState, directory: String) {
        var state = previousState
        state.isLoading = false
        workspaceSessionsByDirectory[directory] = state
    }

    func upsertWorkspaceSession(_ session: OpenCodeSession) {
        guard let directory = session.directory, !directory.isEmpty else { return }
        var workspaceState = workspaceSessionsByDirectory[directory] ?? OpenCodeWorkspaceSessionState()
        if let index = workspaceState.sessions.firstIndex(where: { $0.id == session.id }) {
            workspaceState.sessions[index] = session
        } else {
            workspaceState.sessions.insert(session, at: 0)
            workspaceState.sessionTotal = max(workspaceState.sessionTotal, workspaceState.rootSessions.count)
        }
        workspaceState.isLoading = false
        workspaceSessionsByDirectory[directory] = workspaceState
    }

    func ensureWorkspaceStateExists(for directory: String, defaultState: OpenCodeWorkspaceSessionState = OpenCodeWorkspaceSessionState()) {
        workspaceSessionsByDirectory[directory] = workspaceSessionsByDirectory[directory] ?? defaultState
    }

    func upsertVisibleSession(_ session: OpenCodeSession, visibleSessions: inout [OpenCodeSession]) {
        if let index = visibleSessions.firstIndex(where: { $0.id == session.id }) {
            visibleSessions[index] = session
        } else {
            visibleSessions.insert(session, at: 0)
        }

        upsertWorkspaceSession(session)
    }

    func sessions(_ sessions: [OpenCodeSession], scopedTo directory: String?) -> [OpenCodeSession] {
        guard let directory, !directory.isEmpty else {
            return sessions.filter { session in
                guard let sessionDirectory = session.directory else { return true }
                return sessionDirectory.isEmpty
            }
        }

        return sessions.filter { $0.directory == directory }
    }

    func mergeSessions(_ sessions: [OpenCodeSession], into visibleSessions: inout [OpenCodeSession]) {
        for session in sessions {
            if let index = visibleSessions.firstIndex(where: { $0.id == session.id }) {
                visibleSessions[index] = visibleSessions[index].merged(with: session)
            } else {
                visibleSessions.append(session)
            }
        }
    }

    func removeSessionFromWorkspaceStates(sessionID: String) {
        for (directory, var state) in workspaceSessionsByDirectory {
            let previousCount = state.sessions.count
            state.sessions.removeAll { $0.id == sessionID }
            if state.sessions.count != previousCount {
                state.sessionTotal = max(0, state.sessionTotal - (previousCount - state.sessions.count))
                workspaceSessionsByDirectory[directory] = state
            }
        }
    }

    func setPendingActionRun(_ run: PendingOpenCodeActionRun?) {
        guard let run else { return }
        pendingActionRunsBySessionID[run.sessionID] = run
    }

    func pendingActionRun(for sessionID: String) -> PendingOpenCodeActionRun? {
        pendingActionRunsBySessionID[sessionID]
    }

    func updatePendingActionRun(for sessionID: String, mutate: (inout PendingOpenCodeActionRun) -> Bool) {
        guard var run = pendingActionRunsBySessionID[sessionID] else { return }
        if mutate(&run) {
            pendingActionRunsBySessionID[sessionID] = run
        } else {
            pendingActionRunsBySessionID[sessionID] = nil
        }
    }
}
