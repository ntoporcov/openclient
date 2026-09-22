import Combine
import Foundation
import XCTest
#if canImport(UIKit)
import UIKit
#endif
@testable import OpenClient

@MainActor
final class FeatureFacadeTests: XCTestCase {
    func testPendingSelectionCannotOpenASessionDeletedBeforeHandoff() {
        let model = AppViewModel()
        let session = OpenCodeSession(id: "pending", title: "Pending", workspaceID: nil,
            directory: nil, projectID: "global", parentID: nil)
        model.allSessions = [session]
        let facade = model.sessionListFacade
        let context = facade.selectionContextID
        XCTAssertEqual(facade.sessionForSelection(id: session.id, context: context), session)
        model.allSessions = []
        XCTAssertNil(facade.sessionForSelection(id: session.id, context: context))
        XCTAssertNil(model.selectedSession)
    }

    func testOptimisticSelectionFeedbackPrecedesCommitAndSurvivesRelease() {
        let feedback = SessionSelectionFeedback()
        feedback.press("first")
        XCTAssertEqual(feedback.sessionID, "first")
        feedback.commit("first")
        feedback.release("first")
        XCTAssertEqual(feedback.sessionID, "first")
        feedback.press("second")
        feedback.release("first")
        XCTAssertEqual(feedback.sessionID, "second")
        feedback.release("second")
        XCTAssertNil(feedback.sessionID, "Cancelling a press restores the canonical row selection")
    }

    func testDelayedReleaseCannotClearANewerPressOnTheSameRow() async {
        let feedback = SessionSelectionFeedback()
        feedback.press("first")
        feedback.releaseAfterActivation("first")
        feedback.press("first")
        let released = expectation(description: "Deferred release processed")
        DispatchQueue.main.async { released.fulfill() }
        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(feedback.sessionID, "first")
        feedback.reset()
        XCTAssertNil(feedback.sessionID)
    }

    func testReplacementSelectionLoadCancelsThePreviousLoad() async {
        let feedback = SessionSelectionFeedback()
        let started = expectation(description: "First load started")
        let cancelled = expectation(description: "Superseded load cancelled")
        feedback.load {
            started.fulfill()
            do {
                try await Task.sleep(for: .seconds(60))
                XCTFail("Superseded load should not finish")
            } catch {
                XCTAssertTrue(Task.isCancelled)
                cancelled.fulfill()
            }
        }
        await fulfillment(of: [started], timeout: 1)
        feedback.press("second")
        feedback.commit("second")
        feedback.load {}
        await fulfillment(of: [cancelled], timeout: 1)
        XCTAssertEqual(feedback.sessionID, "second")
    }

    #if canImport(UIKit)
    func testNativeSelectionInputAttachesToCellWithoutDelayingItsButton() async throws {
        let feedback = SessionSelectionFeedback()
        let surface = SessionSelectionSurfaceView(frame: CGRect(x: 0, y: 0, width: 300, height: 70))
        surface.bind(sessionID: "first", canonicalSelection: false, feedback: feedback)
        let cell = UICollectionViewCell(frame: surface.frame)
        cell.contentView.addSubview(surface)
        let controller = UIViewController()
        controller.view.addSubview(cell)
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 400, height: 600))
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        surface.layoutIfNeeded()
        let recognizer = try XCTUnwrap(cell.gestureRecognizers?.first { $0.name == "openclient.selectionFeedback" })
        XCTAssertFalse(recognizer.cancelsTouchesInView)
        XCTAssertFalse(recognizer.delaysTouchesBegan)
        XCTAssertFalse(recognizer.delaysTouchesEnded)

        surface.beginNativePress()
        XCTAssertEqual(feedback.sessionID, "first")
        XCTAssertTrue(surface.showsSelection)
        surface.endNativePress()
        feedback.commit("first")
        let released = expectation(description: "Native release processed")
        DispatchQueue.main.async { released.fulfill() }
        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(feedback.sessionID, "first")

        surface.bind(sessionID: "reused", canonicalSelection: false, feedback: feedback)
        surface.beginNativePress()
        XCTAssertEqual(feedback.sessionID, "reused")
        surface.removeFromSuperview()
        XCTAssertNil(recognizer.view, "Recycled rows must detach their input observer")
        let detached = expectation(description: "Cancelled native press processed")
        DispatchQueue.main.async { detached.fulfill() }
        await fulfillment(of: [detached], timeout: 1)
        XCTAssertNil(feedback.sessionID)
    }

    func testSelectionOutlineChangesSynchronouslyWithoutARowRender() {
        let feedback = SessionSelectionFeedback()
        let first = SessionSelectionSurfaceView()
        let second = SessionSelectionSurfaceView()
        for surface in [first, second] {
            surface.selectedBorderWidth = 2
            surface.selectedBorder = .blue
            surface.normalBorder = .gray
        }
        first.bind(sessionID: "first", canonicalSelection: true, feedback: feedback)
        second.bind(sessionID: "second", canonicalSelection: false, feedback: feedback)
        XCTAssertEqual(first.layer.borderWidth, 2)

        feedback.press("second")

        XCTAssertFalse(first.showsSelection)
        XCTAssertTrue(second.showsSelection)
        XCTAssertEqual(first.layer.borderWidth, 1)
        XCTAssertEqual(second.layer.borderWidth, 2)
        XCTAssertEqual(second.layer.borderColor, UIColor.blue.cgColor)
        XCTAssertNil(second.layer.animationKeys())

        // A stale SwiftUI update cannot undo optimistic drawing while navigation catches up.
        second.bind(sessionID: "second", canonicalSelection: false, feedback: feedback)
        XCTAssertTrue(second.showsSelection)
        feedback.commit("second")
        first.bind(sessionID: "first", canonicalSelection: false, feedback: feedback)
        second.bind(sessionID: "second", canonicalSelection: true, feedback: feedback)
        feedback.reset()
        XCTAssertFalse(first.showsSelection)
        XCTAssertTrue(second.showsSelection)
        feedback.press("first")
        feedback.release("first")
        XCTAssertFalse(first.showsSelection)
        XCTAssertTrue(second.showsSelection)
    }

    func testSelectionHandoffLeavesAFrameForFeedbackAndCoalescesClicks() {
        let handoff = OpenCodeDisplayFrameHandoff()
        var selected: String?
        handoff.schedule { selected = "first" }
        handoff.advanceFrame()
        XCTAssertNil(selected)
        handoff.schedule { selected = "second" }
        handoff.advanceFrame()
        XCTAssertNil(selected)
        handoff.advanceFrame()
        XCTAssertEqual(selected, "second")
        handoff.schedule { selected = "cancelled" }
        handoff.cancel()
        handoff.advanceFrame()
        handoff.advanceFrame()
        XCTAssertEqual(selected, "second")
    }
    #endif

    func testFunAndGamesDefaultsHidden() {
        XCTAssertFalse(FunAndGamesPreferences().showsSection)
    }

    func testSessionRelativeTimeNeverUsesSeconds() {
        let now = Date(timeIntervalSince1970: 10_000)

        XCTAssertEqual(SessionRelativeTimeText.label(for: now.addingTimeInterval(-20), at: now), "Now")
        XCTAssertEqual(SessionRelativeTimeText.label(for: now.addingTimeInterval(-90), at: now), "1m ago")
        XCTAssertEqual(SessionRelativeTimeText.label(for: now.addingTimeInterval(-3_600), at: now), "1h ago")
    }

    func testSessionListShimmersGeneratedTitleOnlyWhileSessionIsBusy() {
        let session = OpenCodeSession(
            id: "session",
            title: "New session - 2026-08-04T12:00:00.000Z",
            workspaceID: nil,
            directory: nil,
            projectID: "global",
            parentID: nil
        )
        let idleViewModel = AppViewModel()
        idleViewModel.allSessions = [session]
        let busyViewModel = AppViewModel()
        busyViewModel.allSessions = [session]
        busyViewModel.sessionStatuses = [session.id: "busy"]

        XCTAssertFalse(idleViewModel.sessionListFacade.snapshot.unpinnedRows[0].shimmersTitle)
        XCTAssertTrue(busyViewModel.sessionListFacade.snapshot.unpinnedRows[0].shimmersTitle)
    }

    func testSessionListProjectsPreviewIntoSelectedActivityCardStyle() {
        let viewModel = AppViewModel()
        let previousStyle = viewModel.appCustomizationStore.sessionCardStyle
        defer { viewModel.appCustomizationStore.setSessionCardStyle(previousStyle) }
        let session = OpenCodeSession(
            id: "session-activity-card",
            title: "Detailed session",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        viewModel.appCustomizationStore.setSessionCardStyle(.activity)
        viewModel.allSessions = [session]
        viewModel.sessionPreviews[session.id] = SessionPreview(text: "Latest assistant reply", date: Date())

        let snapshot = viewModel.sessionListFacade.snapshot
        let row = snapshot.unpinnedRows[0]

        XCTAssertEqual(snapshot.cardStyle, .activity)
        XCTAssertEqual(row.activityRow.latestAssistantText, "Latest assistant reply")
        XCTAssertEqual(row.activityRow.recent.session.id, session.id)
    }

    func testStableUIKitMenuCoordinatorReusesUnchangedMenu() {
        #if canImport(UIKit)
        let coordinator = StableUIKitMenuCoordinator(onSelect: { _ in })
        let elements = [StablePickerMenuElement.action(
            id: "model",
            title: "Model",
            systemImage: "cpu",
            isSelected: false
        )]

        let initialMenu = coordinator.menuIfChanged(for: elements)
        XCTAssertNotNil(initialMenu)
        XCTAssertTrue(initialMenu?.children.first is UIDeferredMenuElement)
        XCTAssertNil(coordinator.menuIfChanged(for: elements))
        XCTAssertNotNil(coordinator.menuIfChanged(for: [
            .action(id: "model", title: "Model", systemImage: "cpu", isSelected: true),
        ]))
        #endif
    }

    func testMCPFacadeSnapshotContainsOnlyMCPState() {
        let store = MCPStore(
            statuses: [
                "zeta": OpenCodeMCPStatus(status: "disabled", error: nil),
                "alpha": OpenCodeMCPStatus(status: "connected", error: nil),
            ],
            isReady: true,
            isLoading: true,
            togglingServerNames: ["alpha"]
        )
        let facade = MCPFacade(
            store: store,
            clientProvider: { OpenCodeAPIClient(config: OpenCodeServerConfig()) },
            directoryProvider: { "/tmp/project" }
        )

        let snapshot = facade.snapshot

        XCTAssertEqual(snapshot.servers.map(\.name), ["alpha", "zeta"])
        XCTAssertEqual(snapshot.connectedServerCount, 1)
        XCTAssertTrue(snapshot.isLoading)
        XCTAssertEqual(snapshot.togglingServerNames, ["alpha"])
    }

    func testProjectFilesFacadeBuildsPreparedSnapshot() {
        let path = "Sources/App.swift"
        let directory = makeFileNode(
            name: "Sources",
            path: "Sources",
            absolute: "/tmp/project/Sources",
            type: "directory"
        )
        let file = makeFileNode(
            name: "App.swift",
            path: path,
            absolute: "/tmp/project/\(path)"
        )
        let store = ProjectFilesStore(
            vcsInfo: OpenCodeVCSInfo(branch: "feature", defaultBranch: "main"),
            vcsFileStatuses: [
                OpenCodeVCSFileStatus(path: path, added: 3, removed: 1, status: "modified"),
            ],
            vcsDiffsByMode: [
                .git: [OpenCodeVCSFileDiff(file: path, patch: "@@", additions: 3, deletions: 1, status: "modified")],
            ],
            selectedVCSFile: path,
            fileTreeRootNodes: [directory],
            fileTreeChildrenByParentPath: [directory.absolute: [file]],
            expandedFileTreeDirectories: [directory.absolute],
            selectedFilePath: path,
            fileContentsByPath: [
                path: OpenCodeFileContent(type: "text", content: "print(\"hi\")", diff: nil, encoding: "utf-8", mimeType: "text/x-swift"),
            ]
        )
        let facade = makeProjectFilesFacade(store: store)

        let snapshot = facade.snapshot

        XCTAssertEqual(snapshot.summary.fileCount, 1)
        XCTAssertEqual(snapshot.summary.additions, 3)
        XCTAssertEqual(snapshot.fileStatuses.map(\.path), [path])
        XCTAssertEqual(snapshot.selectedVCSFile, path)
        XCTAssertEqual(snapshot.filesMode, .changes)
        XCTAssertEqual(snapshot.visibleRows.map(\.node.name), ["Sources", "App.swift"])
        XCTAssertEqual(snapshot.selectedFileDiff?.file, path)
        XCTAssertEqual(snapshot.selectedFileContent?.content, "print(\"hi\")")
    }

    func testProjectFilesFacadeResetClearsWorkspaceAndStoreState() {
        let store = ProjectFilesStore(
            vcsInfo: OpenCodeVCSInfo(branch: "main", defaultBranch: "main"),
            vcsFileStatuses: [OpenCodeVCSFileStatus(path: "README.md", added: 1, removed: 0, status: "modified")]
        )
        let facade = makeProjectFilesFacade(store: store)
        facade.selectedWorkspaceDirectory = "/tmp/project"

        facade.reset()

        XCTAssertNil(facade.selectedWorkspaceDirectory)
        XCTAssertNil(store.vcsInfo)
        XCTAssertTrue(store.vcsFileStatuses.isEmpty)
    }

    func testProjectFilesManualAndWatcherRefreshReplaceCachedDiffWhenRepositoryBecomesClean() async throws {
        let path = "Sources/App.swift"
        let store = ProjectFilesStore(
            vcsInfo: OpenCodeVCSInfo(branch: "main", defaultBranch: "main"),
            vcsFileStatuses: [
                OpenCodeVCSFileStatus(path: path, added: 3, removed: 1, status: "modified"),
            ],
            vcsDiffsByMode: [
                .git: [OpenCodeVCSFileDiff(file: path, patch: "@@", additions: 3, deletions: 1, status: "modified")],
            ],
            selectedVCSFile: path,
            selectedFilePath: path
        )
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ProjectFilesMockURLProtocol.self]
        let client = OpenCodeAPIClient(
            config: OpenCodeServerConfig(baseURL: "http://127.0.0.1:4096", username: "opencode", password: "pw"),
            session: URLSession(configuration: configuration)
        )
        let facade = makeProjectFilesFacade(store: store, client: client)
        ProjectFilesMockURLProtocol.requestHandler = { request in
            let body: String
            switch request.url?.path {
            case "/vcs":
                body = #"{"branch":"main","default_branch":"main"}"#
            case "/file/status", "/vcs/diff":
                body = "[]"
            default:
                throw URLError(.badURL)
            }
            return (
                HTTPURLResponse(
                    url: try XCTUnwrap(request.url),
                    statusCode: 200,
                    httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]
                )!,
                Data(body.utf8)
            )
        }
        defer { ProjectFilesMockURLProtocol.requestHandler = nil }

        await facade.refresh()

        XCTAssertTrue(store.vcsFileStatuses.isEmpty)
        XCTAssertEqual(store.vcsDiffsByMode[.git], [])

        store.vcsFileStatuses = [
            OpenCodeVCSFileStatus(path: path, added: 3, removed: 1, status: "modified"),
        ]
        store.vcsDiffsByMode[.git] = [
            OpenCodeVCSFileDiff(file: path, patch: "@@", additions: 3, deletions: 1, status: "modified"),
        ]
        let cacheCleared = expectation(description: "Fresh empty diff replaces the cached diff")
        let observation = store.$vcsDiffsByMode.dropFirst().sink { diffs in
            if diffs[.git] == [] {
                cacheCleared.fulfill()
            }
        }

        facade.handleFileWatcherUpdate(".git/index")
        await fulfillment(of: [cacheCleared], timeout: 2)

        XCTAssertTrue(store.vcsFileStatuses.isEmpty)
        XCTAssertEqual(store.vcsDiffsByMode[.git], [])
        withExtendedLifetime(observation) {}
    }

    func testProjectFacadeBuildsListAndSettingsSnapshots() {
        let viewModel = AppViewModel()
        let project = OpenCodeProject(
            id: "project",
            worktree: "/tmp/project",
            vcs: "git",
            name: "Project",
            sandboxes: nil,
            icon: nil,
            time: nil
        )
        let action = OpenCodeAction(commandName: "review", iconName: "checkmark")
        let review = OpenCodeCommand(
            name: "review",
            description: "Review changes",
            agent: nil,
            model: nil,
            source: "project",
            template: "review",
            subtask: false,
            hints: []
        )
        let test = OpenCodeCommand(
            name: "test",
            description: "Run tests",
            agent: nil,
            model: nil,
            source: "project",
            template: "test",
            subtask: false,
            hints: []
        )
        viewModel.projects = [project]
        viewModel.currentProject = project
        viewModel.selectedDirectory = project.worktree
        viewModel.directoryCommands = [review, test]
        viewModel.projectActionsByScope[viewModel.currentProjectPreferenceScopeKey] = [action]

        let list = viewModel.projectFacade.listSnapshot
        let settings = viewModel.projectFacade.settingsSnapshot

        XCTAssertEqual(list.projects, [project])
        XCTAssertEqual(list.currentProjectID, project.id)
        XCTAssertEqual(list.selectedDirectory, project.worktree)
        XCTAssertEqual(settings.actions.map(\.action), [action])
        XCTAssertEqual(settings.actions.first?.command, review)
        XCTAssertEqual(settings.addableCommands.map(\.name), ["test"])
        XCTAssertTrue(settings.hasGitProject)
    }

    func testSessionSelectionStagesCachedTranscriptBeforeAsyncPreparation() {
        let viewModel = AppViewModel()
        let first = OpenCodeSession(
            id: "session-first",
            title: "First",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        let second = OpenCodeSession(
            id: "session-second",
            title: "Second",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        viewModel.selectedDirectory = "/tmp/project"
        viewModel.allSessions = [first, second]
        viewModel.selectedSession = first
        let previousMessage = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "message-first", role: "assistant", sessionID: first.id, time: nil, agent: nil, model: nil),
            parts: []
        )
        let selectedMessage = OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "message-second", role: "assistant", sessionID: second.id, time: nil, agent: nil, model: nil),
            parts: []
        )
        viewModel.chatStore.messages = [previousMessage]
        viewModel.chatStore.cacheMessages([selectedMessage], forSessionID: second.id)
        let facade = viewModel.sessionListFacade
        XCTAssertEqual(facade.snapshot.selectedSessionID, first.id)
        XCTAssertEqual(facade.snapshot.unpinnedRows.filter(\.isSelected).map(\.id), [first.id])

        let ticket = facade.beginSelection(second)

        XCTAssertEqual(facade.snapshot.selectedSessionID, second.id)
        XCTAssertEqual(facade.snapshot.unpinnedRows.filter(\.isSelected).map(\.id), [second.id])
        XCTAssertEqual(viewModel.selectedSession?.id, second.id)
        XCTAssertEqual(viewModel.directoryStore.selectedSession?.id, second.id)
        XCTAssertEqual(viewModel.chatStore.preparedSessionID, second.id)
        XCTAssertEqual(viewModel.chatStore.messages.map(\.id), [selectedMessage.id])
        XCTAssertTrue(viewModel.chatStore.isLoadingSelectedSession)
        XCTAssertEqual(
            viewModel.appShellFacade.detailRoute(isCompact: true),
            .chat(AppShellChatRoute(sessionID: second.id, presentationRequest: 0))
        )

        XCTAssertTrue(viewModel.sessionListFacade.prepareSelectionIfCurrent(ticket))

        XCTAssertEqual(viewModel.chatStore.preparedSessionID, second.id)
        XCTAssertEqual(viewModel.chatStore.messages.map(\.id), [selectedMessage.id])
        XCTAssertEqual(
            viewModel.appShellFacade.detailRoute(isCompact: true),
            .chat(AppShellChatRoute(sessionID: second.id, presentationRequest: 0))
        )
    }

    func testStaleSessionSelectionTicketDoesNotPreparePreviousTarget() {
        let viewModel = AppViewModel()
        let first = OpenCodeSession(id: "session-first", title: "First", workspaceID: nil, directory: "/tmp/project", projectID: "project", parentID: nil)
        let second = OpenCodeSession(id: "session-second", title: "Second", workspaceID: nil, directory: "/tmp/project", projectID: "project", parentID: nil)
        viewModel.selectedDirectory = "/tmp/project"
        viewModel.allSessions = [first, second]

        let firstTicket = viewModel.sessionListFacade.beginSelection(first)
        let secondTicket = viewModel.sessionListFacade.beginSelection(second)
        XCTAssertFalse(viewModel.sessionListFacade.prepareSelectionIfCurrent(firstTicket))

        XCTAssertEqual(viewModel.chatStore.preparedSessionID, second.id)

        XCTAssertTrue(viewModel.sessionListFacade.prepareSelectionIfCurrent(secondTicket))

        XCTAssertEqual(viewModel.chatStore.preparedSessionID, second.id)
    }

    func testSelectionOnlySnapshotUpdateCoversPinnedAndWorkspaceRows() {
        let model = AppViewModel()
        let first = OpenCodeSession(id: "first", title: "First", workspaceID: nil, directory: "/tmp/project", projectID: nil, parentID: nil)
        let second = OpenCodeSession(id: "second", title: "Second", workspaceID: nil, directory: "/tmp/project", projectID: nil, parentID: nil)
        model.allSessions = [first, second]
        var snapshot = model.sessionListFacade.snapshot
        let rows = snapshot.unpinnedRows
        XCTAssertEqual(rows.count, 2)
        snapshot.pinnedRows = rows
        snapshot.workspaceSections = [SessionListFacade.WorkspaceSection(
            directory: "/tmp/project", title: "Project", isMain: true,
            rows: rows, isLoading: false, hasMore: false, operation: nil
        )]

        for selection in [first.id, second.id, nil] {
            snapshot.selectSession(selection)
            XCTAssertEqual(snapshot.selectedSessionID, selection)
            for group in [snapshot.pinnedRows, snapshot.unpinnedRows, snapshot.workspaceSections[0].rows] {
                XCTAssertEqual(group.filter(\.isSelected).map(\.id), selection.map { [$0] } ?? [])
                XCTAssertEqual(group.map(\.session), rows.map(\.session))
                XCTAssertEqual(group.map(\.preview), rows.map(\.preview))
            }
        }
    }

    func testPendingSidebarRefreshKeepsLatestSelectionAndPreview() async {
        let model = AppViewModel()
        let first = OpenCodeSession(id: "first", title: "First", workspaceID: nil, directory: nil, projectID: "global", parentID: nil)
        let second = OpenCodeSession(id: "second", title: "Second", workspaceID: nil, directory: nil, projectID: "global", parentID: nil)
        model.allSessions = [first, second]
        let facade = model.sessionListFacade
        let refreshed = expectation(description: "Coalesced snapshot contains latest preview and selection")
        let observation = facade.$snapshot.first { snapshot in
            snapshot.selectedSessionID == second.id
                && snapshot.unpinnedRows.first(where: { $0.id == second.id })?.preview?.text == "Latest preview"
        }.sink { _ in refreshed.fulfill() }

        model.sessionPreviews[second.id] = SessionPreview(text: "Earlier preview", date: nil)
        _ = facade.beginSelection(first)
        _ = facade.beginSelection(second)
        model.sessionPreviews[second.id] = SessionPreview(text: "Latest preview", date: nil)

        XCTAssertEqual(facade.snapshot.unpinnedRows.filter(\.isSelected).map(\.id), [second.id])
        await fulfillment(of: [refreshed], timeout: 2)
        XCTAssertEqual(facade.snapshot.unpinnedRows.filter(\.isSelected).map(\.id), [second.id])
        withExtendedLifetime(observation) {}
    }

    func testTranscriptChangesDoNotInvalidateProjectListFacades() {
        let viewModel = AppViewModel()
        let projects = viewModel.projectFacade
        let sessions = viewModel.sessionListFacade
        let connection = viewModel.connectionFacade
        let configurations = viewModel.configurationsFacade
        let games = viewModel.funAndGamesFacade
        var projectChanges = 0
        var sessionChanges = 0
        var connectionChanges = 0
        var configurationChanges = 0
        var gameChanges = 0
        let observations = [
            projects.objectWillChange.sink { projectChanges += 1 },
            sessions.objectWillChange.sink { sessionChanges += 1 },
            connection.objectWillChange.sink { connectionChanges += 1 },
            configurations.objectWillChange.sink { configurationChanges += 1 },
            games.objectWillChange.sink { gameChanges += 1 },
        ]

        viewModel.objectWillChange.send()
        viewModel.chatStore.messages = [OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "message", role: "assistant", sessionID: "session", time: nil, agent: nil, model: nil),
            parts: []
        )]
        var syncState = viewModel.directoryStore.syncState
        syncState.replaceMessages(viewModel.chatStore.messages, forSessionID: "session")
        viewModel.directoryStore.syncState = syncState

        XCTAssertEqual(projectChanges, 0)
        XCTAssertEqual(sessionChanges, 0)
        XCTAssertEqual(connectionChanges, 0)
        XCTAssertEqual(configurationChanges, 0)
        XCTAssertEqual(gameChanges, 0)
        withExtendedLifetime(observations) {}
    }

    func testStreamingSessionStateDoesNotInvalidateNewProjectChatFacade() {
        let viewModel = AppViewModel()
        let facade = viewModel.newProjectChatFacade
        var changes = 0
        let observation = facade.objectWillChange.sink { changes += 1 }

        viewModel.chatStore.messages = [OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: "message", role: "assistant", sessionID: "session", time: nil, agent: nil, model: nil),
            parts: []
        )]
        viewModel.sessionListStore.workspaceSessionsByDirectory["/tmp/project"] = OpenCodeWorkspaceSessionState()
        viewModel.modelConfigurationStore.selectedAgentNamesBySessionID["session"] = "build"
        viewModel.modelConfigurationStore.selectedModelsBySessionID["session"] = OpenCodeModelReference(
            providerID: "provider",
            modelID: "model"
        )
        viewModel.modelConfigurationStore.selectedVariantsBySessionID["session"] = "high"
        viewModel.directoryStore.sessionStatuses = ["session": "busy"]
        var syncState = viewModel.directoryStore.syncState
        syncState.replaceMessages(viewModel.chatStore.messages, forSessionID: "session")
        viewModel.directoryStore.syncState = syncState

        XCTAssertEqual(changes, 0)

        viewModel.modelConfigurationStore.availableAgents = [
            OpenCodeAgent(name: "build", description: nil, mode: "primary", hidden: false, model: nil, variant: nil)
        ]

        XCTAssertEqual(changes, 1)
        withExtendedLifetime(observation) {}
    }

    func testNewProjectChatFacadeExposesCachedRecentProjectRanking() {
        let viewModel = AppViewModel()
        let first = OpenCodeProject(id: "first", worktree: "/tmp/first", vcs: "git", name: "First", sandboxes: nil, icon: nil, time: nil)
        let second = OpenCodeProject(id: "second", worktree: "/tmp/second", vcs: "git", name: "Second", sandboxes: nil, icon: nil, time: nil)
        viewModel.projects = [first, second]
        var session = OpenCodeSession(id: "recent", title: "Recent", workspaceID: nil, directory: second.worktree, projectID: second.id, parentID: nil)
        session.time = .init(created: 100, updated: 200)
        viewModel.sessionListStore.setRecentSessions([session], for: second.worktree)

        XCTAssertEqual(viewModel.newProjectChatFacade.rankedProjects.map(\.id), [second.id, first.id])
    }

    func testNewProjectChatFacadeObservesFreshDirectorySessionsForRanking() {
        let viewModel = AppViewModel()
        let first = OpenCodeProject(id: "first", worktree: "/tmp/first", vcs: "git", name: "First", sandboxes: nil, icon: nil, time: nil)
        let second = OpenCodeProject(id: "second", worktree: "/tmp/second", vcs: "git", name: "Second", sandboxes: nil, icon: nil, time: nil)
        viewModel.projects = [first, second]
        let facade = viewModel.newProjectChatFacade
        var changes = 0
        let observation = facade.objectWillChange.sink { changes += 1 }
        let store = viewModel.directoryStoreRegistry.store(for: second.worktree)
        var session = OpenCodeSession(id: "live", title: "Live", workspaceID: nil, directory: second.worktree, projectID: second.id, parentID: nil)
        session.time = .init(created: 100, updated: 300)

        store.sessions = [session]

        XCTAssertGreaterThan(changes, 0)
        XCTAssertEqual(facade.rankedProjects.map(\.id), [second.id, first.id])
        withExtendedLifetime(observation) {}
    }

    func testSustainedTranscriptDeltaFlushDoesNotInvalidateNewProjectChatFacade() {
        let viewModel = AppViewModel()
        let directory = "/tmp/project"
        let session = OpenCodeSession(
            id: "session",
            title: "Streaming",
            workspaceID: nil,
            directory: directory,
            projectID: "project",
            parentID: nil
        )
        let message = OpenCodeMessage(id: "message", role: "assistant", sessionID: session.id, time: nil, agent: nil, model: nil)
        let part = OpenCodePart(
            id: "part",
            messageID: message.id,
            sessionID: session.id,
            type: "text",
            mime: nil,
            filename: nil,
            url: nil,
            reason: nil,
            tool: nil,
            callID: nil,
            state: nil,
            text: ""
        )
        viewModel.isConnected = true
        viewModel.selectedDirectory = session.directory
        viewModel.selectedSession = session
        viewModel.activeChatSessionID = session.id
        viewModel.handleManagedEvent(OpenCodeManagedEvent(
            directory: directory,
            envelope: OpenCodeEventEnvelope(type: "message.updated", properties: OpenCodeEventProperties(info: OpenCodeEventInfo(message: message))),
            typed: .messageUpdated(message)
        ))
        viewModel.handleManagedEvent(OpenCodeManagedEvent(
            directory: directory,
            envelope: OpenCodeEventEnvelope(type: "message.part.updated", properties: OpenCodeEventProperties(part: part)),
            typed: .messagePartUpdated(part)
        ))

        let facade = viewModel.newProjectChatFacade
        var changes = 0
        let observation = facade.objectWillChange.sink { changes += 1 }
        var sourceChanges: [String: Int] = [:]
        let sourceObservations = [
            viewModel.projectStore.$projects.dropFirst().sink { _ in sourceChanges["projects", default: 0] += 1 },
            viewModel.projectStore.$currentProject.dropFirst().sink { _ in sourceChanges["currentProject", default: 0] += 1 },
            viewModel.projectPreferencesStore.$projectWorkspacesEnabledByScope.dropFirst().sink { _ in sourceChanges["workspaces", default: 0] += 1 },
            viewModel.modelConfigurationStore.$availableAgents.dropFirst().sink { _ in sourceChanges["agents", default: 0] += 1 },
            viewModel.modelConfigurationStore.$allProviders.dropFirst().sink { _ in sourceChanges["allProviders", default: 0] += 1 },
            viewModel.modelConfigurationStore.$availableProviders.dropFirst().sink { _ in sourceChanges["providers", default: 0] += 1 },
            viewModel.modelConfigurationStore.$defaultModelsByProviderID.dropFirst().sink { _ in sourceChanges["defaults", default: 0] += 1 },
            viewModel.modelConfigurationStore.$newSessionDefaults.dropFirst().sink { _ in sourceChanges["newSessionDefaults", default: 0] += 1 },
        ]

        for _ in 0..<100 {
            let event = OpenCodeManagedEvent(
                directory: directory,
                envelope: OpenCodeEventEnvelope(
                    type: "message.part.delta",
                    properties: OpenCodeEventProperties(
                        sessionID: session.id,
                        messageID: message.id,
                        partID: part.id,
                        field: "text",
                        delta: "x"
                    )
                ),
                typed: .messagePartDelta(
                    sessionID: session.id,
                    messageID: message.id,
                    partID: part.id ?? "part",
                    field: "text",
                    delta: "x"
                )
            )
            viewModel.handleManagedEvent(event)
        }
        viewModel.flushBufferedTranscript(reason: "new chat picker stability test")

        XCTAssertEqual(viewModel.messages.first?.parts.first?.text?.count, 100)
        XCTAssertEqual(changes, 0, "Sources: \(sourceChanges)")
        withExtendedLifetime(observation) {}
        withExtendedLifetime(sourceObservations) {}
    }

    func testExtractedFacadesRemainSafeAfterAppViewModelDeinitializes() async {
        var viewModel: AppViewModel? = AppViewModel()
        let projectFilesFacade = viewModel!.projectFilesFacade
        let mcpFacade = viewModel!.mcpFacade
        let widgetSnapshotPublisher = viewModel!.widgetSnapshotPublisher
        weak var weakViewModel = viewModel

        viewModel = nil

        XCTAssertNil(weakViewModel)
        XCTAssertFalse(projectFilesFacade.hasGitProject)
        XCTAssertNil(projectFilesFacade.snapshot.effectiveDirectory)
        await projectFilesFacade.reloadGitViewData(force: true)
        await mcpFacade.reload()
        await widgetSnapshotPublisher.publishNow()
    }

    private func makeProjectFilesFacade(
        store: ProjectFilesStore,
        client: OpenCodeAPIClient = OpenCodeAPIClient(config: OpenCodeServerConfig())
    ) -> ProjectFilesFacade {
        ProjectFilesFacade(
            store: store,
            clientProvider: { client },
            hasGitProjectProvider: { true },
            effectiveSelectedDirectoryProvider: { "/tmp/project" },
            currentProjectProvider: {
                OpenCodeProject(id: "project", worktree: "/tmp/project", vcs: "git", name: "Project", sandboxes: nil, icon: nil, time: nil)
            },
            workspaceDirectoriesProvider: { ["/tmp/project"] },
            workspaceDisplayNameProvider: { _ in "Project" },
            workspaceKeyProvider: { $0 },
            isFilesPresentedProvider: { true },
            preserveNavigationState: {},
            showFilesRoute: {}
        )
    }

    private func makeFileNode(
        name: String,
        path: String,
        absolute: String,
        type: String = "file"
    ) -> OpenCodeFileNode {
        OpenCodeFileNode(name: name, path: path, absolute: absolute, type: type, ignored: false)
    }
}

private final class ProjectFilesMockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var requestHandler: ((URLRequest) throws -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        guard let handler = Self.requestHandler else {
            XCTFail("Missing request handler")
            return
        }

        do {
            let (response, data) = try handler(request)
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}
}
