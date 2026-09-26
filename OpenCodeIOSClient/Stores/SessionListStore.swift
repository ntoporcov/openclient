import Combine
import Foundation

enum OpenCodeWorkspaceOperation: Equatable, Sendable {
    case preparing
    case resetting
    case deleting
    case failed(String)

    var isBusy: Bool {
        switch self {
        case .preparing, .resetting, .deleting:
            return true
        case .failed:
            return false
        }
    }

    var title: String {
        switch self {
        case .preparing:
            return String(localized: "Preparing")
        case .resetting:
            return String(localized: "Resetting")
        case .deleting:
            return String(localized: "Deleting")
        case .failed:
            return String(localized: "Failed")
        }
    }
}

@MainActor
final class SessionListStore: ObservableObject {
    @Published var previews: [String: SessionPreview]
    @Published var pinnedSessionIDsByScope: [String: [String]]
    @Published var workspaceSessionsByDirectory: [String: OpenCodeWorkspaceSessionState]
    @Published var workspaceOperationsByDirectory: [String: OpenCodeWorkspaceOperation]
    @Published var pendingActionRunsBySessionID: [String: PendingOpenCodeActionRun]
    @Published var recentSessionsByDirectory: [String: [OpenCodeSession]]
    @Published var isLoadingRecentProjectSessions: Bool
    @Published var projectSessionSearchQuery: String
    @Published var projectSessionSearchResults: [RecentProjectSession]
    @Published var isSearchingProjectSessions: Bool

    struct WorkspacePage: Equatable {
        var state = OpenCodeWorkspaceSessionState()
        var nextCursor: String?
        var hasLoaded = false
        var requestID: UUID?
    }

    @Published private(set) var workspacePages: [BackendWorkspacePageKey: WorkspacePage] = [:]

    func workspacePageSessions(_ previous: [OpenCodeSession], applying canonical: [OpenCodeSession]) -> [OpenCodeSession] {
        var sessions = previous
        var indexByID = Dictionary(sessions.indices.map { (sessions[$0].id, $0) }, uniquingKeysWith: { first, _ in first })
        for session in canonical {
            if let index = indexByID[session.id] {
                sessions[index] = session
            } else {
                indexByID[session.id] = sessions.count
                sessions.append(session)
            }
        }
        return sessions
    }

    func beginWorkspacePage(_ key: BackendWorkspacePageKey, replacing: Bool) -> UUID? {
        var page = workspacePages[key] ?? WorkspacePage()
        guard replacing || !page.state.isLoading else { return nil }
        let requestID = UUID()
        page.requestID = requestID
        page.state.isLoading = true
        workspacePages[key] = page
        workspaceSessionsByDirectory[key.directory] = page.state
        return requestID
    }

    @discardableResult
    func finishWorkspacePage(_ key: BackendWorkspacePageKey, requestID: UUID, sessions: [OpenCodeSession],
                             nextCursor: String?, limit: Int, hasMore: Bool) -> Bool {
        guard var page = workspacePages[key], page.requestID == requestID else { return false }
        page.state = .init(isLoading: false, sessions: sessions,
                           sessionTotal: sessions.filter(\.isRootSession).count + (hasMore ? 1 : 0), limit: limit)
        page.nextCursor = nextCursor
        page.hasLoaded = true
        page.requestID = nil
        workspacePages[key] = page
        workspaceSessionsByDirectory[key.directory] = page.state
        return true
    }

    func failWorkspacePage(_ key: BackendWorkspacePageKey, requestID: UUID, projectsToVisible: Bool = true) {
        guard var page = workspacePages[key], page.requestID == requestID else { return }
        page.requestID = nil
        page.state.isLoading = false
        workspacePages[key] = page
        if projectsToVisible { workspaceSessionsByDirectory[key.directory] = page.state }
    }

    func removeWorkspacePage(_ key: BackendWorkspacePageKey) {
        workspacePages[key] = nil
        removeWorkspaceState(for: key.directory)
    }

    func resetWorkspacePages() {
        workspacePages = [:]
        workspaceSessionsByDirectory = [:]
        workspaceOperationsByDirectory = [:]
    }

    init(
        previews: [String: SessionPreview] = [:],
        pinnedSessionIDsByScope: [String: [String]] = [:],
        workspaceSessionsByDirectory: [String: OpenCodeWorkspaceSessionState] = [:],
        workspaceOperationsByDirectory: [String: OpenCodeWorkspaceOperation] = [:],
        pendingActionRunsBySessionID: [String: PendingOpenCodeActionRun] = [:],
        recentSessionsByDirectory: [String: [OpenCodeSession]] = [:],
        isLoadingRecentProjectSessions: Bool = false,
        projectSessionSearchQuery: String = "",
        projectSessionSearchResults: [RecentProjectSession] = [],
        isSearchingProjectSessions: Bool = false
    ) {
        self.previews = previews
        self.pinnedSessionIDsByScope = pinnedSessionIDsByScope
        self.workspaceSessionsByDirectory = workspaceSessionsByDirectory
        self.workspaceOperationsByDirectory = workspaceOperationsByDirectory
        self.pendingActionRunsBySessionID = pendingActionRunsBySessionID
        self.recentSessionsByDirectory = recentSessionsByDirectory
        self.isLoadingRecentProjectSessions = isLoadingRecentProjectSessions
        self.projectSessionSearchQuery = projectSessionSearchQuery
        self.projectSessionSearchResults = projectSessionSearchResults
        self.isSearchingProjectSessions = isSearchingProjectSessions
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

    func workspaceOperation(for directory: String) -> OpenCodeWorkspaceOperation? {
        workspaceOperationsByDirectory[directory]
    }

    func setWorkspaceOperation(_ operation: OpenCodeWorkspaceOperation?, for directory: String) {
        if let operation {
            workspaceOperationsByDirectory[directory] = operation
        } else {
            workspaceOperationsByDirectory[directory] = nil
        }
    }

    func removeWorkspaceState(for directory: String) {
        workspaceSessionsByDirectory[directory] = nil
        workspaceOperationsByDirectory[directory] = nil
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
            workspaceState.sessions[index] = workspaceState.sessions[index].merged(with: session)
        } else {
            workspaceState.sessions.insert(session, at: 0)
            workspaceState.sessionTotal = max(workspaceState.sessionTotal, workspaceState.rootSessions.count)
        }
        workspaceState.isLoading = false
        workspaceSessionsByDirectory[directory] = workspaceState
    }

    func reconcileWorkspaceSessions(with canonicalSessions: [OpenCodeSession]) -> Bool {
        var sessionsByID: [String: OpenCodeSession] = [:]
        for session in canonicalSessions {
            sessionsByID[session.id] = session
        }
        var changed = false

        for (directory, var state) in workspaceSessionsByDirectory {
            var nextSessions = state.sessions
            for index in nextSessions.indices {
                guard let canonical = sessionsByID[nextSessions[index].id] else { continue }
                let merged = nextSessions[index].merged(with: canonical)
                if merged != nextSessions[index] {
                    nextSessions[index] = merged
                    changed = true
                }
            }

            if changed, nextSessions != state.sessions {
                state.sessions = nextSessions
                workspaceSessionsByDirectory[directory] = state
            }
        }

        return changed
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
            return sessions
        }

        return sessions.filter { $0.directory == directory }
    }

    func applyDirectoryReloadSessions(_ sessions: [OpenCodeSession], scopedTo directory: String?) -> [OpenCodeSession] {
        var deduplicated: [OpenCodeSession] = []
        var indexByID: [String: Int] = [:]
        for session in sessions {
            if let index = indexByID[session.id] {
                deduplicated[index] = deduplicated[index].merged(with: session)
            } else {
                indexByID[session.id] = deduplicated.count
                deduplicated.append(session)
            }
        }
        setRecentSessions(deduplicated, for: directory)
        return self.sessions(deduplicated, scopedTo: directory)
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

    @discardableResult
    func removeRecentSession(sessionID: String) -> Bool {
        var next = recentSessionsByDirectory
        var changed = false
        for (directory, sessions) in recentSessionsByDirectory {
            let filtered = sessions.filter { $0.id != sessionID }
            if filtered.count != sessions.count {
                next[directory] = filtered
                changed = true
            }
        }
        guard changed else { return false }
        recentSessionsByDirectory = next
        return true
    }

    func setPendingActionRun(_ run: PendingOpenCodeActionRun?) {
        guard let run else { return }
        pendingActionRunsBySessionID[run.sessionID] = run
    }

    func setRecentSessions(_ sessions: [OpenCodeSession], for directory: String?) {
        recentSessionsByDirectory[Self.recentDirectoryKey(directory)] = sessions.map {
            Self.session($0, attributedToSourceDirectory: directory)
        }
    }

    func clearRecentSessions() {
        recentSessionsByDirectory = [:]
        isLoadingRecentProjectSessions = false
    }

    func recentProjectSessions(
        projects: [OpenCodeProject],
        previews: [String: SessionPreview],
        statuses: [String: String],
        hiddenActionSessionIDs: Set<String> = [],
        limit: Int = 15
    ) -> [RecentProjectSession] {
        var projectsByID: [String: OpenCodeProject] = [:]
        for project in projects {
            projectsByID[project.id] = project
        }
        var seen = Set<String>()

        return deduplicatedRecentSessions()
            .filter { $0.isRootSession && !$0.isArchived && !hiddenActionSessionIDs.contains($0.id) }
            .sorted { lhs, rhs in
                let lhsTime = Self.sortTime(for: lhs, preview: previews[lhs.id])
                let rhsTime = Self.sortTime(for: rhs, preview: previews[rhs.id])
                if lhsTime != rhsTime { return lhsTime > rhsTime }
                return lhs.id < rhs.id
            }
            .compactMap { session -> RecentProjectSession? in
                let key = "\(Self.recentDirectoryKey(session.directory)):\(session.id)"
                guard seen.insert(key).inserted else { return nil }
                let project = Self.project(for: session, projects: projects, projectsByID: projectsByID)
                return RecentProjectSession(
                    session: session,
                    projectTitle: project.map(Self.projectTitle) ?? Self.directoryTitle(session.directory),
                    preview: previews[session.id],
                    isBusy: statuses[session.id] == "busy"
                )
            }
            .prefix(limit)
            .map { $0 }
    }

    func projectsRankedByRecentSessions(
        projects: [OpenCodeProject],
        previews: [String: SessionPreview],
        hiddenActionSessionIDs: Set<String> = [],
        deletedSessionIDs: Set<String> = [],
        liveSessionsByProjectID: [String: [OpenCodeSession]] = [:]
    ) -> [OpenCodeProject] {
        let projectsByID = Dictionary(projects.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var candidatesBySessionID: [String: (session: OpenCodeSession, projectID: String, hasCachedAttribution: Bool)] = [:]
        var latestActivityByProjectID: [String: Double] = [:]

        for session in deduplicatedRecentSessions() {
            guard let project = Self.project(for: session, projects: projects, projectsByID: projectsByID) else { continue }
            candidatesBySessionID[session.id] = (session, project.id, true)
        }

        // Process global first so an uncached explicit scope wins attribution.
        let liveProjectOrder = projects.filter { $0.id == "global" } + projects.filter { $0.id != "global" }
        for project in liveProjectOrder {
            guard let sessions = liveSessionsByProjectID[project.id] else { continue }
            for session in sessions {
                if var candidate = candidatesBySessionID[session.id] {
                    candidate.session = session
                    if !candidate.hasCachedAttribution, project.id != "global" {
                        candidate.projectID = project.id
                    }
                    candidatesBySessionID[session.id] = candidate
                } else {
                    candidatesBySessionID[session.id] = (session, project.id, false)
                }
            }
        }

        for candidate in candidatesBySessionID.values {
            let session = candidate.session
            guard session.isRootSession, !session.isArchived,
                  !hiddenActionSessionIDs.contains(session.id), !deletedSessionIDs.contains(session.id) else { continue }
            latestActivityByProjectID[candidate.projectID] = max(
                latestActivityByProjectID[candidate.projectID] ?? -.infinity,
                Self.sortTime(for: session, preview: previews[session.id])
            )
        }

        return projects.enumerated().sorted { lhs, rhs in
            let lhsActivity = latestActivityByProjectID[lhs.element.id]
            let rhsActivity = latestActivityByProjectID[rhs.element.id]
            if lhsActivity != rhsActivity {
                return (lhsActivity ?? -.infinity) > (rhsActivity ?? -.infinity)
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    func projectSessionSearchResults(
        projects: [OpenCodeProject],
        previews: [String: SessionPreview],
        statuses: [String: String],
        query: String,
        hiddenActionSessionIDs: Set<String> = [],
        limit: Int = 40
    ) -> [RecentProjectSession] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else { return [] }

        let terms = trimmedQuery
            .lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
        guard !terms.isEmpty else { return [] }

        var projectsByID: [String: OpenCodeProject] = [:]
        for project in projects {
            projectsByID[project.id] = project
        }
        var seen = Set<String>()

        return deduplicatedRecentSessions()
            .filter { $0.isRootSession && !$0.isArchived && !hiddenActionSessionIDs.contains($0.id) }
            .compactMap { session -> RecentProjectSession? in
                let key = "\(Self.recentDirectoryKey(session.directory)):\(session.id)"
                guard seen.insert(key).inserted else { return nil }
                let project = Self.project(for: session, projects: projects, projectsByID: projectsByID)
                let projectTitle = project.map(Self.projectTitle) ?? Self.directoryTitle(session.directory)
                let result = RecentProjectSession(
                    session: session,
                    projectTitle: projectTitle,
                    preview: previews[session.id],
                    isBusy: statuses[session.id] == "busy"
                )
                return Self.matchesSearch(result, terms: terms) ? result : nil
            }
            .sorted { lhs, rhs in
                let lhsTime = Self.sortTime(for: lhs.session, preview: lhs.preview)
                let rhsTime = Self.sortTime(for: rhs.session, preview: rhs.preview)
                if lhsTime != rhsTime { return lhsTime > rhsTime }
                return lhs.id < rhs.id
            }
            .prefix(limit)
            .map { $0 }
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

    nonisolated static func recentDirectoryKey(_ directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return "global" }
        return directory
    }

    private static func project(for session: OpenCodeSession, projects: [OpenCodeProject], projectsByID: [String: OpenCodeProject]) -> OpenCodeProject? {
        if session.projectID == "global" {
            return projectsByID["global"]
        }
        if let directory = session.directory,
           let project = projects.first(where: { $0.worktree == directory }) {
            return project
        }
        if let projectID = session.projectID, let project = projectsByID[projectID] {
            return project
        }

        guard let directory = session.directory else {
            return projects.first { $0.id == "global" }
        }

        return projects.first { ($0.sandboxes ?? []).contains(directory) }
    }

    private func deduplicatedRecentSessions() -> [OpenCodeSession] {
        let orderedScopes = recentSessionsByDirectory.keys.sorted { lhs, rhs in
            if lhs == Self.recentDirectoryKey(nil) { return false }
            if rhs == Self.recentDirectoryKey(nil) { return true }
            return lhs < rhs
        }
        var seen = Set<String>()
        return orderedScopes.flatMap { recentSessionsByDirectory[$0] ?? [] }.filter {
            seen.insert($0.id).inserted
        }
    }

    private static func session(_ session: OpenCodeSession, attributedToSourceDirectory directory: String?) -> OpenCodeSession {
        guard directory == nil else { return session }
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

    private static func projectTitle(_ project: OpenCodeProject) -> String {
        if let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if project.id == "global" { return String(localized: "Global") }
        return directoryTitle(project.worktree)
    }

    private static func directoryTitle(_ directory: String?) -> String {
        guard let directory, !directory.isEmpty else { return String(localized: "Global") }
        return URL(fileURLWithPath: directory).lastPathComponent
    }

    private static func sortTime(for session: OpenCodeSession, preview: SessionPreview?) -> Double {
        session.time?.updated ?? session.time?.created ?? (preview?.date?.timeIntervalSince1970).map { $0 * 1_000 } ?? 0
    }

    private static func matchesSearch(_ result: RecentProjectSession, terms: [String]) -> Bool {
        let searchable = [
            result.session.title,
            result.preview?.text,
            result.projectTitle,
            result.session.directory,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
            .lowercased()

        return terms.allSatisfy { searchable.contains($0) }
    }
}

struct RecentProjectSession: Identifiable, Equatable {
    let session: OpenCodeSession
    let projectTitle: String
    let preview: SessionPreview?
    let isBusy: Bool

    var id: String {
        "\(SessionListStore.recentDirectoryKey(session.directory)):\(session.id)"
    }
}
