import XCTest
import UIKit
import SwiftUI
@testable import OpenClient

@MainActor
final class ActivityFacadeTests: XCTestCase {
    func testRecentBucketsUseCalendarDayBoundaries() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 8, day: 15, hour: 12)))

        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-3_600), now: now, calendar: calendar), .recent)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-30 * 3_600), now: now, calendar: calendar), .yesterday)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-4 * 86_400), now: now, calendar: calendar), .lastWeek)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: now.addingTimeInterval(-8 * 86_400), now: now, calendar: calendar), .older)
        XCTAssertEqual(ActivityRecentBucket.bucket(for: nil, now: now, calendar: calendar), .older)
    }

    func testOnlyRecentBucketUsesFullContextCards() {
        XCTAssertEqual(ActivityRecentBucket.recent.rowPresentation, .fullContext)
        XCTAssertEqual(ActivityRecentBucket.yesterday.rowPresentation, .summary)
        XCTAssertEqual(ActivityRecentBucket.lastWeek.rowPresentation, .summary)
        XCTAssertEqual(ActivityRecentBucket.older.rowPresentation, .summary)
    }

    func testActivityToolAppearanceMatchesChatMapping() {
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("bash").icon, "terminal.fill")
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("bash").tint, .green)
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("read").tint, .blue)
        XCTAssertEqual(OpenCodeToolActivityAppearance.resolve("apply_patch").tint, .orange)
    }

    func testNewChatPresentationIsNotLockedToAProject() throws {
        let viewModel = AppViewModel()

        viewModel.activityFacade.presentNewChat()

        let request = try XCTUnwrap(viewModel.newProjectChatSheetRequest)
        XCTAssertNil(request.projectID)
        XCTAssertNil(request.workspaceDirectory)
        XCTAssertFalse(request.locksProject)
    }

    func testNewTalkPresentationAsksForAProject() throws {
        let viewModel = AppViewModel()
        viewModel.backendMode = .server
        viewModel.isConnected = true

        viewModel.activityFacade.presentNewTalk()

        XCTAssertEqual(viewModel.talkSessionCoordinator.phase, .choosingProject)
        XCTAssertNil(viewModel.newProjectChatSheetRequest)
        XCTAssertNil(viewModel.selectedSession)
    }

    func testSelectingTalkProjectStartsListeningBeforeCreatingSession() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "voice-project", directory: "/tmp/voice-project")
        viewModel.projects = [project]
        viewModel.backendMode = .server
        viewModel.isConnected = true
        viewModel.talkSessionCoordinator.setHoldToTalkEnabled(true)
        viewModel.talkSessionCoordinator.presentProjectSelection()

        viewModel.talkSessionCoordinator.selectProject(project)

        XCTAssertEqual(viewModel.talkSessionCoordinator.phase, .listening)
        XCTAssertEqual(viewModel.talkSessionCoordinator.selectedProjectID, project.id)
        XCTAssertNil(viewModel.selectedSession)

        viewModel.talkSessionCoordinator.applicationActivityChanged(isActive: false)
        XCTAssertEqual(viewModel.talkSessionCoordinator.conversationController.state, .ready)
        viewModel.talkSessionCoordinator.applicationActivityChanged(isActive: true)
        XCTAssertEqual(viewModel.talkSessionCoordinator.conversationController.state, .ready)

        viewModel.talkSessionCoordinator.stop()
    }

    func testPreparationHydratesCardMetadataFromPersistentCacheBeforeServerReconciliation() async throws {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project-cache", directory: "/tmp/cache")
        let session = makeSession(
            id: "cached",
            title: "Cached activity",
            directory: project.worktree,
            projectID: project.id,
            updated: 2_000
        )
        let messages = [
            makeMessage(id: "user-cache", sessionID: session.id, role: "user", text: "Restore everything"),
            makeMessage(id: "assistant-cache", sessionID: session.id, role: "assistant", text: "Restored from SwiftData"),
        ]
        let todo = OpenCodeTodo(content: "Verify cache", status: "in_progress", priority: "high")
        let permission = OpenCodePermission(
            id: "permission-cache",
            sessionID: session.id,
            permission: "bash",
            patterns: ["xcodebuild test"],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let config = OpenCodeServerConfig(
            name: "Cache Test",
            baseURL: "https://cache.example",
            username: "opencode",
            password: "password"
        )
        let repository = try OpenCodeLocalCacheRepositoryFactory.makeInMemory()
        viewModel.config = config
        viewModel.projects = [project]
        viewModel.localCacheRepository = repository
        try await repository.saveDirectorySessions(
            [session],
            serverID: config.recentServerID,
            directory: project.worktree
        )
        try await repository.saveChatMessages(
            messages,
            serverID: config.recentServerID,
            sessionID: session.id
        )
        try await repository.saveTodos(
            [todo],
            serverID: config.recentServerID,
            sessionID: session.id
        )
        let metadataDate = Date()
        try await repository.saveDirectoryMetadata(
            statuses: [session.id: "busy"],
            permissions: [permission],
            questions: [],
            serverID: config.recentServerID,
            directory: project.worktree,
            refreshedAt: metadataDate,
            writtenAt: metadataDate
        )

        XCTAssertTrue(viewModel.activityFacade.snapshot.isLoading)

        await viewModel.activityFacade.prepareForPresentation()

        let row = try XCTUnwrap(viewModel.activityFacade.snapshot.needsInputRows.first)
        XCTAssertFalse(viewModel.activityFacade.snapshot.isLoading)
        XCTAssertEqual(row.recent.session.id, session.id)
        XCTAssertEqual(row.latestUserText, "Restore everything")
        XCTAssertEqual(row.latestAssistantText, "Restored from SwiftData")
        XCTAssertTrue(row.isWorking)
        XCTAssertEqual(row.pendingInteractionCount, 1)
        XCTAssertEqual(row.statusTitle, "Needs input")
        XCTAssertEqual(row.todoCount, 1)
        XCTAssertEqual(row.completedTodoCount, 0)
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testSnapshotPlacesWorkingSessionsFirstAndUsesPerDirectoryTranscripts() {
        let viewModel = AppViewModel()
        let projectA = makeProject(id: "project-a", directory: "/tmp/a")
        let projectB = makeProject(id: "project-b", directory: "/tmp/b")
        let working = makeSession(
            id: "working",
            title: "Build release",
            directory: projectA.worktree,
            projectID: projectA.id,
            updated: 1_000
        )
        let idle = makeSession(
            id: "idle",
            title: "Review logs",
            directory: projectB.worktree,
            projectID: projectB.id,
            updated: 2_000
        )
        viewModel.projects = [projectA, projectB]
        viewModel.activeLiveActivitySessionIDs = [working.id]
        viewModel.sessionListStore.setRecentSessions([working], for: projectA.worktree)
        viewModel.sessionListStore.setRecentSessions([idle], for: projectB.worktree)

        let workingStore = viewModel.directoryStoreRegistry.store(for: projectA.worktree)
        _ = workingStore.upsertSessions([working])
        _ = workingStore.applySessionStatuses([working.id: "busy"])
        workingStore.applyCanonicalMessages(
            [
                makeMessage(id: "user-1", sessionID: working.id, role: "user", text: "Ship the release build"),
                makeMessage(id: "assistant-1", sessionID: working.id, role: "assistant", text: "Running the full test suite now"),
            ],
            forSessionID: working.id
        )

        let idleStore = viewModel.directoryStoreRegistry.store(for: projectB.worktree)
        _ = idleStore.upsertSessions([idle])
        _ = idleStore.applySessionStatuses([idle.id: "idle"])
        idleStore.applyCanonicalMessages(
            [makeMessage(id: "assistant-2", sessionID: idle.id, role: "assistant", text: "The logs look clean")],
            forSessionID: idle.id
        )

        let snapshot = viewModel.activityFacade.snapshot

        XCTAssertEqual(snapshot.workingRows.map(\.recent.session.id), [working.id])
        XCTAssertEqual(snapshot.recentRows.map(\.recent.session.id), [idle.id])
        XCTAssertEqual(snapshot.workingRows.first?.latestUserText, "Ship the release build")
        XCTAssertEqual(snapshot.workingRows.first?.latestAssistantText, "Running the full test suite now")
        XCTAssertEqual(snapshot.recentRows.first?.latestAssistantText, "The logs look clean")
        XCTAssertEqual(snapshot.projects.map(\.id), [projectA.id, projectB.id])
        XCTAssertEqual(snapshot.workingRows.first?.projectID, projectA.id)
        XCTAssertEqual(snapshot.recentRows.first?.projectID, projectB.id)
        XCTAssertTrue(snapshot.workingRows.first?.isLiveActivityActive == true)
        XCTAssertFalse(snapshot.recentRows.first?.isLiveActivityActive == true)
        XCTAssertEqual(snapshot.workingRows.first?.statusTitle, "Working")
        XCTAssertEqual(snapshot.recentRows.first?.statusTitle, "Idle")
    }

    func testSnapshotOrdersIdleSessionsByMostRecentUpdate() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let older = makeSession(id: "older", title: "Older", directory: project.worktree, projectID: project.id, updated: 1_000)
        let newer = makeSession(id: "newer", title: "Newer", directory: project.worktree, projectID: project.id, updated: 2_000)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([older, newer], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([older, newer])

        XCTAssertEqual(viewModel.activityFacade.snapshot.recentRows.map(\.recent.session.id), [newer.id, older.id])
    }

    func testSnapshotTracksSelectedActivitySession() async throws {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let session = makeSession(
            id: "selected",
            title: "Selected",
            directory: project.worktree,
            projectID: project.id,
            updated: 1_000
        )
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([session], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([session])
        let facade = viewModel.activityFacade
        let row = try XCTUnwrap(facade.snapshot.recentRows.first)

        facade.prepareSelection(row)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(facade.snapshot.selectedSessionID, session.id)
    }

    func testSnapshotOrdersWithinSectionByLatestUserMessageInsteadOfSessionUpdate() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let assistantRecentlyUpdated = makeSession(
            id: "assistant-recent",
            title: "Assistant still working",
            directory: project.worktree,
            projectID: project.id,
            updated: 3_000
        )
        let userRecentlyUpdated = makeSession(
            id: "user-recent",
            title: "New user request",
            directory: project.worktree,
            projectID: project.id,
            updated: 2_000
        )
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([assistantRecentlyUpdated, userRecentlyUpdated], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([assistantRecentlyUpdated, userRecentlyUpdated])
        store.applyCanonicalMessages(
            [makeMessage(id: "user-old", sessionID: assistantRecentlyUpdated.id, role: "user", text: "Earlier", created: 1_000)],
            forSessionID: assistantRecentlyUpdated.id
        )
        store.applyCanonicalMessages(
            [makeMessage(id: "user-new", sessionID: userRecentlyUpdated.id, role: "user", text: "Later", created: 2_000)],
            forSessionID: userRecentlyUpdated.id
        )

        XCTAssertEqual(
            viewModel.activityFacade.snapshot.recentRows.map(\.recent.session.id),
            [userRecentlyUpdated.id, assistantRecentlyUpdated.id]
        )
    }

    func testBareScopeAttributionSurvivesCanonicalRepositorySessionInDirectoryStore() {
        let viewModel = AppViewModel()
        let global = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        let repository = makeProject(id: "opencode", directory: "/tmp/opencode")
        let canonical = makeSession(
            id: "free-space",
            title: "Freeing up disk space",
            directory: "/tmp/opencode/BlueBubbles",
            projectID: repository.id,
            updated: 2_000
        )
        viewModel.projects = [global, repository]
        viewModel.sessionListStore.setRecentSessions([canonical], for: nil)
        let globalStore = viewModel.directoryStoreRegistry.store(for: nil)
        _ = globalStore.upsertSessions([canonical])

        let row = viewModel.activityFacade.snapshot.recentRows.first

        XCTAssertEqual(row?.recent.projectTitle, "Global")
        XCTAssertEqual(row?.projectID, "global")
        XCTAssertEqual(row?.recent.session.projectID, "global")
        XCTAssertTrue(row?.usesGlobalProjectAvatar == true)
    }

    func testNeedsInputSectionTakesPrecedenceOverWorking() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let blocked = makeSession(id: "blocked", title: "Blocked", directory: project.worktree, projectID: project.id, updated: 2_000)
        let working = makeSession(id: "working", title: "Working", directory: project.worktree, projectID: project.id, updated: 1_000)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([blocked, working], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([blocked, working])
        _ = store.applySessionStatuses([blocked.id: "busy", working.id: "busy"])
        store.syncState.permissionsBySessionID[blocked.id] = [
            OpenCodePermission(
                id: "permission",
                sessionID: blocked.id,
                permission: "bash",
                patterns: ["rm"],
                always: nil,
                metadata: nil,
                tool: nil
            ),
        ]

        let snapshot = viewModel.activityFacade.snapshot

        XCTAssertEqual(snapshot.needsInputRows.map(\.id), ["/tmp/project:blocked"])
        XCTAssertEqual(snapshot.workingRows.map(\.id), ["/tmp/project:working"])
        XCTAssertTrue(snapshot.recentRows.isEmpty)
        XCTAssertEqual(snapshot.needsInputRows.first?.statusTitle, "Needs input")
    }

    func testSnapshotFlattensMarkdownAndIncludesRunningTools() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let session = makeSession(id: "session", title: "Streaming", directory: project.worktree, projectID: project.id, updated: 2_000)
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([session], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([session])
        _ = store.applySessionStatuses([session.id: "busy"])
        store.applyCanonicalMessages(
            [
                makeMessage(id: "assistant", sessionID: session.id, role: "assistant", text: "**Checking**\n`disk usage`"),
                makeToolMessage(id: "tool", sessionID: session.id),
            ],
            forSessionID: session.id
        )

        let row = viewModel.activityFacade.snapshot.workingRows.first

        XCTAssertEqual(row?.latestAssistantText, "Checking · disk usage")
        XCTAssertEqual(row?.runningTools.first?.tool, "bash")
        XCTAssertEqual(row?.runningTools.first?.title, "Checking disk space")
        XCTAssertEqual(row?.runningTools.first?.detail, "du -sh ~")
    }

    func testSnapshotHidesRunningToolWhenNewerTextIsLatestAndPreservesTextForLayout() {
        let viewModel = AppViewModel()
        let project = makeProject(id: "project", directory: "/tmp/project")
        let session = makeSession(id: "session", title: "Streaming", directory: project.worktree, projectID: project.id, updated: 2_000)
        let finalText = String(repeating: "old ", count: 100) + "latest streaming news"
        viewModel.projects = [project]
        viewModel.sessionListStore.setRecentSessions([session], for: project.worktree)
        let store = viewModel.directoryStoreRegistry.store(for: project.worktree)
        _ = store.upsertSessions([session])
        _ = store.applySessionStatuses([session.id: "busy"])
        store.applyCanonicalMessages(
            [
                makeToolMessage(id: "a-tool", sessionID: session.id),
                makeMessage(id: "z-text", sessionID: session.id, role: "assistant", text: finalText),
            ],
            forSessionID: session.id
        )

        let row = viewModel.activityFacade.snapshot.workingRows.first

        XCTAssertTrue(row?.runningTools.isEmpty == true)
        XCTAssertEqual(row?.latestAssistantText, finalText)
    }

    func testPreviewTextFlattensMarkdownListsAndKeepsNewestTextWhenLimited() {
        let markdown = """
        # Summary
        - First item
        - [x] Fixed issue
        1. Latest sentence
        """

        XCTAssertEqual(
            opencodePreviewText(markdown, limit: nil),
            "Summary · First item · Fixed issue · Latest sentence"
        )
        XCTAssertEqual(opencodePreviewText(markdown, limit: 20), "…e · Latest sentence")
    }

    func testSessionPreviewFlattensListsAndKeepsLatestSentence() {
        let viewModel = AppViewModel()
        let text = String(repeating: "Older context ", count: 12) + "\n- First result\n- Latest sentence"

        let preview = viewModel.buildSessionPreview(
            from: [makeMessage(id: "assistant", sessionID: "session", role: "assistant", text: text)]
        )

        XCTAssertTrue(preview.text.hasPrefix("…"))
        XCTAssertTrue(preview.text.hasSuffix("First result · Latest sentence"))
        XCTAssertFalse(preview.text.contains(String(repeating: "Older context ", count: 10)))
    }

    func testActivityTailPreviewStartsFirstLineWithEllipsisAndFillsTwoLines() {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let source = String(repeating: "older words ", count: 20) + "the latest streaming sentence"
        let fitted = ActivityTailPreview.fittingText(source, width: 180, font: font)
        let height = (fitted as NSString).boundingRect(
            with: CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height
        let twoLineHeight = ("Ag\nAg" as NSString).boundingRect(
            with: CGSize(width: 180, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font],
            context: nil
        ).height

        XCTAssertTrue(fitted.hasPrefix("…"))
        XCTAssertTrue(fitted.hasSuffix("the latest streaming sentence"))
        XCTAssertGreaterThan(height, font.lineHeight)
        XCTAssertLessThanOrEqual(height, twoLineHeight)
    }

    func testActivityTailPreviewFillsTwoLinesWhenOlderTextContainsLongPath() {
        let font = UIFont.preferredFont(forTextStyle: .subheadline)
        let source = "Checked /Applications/Xcode-beta.app/Contents/Developer/Platforms/iPhoneSimulator.platform and verified every deterministic preview. The newest sentence remains visible."
        let fitted = ActivityTailPreview.fittingText(source, width: 300, font: font)
        let paragraphStyle = NSMutableParagraphStyle()
        paragraphStyle.lineBreakMode = .byCharWrapping
        let height = (fitted as NSString).boundingRect(
            with: CGSize(width: 300, height: CGFloat.greatestFiniteMagnitude),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: font, .paragraphStyle: paragraphStyle],
            context: nil
        ).height

        XCTAssertTrue(fitted.hasPrefix("…"))
        XCTAssertTrue(fitted.hasSuffix("The newest sentence remains visible."))
        XCTAssertGreaterThan(height, font.lineHeight)
    }

    private func makeProject(id: String, directory: String) -> OpenCodeProject {
        OpenCodeProject(
            id: id,
            worktree: directory,
            vcs: "git",
            name: id,
            sandboxes: nil,
            icon: nil,
            time: nil
        )
    }

    private func makeSession(
        id: String,
        title: String,
        directory: String,
        projectID: String,
        updated: Double
    ) -> OpenCodeSession {
        var session = OpenCodeSession(
            id: id,
            title: title,
            workspaceID: nil,
            directory: directory,
            projectID: projectID,
            parentID: nil
        )
        session.time = OpenCodeMessageTime(created: updated, updated: updated, completed: nil, archived: nil)
        return session
    }

    private func makeMessage(
        id: String,
        sessionID: String,
        role: String,
        text: String,
        created: Double? = nil
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: created.map { OpenCodeMessageTime(created: $0) },
                agent: nil,
                model: nil
            ),
            parts: [
                OpenCodePart(
                    id: "part-\(id)",
                    messageID: id,
                    sessionID: sessionID,
                    type: "text",
                    mime: nil,
                    filename: nil,
                    url: nil,
                    reason: nil,
                    tool: nil,
                    callID: nil,
                    state: nil,
                    text: text
                ),
            ]
        )
    }

    private func makeToolMessage(id: String, sessionID: String) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: "assistant", sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(
                    id: "part-\(id)",
                    messageID: id,
                    sessionID: sessionID,
                    type: "tool",
                    mime: nil,
                    filename: nil,
                    url: nil,
                    reason: nil,
                    tool: "bash",
                    callID: "call-\(id)",
                    state: OpenCodeToolState(
                        status: "running",
                        title: "Checking disk space",
                        error: nil,
                        input: OpenCodeToolInput(
                            command: "du -sh ~",
                            description: nil,
                            filePath: nil,
                            name: nil,
                            path: nil,
                            query: nil,
                            pattern: nil,
                            subagentType: nil,
                            url: nil
                        ),
                        output: nil,
                        metadata: nil
                    ),
                    text: nil
                ),
            ]
        )
    }
}
