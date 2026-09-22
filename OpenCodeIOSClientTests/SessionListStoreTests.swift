import XCTest
@testable import OpenClient

@MainActor
final class SessionListStoreTests: XCTestCase {
    func testDefaultGeneratedRootTitleIsDetectedAndDisplayedLikeUpstream() {
        let session = OpenCodeSession(id: "ses_default", title: "New session - 2026-05-26T12:34:56.789Z", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)

        XCTAssertTrue(session.isDefaultGeneratedTitle)
        XCTAssertEqual(session.defaultGeneratedTitleDisplayName, "New session")
        XCTAssertEqual(session.displayTitle(), "New session")
    }

    func testDefaultGeneratedChildTitleIsDetectedAndDisplayedLikeUpstream() {
        let session = OpenCodeSession(id: "ses_child", title: "Child session - 2026-05-26T12:34:56.789Z", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: "ses_parent")

        XCTAssertTrue(session.isDefaultGeneratedTitle)
        XCTAssertEqual(session.defaultGeneratedTitleDisplayName, "Child session")
        XCTAssertEqual(session.displayTitle(), "Child session")
    }

    func testInvalidDefaultGeneratedTitleShapeIsNotDetected() {
        let session = OpenCodeSession(id: "ses_invalid", title: "New session - 2026-05-26", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)

        XCTAssertFalse(session.isDefaultGeneratedTitle)
        XCTAssertNil(session.defaultGeneratedTitleDisplayName)
        XCTAssertEqual(session.displayTitle(), "New session - 2026-05-26")
    }

    func testCustomSessionTitleIsDisplayedUnchanged() {
        let session = OpenCodeSession(id: "ses_custom", title: "Fix streaming title shimmer", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)

        XCTAssertFalse(session.isDefaultGeneratedTitle)
        XCTAssertEqual(session.displayTitle(), "Fix streaming title shimmer")
    }

    func testReconcileWorkspaceSessionsUpdatesStaleLiveTitleCache() {
        let store = SessionListStore()
        let stale = OpenCodeSession(id: "ses_test", title: "New session - 2026-05-26T12:34:56.789Z", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)
        let renamed = OpenCodeSession(id: "ses_test", title: "Generated title", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)
        store.finishWorkspaceSessionsLoading([stale], estimatedTotal: 1, limit: 55, directory: "/tmp/project")

        XCTAssertTrue(store.reconcileWorkspaceSessions(with: [renamed]))
        XCTAssertEqual(store.workspaceSessionsByDirectory["/tmp/project"]?.sessions.first?.title, "Generated title")
    }

    func testGlobalScopePreservesLoadedSessionsWithoutDirectoryFiltering() {
        let store = SessionListStore()
        let global = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: "/", projectID: "global", parentID: nil)
        let project = OpenCodeSession(id: "ses_project", title: "Project", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)

        XCTAssertEqual(store.sessions([global, project], scopedTo: nil), [global, project])
        XCTAssertEqual(store.sessions([global, project], scopedTo: ""), [global, project])
    }

    func testDirectoryScopeFiltersByExactDirectory() {
        let store = SessionListStore()
        let global = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: "/", projectID: "global", parentID: nil)
        let project = OpenCodeSession(id: "ses_project", title: "Project", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)

        XCTAssertEqual(store.sessions([global, project], scopedTo: "/tmp/project"), [project])
    }

    func testApplyDirectoryReloadSessionsStoresRecentsAndReturnsScopedSessions() {
        let store = SessionListStore()
        let global = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: "/", projectID: "global", parentID: nil)
        let project = OpenCodeSession(id: "ses_project", title: "Project", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)

        let visible = store.applyDirectoryReloadSessions([global, project], scopedTo: "/tmp/project")

        XCTAssertEqual(visible, [project])
        XCTAssertEqual(store.recentSessionsByDirectory["/tmp/project"], [global, project])
    }

    func testDirectoryReloadDeduplicatesSessionIDs() {
        let store = SessionListStore()
        let stale = OpenCodeSession(id: "ses_duplicate", title: "Stale", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)
        let updated = OpenCodeSession(id: "ses_duplicate", title: "Updated", workspaceID: nil, directory: "/tmp/project", projectID: "proj", parentID: nil)

        let sessions = store.applyDirectoryReloadSessions([stale, updated], scopedTo: "/tmp/project")

        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions.first?.title, "Updated")
    }

    func testRecentSessionPrefersExplicitDirectoryProjectOverRepositoryProjectID() {
        let store = SessionListStore()
        let repository = OpenCodeProject(id: "repo", worktree: "/tmp/repo", vcs: "git", name: "opencode", sandboxes: nil, icon: nil, time: nil)
        let general = OpenCodeProject(id: "local:/tmp/repo/general", worktree: "/tmp/repo/general", vcs: nil, name: "General", sandboxes: nil, icon: nil, time: nil)
        let session = OpenCodeSession(id: "session", title: "General work", workspaceID: nil, directory: general.worktree, projectID: repository.id, parentID: nil)
        store.setRecentSessions([session], for: general.worktree)

        let recent = store.recentProjectSessions(projects: [repository, general], previews: [:], statuses: [:])

        XCTAssertEqual(recent.first?.projectTitle, "General")
    }

    func testBareSessionScopeAttributesRepositorySessionToGlobalProject() {
        let store = SessionListStore()
        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        let repository = OpenCodeProject(id: "repo", worktree: "/tmp/repo", vcs: "git", name: "opencode", sandboxes: nil, icon: nil, time: nil)
        let session = OpenCodeSession(id: "session", title: "Freeing up disk space", workspaceID: nil, directory: "/tmp/repo/subdirectory", projectID: repository.id, parentID: nil)
        store.setRecentSessions([session], for: nil)

        let recent = store.recentProjectSessions(projects: [global, repository], previews: [:], statuses: [:])

        XCTAssertEqual(recent.first?.projectTitle, "Global")
        XCTAssertEqual(recent.first?.session.projectID, "global")
    }

    func testExplicitScopeWinsWhenSessionAlsoAppearsInBareScope() {
        let store = SessionListStore()
        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        let repository = OpenCodeProject(id: "repo", worktree: "/tmp/repo", vcs: "git", name: "opencode", sandboxes: nil, icon: nil, time: nil)
        let session = OpenCodeSession(id: "session", title: "Repository work", workspaceID: nil, directory: repository.worktree, projectID: repository.id, parentID: nil)
        store.setRecentSessions([session], for: nil)
        store.setRecentSessions([session], for: repository.worktree)

        let recent = store.recentProjectSessions(projects: [global, repository], previews: [:], statuses: [:])

        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.projectTitle, "opencode")
        XCTAssertEqual(recent.first?.session.projectID, repository.id)
    }

    func testRemovingRecentSessionClearsEverySourceScope() {
        let store = SessionListStore()
        let session = OpenCodeSession(id: "session", title: "Delete me", workspaceID: nil, directory: "/tmp/project", projectID: "project", parentID: nil)
        store.setRecentSessions([session], for: nil)
        store.setRecentSessions([session], for: session.directory)

        XCTAssertTrue(store.removeRecentSession(sessionID: session.id))
        XCTAssertTrue(store.recentSessionsByDirectory.values.allSatisfy(\.isEmpty))
        XCTAssertFalse(store.removeRecentSession(sessionID: session.id))
    }

    func testProjectsRankByMostRecentRootSession() {
        let store = SessionListStore()
        let first = OpenCodeProject(id: "first", worktree: "/tmp/first", vcs: "git", name: "First", sandboxes: nil, icon: nil, time: nil)
        let second = OpenCodeProject(id: "second", worktree: "/tmp/second", vcs: "git", name: "Second", sandboxes: nil, icon: nil, time: nil)
        let idle = OpenCodeProject(id: "idle", worktree: "/tmp/idle", vcs: "git", name: "Idle", sandboxes: nil, icon: nil, time: nil)
        var older = OpenCodeSession(id: "older", title: "Older", workspaceID: nil, directory: first.worktree, projectID: first.id, parentID: nil)
        older.time = .init(created: 100, updated: 200)
        var newer = OpenCodeSession(id: "newer", title: "Newer", workspaceID: nil, directory: second.worktree, projectID: second.id, parentID: nil)
        newer.time = .init(created: 300, updated: 400)
        store.setRecentSessions([older], for: first.worktree)
        store.setRecentSessions([newer], for: second.worktree)

        let ranked = store.projectsRankedByRecentSessions(projects: [first, second, idle], previews: [:])

        XCTAssertEqual(ranked.map(\.id), [second.id, first.id, idle.id])
    }

    func testProjectRankingPreservesBareScopeGlobalAttribution() {
        let store = SessionListStore()
        let repository = OpenCodeProject(id: "repo", worktree: "/tmp/repo", vcs: "git", name: "Repository", sandboxes: nil, icon: nil, time: nil)
        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        var session = OpenCodeSession(id: "global-session", title: "Global work", workspaceID: nil, directory: repository.worktree, projectID: repository.id, parentID: nil)
        session.time = .init(created: 100, updated: 200)
        store.setRecentSessions([session], for: nil)

        let ranked = store.projectsRankedByRecentSessions(projects: [repository, global], previews: [:])

        XCTAssertEqual(ranked.map(\.id), [global.id, repository.id])
    }

    func testProjectRankingPreservesInputOrderForEqualActivityAndNoHistory() {
        let store = SessionListStore()
        let first = OpenCodeProject(id: "first", worktree: "/tmp/first", vcs: "git", name: "First", sandboxes: nil, icon: nil, time: nil)
        let second = OpenCodeProject(id: "second", worktree: "/tmp/second", vcs: "git", name: "Second", sandboxes: nil, icon: nil, time: nil)
        let third = OpenCodeProject(id: "third", worktree: "/tmp/third", vcs: "git", name: "Third", sandboxes: nil, icon: nil, time: nil)
        var firstSession = OpenCodeSession(id: "first-session", title: "First", workspaceID: nil, directory: first.worktree, projectID: first.id, parentID: nil)
        firstSession.time = .init(created: 100, updated: 200)
        var secondSession = OpenCodeSession(id: "second-session", title: "Second", workspaceID: nil, directory: second.worktree, projectID: second.id, parentID: nil)
        secondSession.time = .init(created: 100, updated: 200)
        store.setRecentSessions([firstSession], for: first.worktree)
        store.setRecentSessions([secondSession], for: second.worktree)

        let ranked = store.projectsRankedByRecentSessions(projects: [first, second, third], previews: [:])
        let noHistory = SessionListStore().projectsRankedByRecentSessions(projects: [third, second, first], previews: [:])

        XCTAssertEqual(ranked.map(\.id), [first.id, second.id, third.id])
        XCTAssertEqual(noHistory.map(\.id), [third.id, second.id, first.id])
    }

    func testLiveArchivedSessionOverridesEligibleCachedSessionBeforeRanking() {
        let store = SessionListStore()
        let idle = OpenCodeProject(id: "idle", worktree: "/tmp/idle", vcs: "git", name: "Idle", sandboxes: nil, icon: nil, time: nil)
        let active = OpenCodeProject(id: "active", worktree: "/tmp/active", vcs: "git", name: "Active", sandboxes: nil, icon: nil, time: nil)
        var cached = OpenCodeSession(id: "session", title: "Cached", workspaceID: nil, directory: active.worktree, projectID: active.id, parentID: nil)
        cached.time = .init(created: 100, updated: 200)
        var archived = cached
        archived.time = .init(created: 100, updated: 300, archived: 300)
        store.setRecentSessions([cached], for: active.worktree)

        let ranked = store.projectsRankedByRecentSessions(
            projects: [idle, active],
            previews: [:],
            liveSessionsByProjectID: [active.id: [archived]]
        )

        XCTAssertEqual(ranked.map(\.id), [idle.id, active.id])
    }

    func testLiveDuplicateRetainsCachedGlobalSourceAttribution() {
        let store = SessionListStore()
        let repository = OpenCodeProject(id: "repo", worktree: "/tmp/repo", vcs: "git", name: "Repository", sandboxes: nil, icon: nil, time: nil)
        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        var cached = OpenCodeSession(id: "session", title: "Cached", workspaceID: nil, directory: repository.worktree, projectID: repository.id, parentID: nil)
        cached.time = .init(created: 100, updated: 200)
        var live = cached
        live.time = .init(created: 100, updated: 500)
        store.setRecentSessions([cached], for: nil)

        let ranked = store.projectsRankedByRecentSessions(
            projects: [repository, global],
            previews: [:],
            liveSessionsByProjectID: [repository.id: [live]]
        )

        XCTAssertEqual(ranked.map(\.id), [global.id, repository.id])
    }

    func testProjectRankingUsesPreviewFallbackAndExcludesHiddenAndChildSessions() {
        let store = SessionListStore()
        let ordinary = OpenCodeProject(id: "ordinary", worktree: "/tmp/ordinary", vcs: "git", name: "Ordinary", sandboxes: nil, icon: nil, time: nil)
        let hidden = OpenCodeProject(id: "hidden", worktree: "/tmp/hidden", vcs: "git", name: "Hidden", sandboxes: nil, icon: nil, time: nil)
        let child = OpenCodeProject(id: "child", worktree: "/tmp/child", vcs: "git", name: "Child", sandboxes: nil, icon: nil, time: nil)
        let preview = OpenCodeProject(id: "preview", worktree: "/tmp/preview", vcs: "git", name: "Preview", sandboxes: nil, icon: nil, time: nil)
        var ordinarySession = OpenCodeSession(id: "ordinary-session", title: "Ordinary", workspaceID: nil, directory: ordinary.worktree, projectID: ordinary.id, parentID: nil)
        ordinarySession.time = .init(created: 100, updated: 500)
        var hiddenSession = OpenCodeSession(id: "hidden-session", title: "Hidden", workspaceID: nil, directory: hidden.worktree, projectID: hidden.id, parentID: nil)
        hiddenSession.time = .init(created: 100, updated: 3_000)
        var childSession = OpenCodeSession(id: "child-session", title: "Child", workspaceID: nil, directory: child.worktree, projectID: child.id, parentID: "parent")
        childSession.time = .init(created: 100, updated: 4_000)
        let previewSession = OpenCodeSession(id: "preview-session", title: "Preview", workspaceID: nil, directory: preview.worktree, projectID: preview.id, parentID: nil)
        store.setRecentSessions([ordinarySession], for: ordinary.worktree)
        store.setRecentSessions([hiddenSession], for: hidden.worktree)
        store.setRecentSessions([childSession], for: child.worktree)
        store.setRecentSessions([previewSession], for: preview.worktree)

        let ranked = store.projectsRankedByRecentSessions(
            projects: [ordinary, hidden, child, preview],
            previews: [previewSession.id: SessionPreview(text: "Latest", date: Date(timeIntervalSince1970: 1))],
            hiddenActionSessionIDs: [hiddenSession.id]
        )

        XCTAssertEqual(ranked.map(\.id), [preview.id, ordinary.id, hidden.id, child.id])
    }

    func testProjectRankingFiltersTombstonesFromCachedAndLiveCandidates() {
        let store = SessionListStore()
        let idle = OpenCodeProject(id: "idle", worktree: "/tmp/idle", vcs: "git", name: "Idle", sandboxes: nil, icon: nil, time: nil)
        let cachedProject = OpenCodeProject(id: "cached", worktree: "/tmp/cached", vcs: "git", name: "Cached", sandboxes: nil, icon: nil, time: nil)
        let liveProject = OpenCodeProject(id: "live", worktree: "/tmp/live", vcs: "git", name: "Live", sandboxes: nil, icon: nil, time: nil)
        var cached = OpenCodeSession(id: "cached-session", title: "Cached", workspaceID: nil, directory: cachedProject.worktree, projectID: cachedProject.id, parentID: nil)
        cached.time = .init(created: 100, updated: 500)
        var live = OpenCodeSession(id: "live-session", title: "Live", workspaceID: nil, directory: liveProject.worktree, projectID: liveProject.id, parentID: nil)
        live.time = .init(created: 100, updated: 600)
        store.setRecentSessions([cached], for: cachedProject.worktree)

        let ranked = store.projectsRankedByRecentSessions(
            projects: [idle, cachedProject, liveProject],
            previews: [:],
            deletedSessionIDs: [cached.id, live.id],
            liveSessionsByProjectID: [liveProject.id: [live]]
        )

        XCTAssertEqual(ranked.map(\.id), [idle.id, cachedProject.id, liveProject.id])
    }
}
