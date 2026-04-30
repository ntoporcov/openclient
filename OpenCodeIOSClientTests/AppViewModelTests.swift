import XCTest
@testable import OpenClient

@MainActor
final class AppViewModelTests: XCTestCase {
    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.messageDraftsByChat)
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.appleIntelligenceWorkspaces)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.messageDraftsByChat)
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.appleIntelligenceWorkspaces)
        super.tearDown()
    }

    func testMessageDraftRestoresPerSession() {
        let viewModel = AppViewModel()
        let first = OpenCodeSession(id: "ses_first", title: "First", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)
        let second = OpenCodeSession(id: "ses_second", title: "Second", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.directoryState.selectedSession = first
        viewModel.draftMessage = "first draft"
        viewModel.persistCurrentMessageDraft()

        viewModel.directoryState.selectedSession = second
        viewModel.draftMessage = "second draft"
        viewModel.persistCurrentMessageDraft()

        viewModel.restoreMessageDraft(for: first)
        XCTAssertEqual(viewModel.draftMessage, "first draft")

        viewModel.restoreMessageDraft(for: second)
        XCTAssertEqual(viewModel.draftMessage, "second draft")
    }

    func testAppleIntelligenceMessagesPersistToRecentWorkspaceStorage() {
        let viewModel = AppViewModel()
        let workspace = AppleIntelligenceWorkspaceRecord(
            id: "apple-workspace:test",
            title: "Test Workspace",
            bookmarkData: Data(),
            lastKnownPath: "/tmp/apple-workspace-test",
            sessionID: "apple-session:test",
            messages: [],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let message = OpenCodeMessageEnvelope.local(
            role: "user",
            text: "hello apple intelligence",
            messageID: "msg_test",
            sessionID: workspace.sessionID,
            partID: "part_test"
        )

        viewModel.activeAppleIntelligenceWorkspaceID = workspace.id
        viewModel.currentAppleIntelligenceWorkspace = workspace
        viewModel.selectedDirectory = workspace.lastKnownPath
        viewModel.directoryState.messages = [message]

        viewModel.persistAppleIntelligenceMessages()

        XCTAssertEqual(viewModel.appleIntelligenceRecentWorkspaces.first?.id, workspace.id)
        XCTAssertEqual(viewModel.appleIntelligenceRecentWorkspaces.first?.messages.map(\.id), ["msg_test"])

        let restored = AppViewModel()
        XCTAssertEqual(restored.appleIntelligenceRecentWorkspaces.first?.id, workspace.id)
        XCTAssertEqual(restored.appleIntelligenceRecentWorkspaces.first?.messages.map(\.id), ["msg_test"])
    }

    func testAppleIntelligenceAnimatedSendKeepsOptimisticUserMessage() async {
        let viewModel = AppViewModel()
        let workspace = AppleIntelligenceWorkspaceRecord(
            id: "apple-workspace:test",
            title: "Test Workspace",
            bookmarkData: Data(),
            lastKnownPath: "/tmp/apple-workspace-test",
            sessionID: "apple-session:test",
            messages: [],
            updatedAt: Date(timeIntervalSince1970: 1)
        )
        let session = workspace.session
        let optimistic = OpenCodeMessageEnvelope.local(
            role: "user",
            text: "hello apple intelligence",
            messageID: "msg_user",
            sessionID: session.id,
            partID: "part_user"
        )

        viewModel.backendMode = .appleIntelligence
        viewModel.activeAppleIntelligenceWorkspaceID = workspace.id
        viewModel.currentAppleIntelligenceWorkspace = workspace
        viewModel.selectedDirectory = workspace.lastKnownPath
        viewModel.directoryState = OpenCodeDirectoryState(
            sessions: [session],
            selectedSession: session,
            messages: [optimistic],
            sessionStatuses: [session.id: "idle"]
        )

        await viewModel.sendMessage(
            "hello apple intelligence",
            in: session,
            userVisible: true,
            messageID: "msg_user",
            partID: "part_user",
            appendOptimisticMessage: false,
            meterPrompt: false
        )
        viewModel.appleIntelligenceResponseTask?.cancel()

        XCTAssertEqual(viewModel.directoryState.messages.filter { $0.id == "msg_user" }.count, 1)
        XCTAssertEqual(viewModel.directoryState.messages.first?.parts.first?.text, "hello apple intelligence")
        XCTAssertEqual(viewModel.directoryState.messages.count, 2)
        XCTAssertEqual(viewModel.directoryState.messages.last?.info.role, "assistant")
    }

    func testMessageDraftPersistsAcrossViewModels() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(id: "ses_persisted", title: "Persisted", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.directoryState.selectedSession = session
        viewModel.draftMessage = "persist me"
        viewModel.persistCurrentMessageDraft()

        let restored = AppViewModel()
        restored.restoreMessageDraft(for: session)

        XCTAssertEqual(restored.draftMessage, "persist me")
        XCTAssertEqual(restored.draftAttachments, [])
    }

    func testMessageDraftIndicatorIgnoresWhitespaceDraft() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(id: "ses_empty_draft", title: "Empty", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.directoryState.selectedSession = session
        viewModel.draftMessage = "   \n"
        viewModel.persistCurrentMessageDraft()

        XCTAssertFalse(viewModel.hasMessageDraft(for: session))
    }

    func testMessageDraftCanRestoreAfterEmptyComposerRace() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(id: "ses_race", title: "Race", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.directoryState.selectedSession = session
        viewModel.draftMessage = "saved draft"
        viewModel.persistCurrentMessageDraft()
        viewModel.draftMessage = ""

        viewModel.restoreMessageDraftIfComposerIsEmpty(for: session)

        XCTAssertEqual(viewModel.draftMessage, "saved draft")
    }

    func testNavigationPreserveDoesNotEraseStoredDraftWhenComposerIsEmpty() {
        let viewModel = AppViewModel()
        let first = OpenCodeSession(id: "ses_first", title: "First", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)
        let second = OpenCodeSession(id: "ses_second", title: "Second", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.directoryState.selectedSession = first
        viewModel.draftMessage = "saved draft"
        viewModel.persistCurrentMessageDraft()

        viewModel.draftMessage = ""
        viewModel.prepareSessionSelection(second)

        XCTAssertTrue(viewModel.hasMessageDraft(for: first))
    }

    func testStaleChatBindingCannotErasePreviousSessionDraft() {
        let viewModel = AppViewModel()
        let first = OpenCodeSession(id: "ses_first", title: "First", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)
        let second = OpenCodeSession(id: "ses_second", title: "Second", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.directoryState.selectedSession = first
        viewModel.setDraftMessage("saved draft", forSessionID: first.id)
        viewModel.prepareSessionSelection(second)

        viewModel.setDraftMessage("", forSessionID: first.id)

        XCTAssertTrue(viewModel.hasMessageDraft(for: first))
        XCTAssertEqual(viewModel.messageDraftsByChatKey[viewModel.messageDraftStorageKey(for: first)]?.text, "saved draft")
    }

    func testSendDirectoryPrefersSelectedWorkspaceScope() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(
            id: "ses_test",
            title: "Test",
            workspaceID: nil,
            directory: "/tmp/session-dir",
            projectID: "proj_test",
            parentID: nil
        )

        viewModel.selectedDirectory = "/tmp/selected-dir"
        viewModel.currentProject = OpenCodeProject(
            id: "proj_test",
            worktree: "/tmp/selected-dir",
            vcs: "git",
            name: "selected-dir",
            icon: nil,
            time: nil
        )

        XCTAssertEqual(viewModel.sendDirectory(for: session), "/tmp/selected-dir")
    }

    func testSendDirectoryUsesSessionScopeForLocalSessionWhenGlobalProjectSelected() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(
            id: "ses_test",
            title: "Global",
            workspaceID: nil,
            directory: "/tmp/session-dir",
            projectID: "global",
            parentID: nil
        )

        viewModel.selectedDirectory = nil
        viewModel.currentProject = OpenCodeProject(
            id: "global",
            worktree: "Global",
            vcs: nil,
            name: nil,
            icon: nil,
            time: nil
        )

        XCTAssertEqual(viewModel.sendDirectory(for: session), "/tmp/session-dir")
    }

    func testSelectedSessionDirectoryEventsRefreshWhenGlobalProjectSelected() {
        let viewModel = AppViewModel()
        let selectedSession = OpenCodeSession(
            id: "ses_selected",
            title: "Selected",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_test",
            parentID: nil
        )

        viewModel.isConnected = true
        viewModel.selectedDirectory = nil
        viewModel.currentProject = OpenCodeProject(
            id: "global",
            worktree: "Global",
            vcs: nil,
            name: nil,
            icon: nil,
            time: nil
        )
        viewModel.directoryState.selectedSession = selectedSession
        viewModel.directoryState.sessionStatuses[selectedSession.id] = "busy"
        viewModel.lastStreamEventAt = .distantPast

        let event = OpenCodeManagedEvent(
            directory: "/tmp/project",
            envelope: OpenCodeEventEnvelope(
                type: "session.idle",
                properties: OpenCodeEventProperties(
                    sessionID: "ses_selected",
                    info: nil,
                    part: nil,
                    status: nil,
                    todos: nil,
                    messageID: nil,
                    partID: nil,
                    field: nil,
                    delta: nil,
                    id: nil,
                    permissionType: nil,
                    pattern: nil,
                    callID: nil,
                    title: nil,
                    metadata: nil,
                    permissionID: nil,
                    response: nil,
                    reply: nil,
                    message: nil,
                    error: nil
                )
            ),
            typed: .sessionIdle(sessionID: "ses_selected")
        )

        viewModel.handleManagedEvent(event)

        XCTAssertEqual(viewModel.directoryState.sessionStatuses[selectedSession.id], "idle")
        XCTAssertGreaterThan(viewModel.lastStreamEventAt, .distantPast)
    }

    func testUnrelatedScopedEventsDoNotRefreshActiveStreamTimestamp() {
        let viewModel = AppViewModel()
        let selectedSession = OpenCodeSession(
            id: "ses_selected",
            title: "Selected",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_test",
            parentID: nil
        )

        viewModel.isConnected = true
        viewModel.selectedDirectory = "/tmp/project"
        viewModel.currentProject = OpenCodeProject(
            id: "proj_test",
            worktree: "/tmp/project",
            vcs: "git",
            name: "project",
            icon: nil,
            time: nil
        )
        viewModel.directoryState.selectedSession = selectedSession
        viewModel.lastStreamEventAt = .distantPast

        let event = OpenCodeManagedEvent(
            directory: "/tmp/project",
            envelope: OpenCodeEventEnvelope(
                type: "message.updated",
                properties: OpenCodeEventProperties(
                    sessionID: "ses_other",
                    info: OpenCodeEventInfo(message: OpenCodeMessage(id: "msg_other", role: "assistant", sessionID: "ses_other", time: nil, agent: nil, model: nil)),
                    part: nil,
                    status: nil,
                    todos: nil,
                    messageID: nil,
                    partID: nil,
                    field: nil,
                    delta: nil,
                    id: nil,
                    permissionType: nil,
                    pattern: nil,
                    callID: nil,
                    title: nil,
                    metadata: nil,
                    permissionID: nil,
                    response: nil,
                    reply: nil,
                    message: nil,
                    error: nil
                )
            ),
            typed: .messageUpdated(OpenCodeMessage(id: "msg_other", role: "assistant", sessionID: "ses_other", time: nil, agent: nil, model: nil))
        )

        viewModel.handleManagedEvent(event)

        XCTAssertEqual(viewModel.lastStreamEventAt, .distantPast)
    }

    func testActiveSessionEventsRefreshStreamTimestamp() {
        let viewModel = AppViewModel()
        let selectedSession = OpenCodeSession(
            id: "ses_selected",
            title: "Selected",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_test",
            parentID: nil
        )

        viewModel.isConnected = true
        viewModel.selectedDirectory = "/tmp/project"
        viewModel.currentProject = OpenCodeProject(
            id: "proj_test",
            worktree: "/tmp/project",
            vcs: "git",
            name: "project",
            icon: nil,
            time: nil
        )
        viewModel.directoryState.selectedSession = selectedSession
        viewModel.lastStreamEventAt = .distantPast

        let event = OpenCodeManagedEvent(
            directory: "/tmp/project",
            envelope: OpenCodeEventEnvelope(
                type: "session.status",
                properties: OpenCodeEventProperties(
                    sessionID: "ses_selected",
                    info: nil,
                    part: nil,
                    status: OpenCodeSessionStatus(type: "busy"),
                    todos: nil,
                    messageID: nil,
                    partID: nil,
                    field: nil,
                    delta: nil,
                    id: nil,
                    permissionType: nil,
                    pattern: nil,
                    callID: nil,
                    title: nil,
                    metadata: nil,
                    permissionID: nil,
                    response: nil,
                    reply: nil,
                    message: nil,
                    error: nil
                )
            ),
            typed: .sessionStatus(sessionID: "ses_selected", status: "busy")
        )

        viewModel.handleManagedEvent(event)

        XCTAssertGreaterThan(viewModel.lastStreamEventAt, .distantPast)
    }

    func testLiveActivityTranscriptShowsLatestAssistantLineOnly() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(
            id: "ses_live",
            title: "Live",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_test",
            parentID: nil
        )

        viewModel.directoryState.selectedSession = session
        viewModel.directoryState.sessionStatuses[session.id] = "busy"
        viewModel.directoryState.messages = [
            .local(role: "user", text: "Can you fix the build?", messageID: "msg_user", sessionID: session.id),
            .local(role: "assistant", text: "I am checking the failing test now.", messageID: "msg_assistant", sessionID: session.id),
        ]

        let lines = viewModel.liveActivityTranscriptLines(for: session)

        XCTAssertEqual(lines.map(\.role), ["assistant"])
        XCTAssertEqual(lines.map(\.text), ["I am checking the failing test now."])
        XCTAssertEqual(lines.last?.isStreaming, true)
    }

    func testLiveActivityTranscriptDoesNotSurfaceUserOnlyMessages() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(
            id: "ses_live",
            title: "Live",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_test",
            parentID: nil
        )

        viewModel.directoryState.selectedSession = session
        viewModel.directoryState.sessionStatuses[session.id] = "busy"
        viewModel.directoryState.messages = [
            .local(role: "user", text: "Can you fix the build?", messageID: "msg_user", sessionID: session.id),
        ]

        XCTAssertTrue(viewModel.liveActivityTranscriptLines(for: session).isEmpty)
    }

    func testLiveActivityTranscriptIsBoundedForLongStreamingText() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(
            id: "ses_live",
            title: "Live",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_test",
            parentID: nil
        )
        let longText = String(repeating: "streaming ", count: 40)

        viewModel.directoryState.selectedSession = session
        viewModel.directoryState.sessionStatuses[session.id] = "busy"
        viewModel.directoryState.messages = [
            .local(role: "assistant", text: longText, messageID: "msg_assistant", sessionID: session.id),
        ]

        let lines = viewModel.liveActivityTranscriptLines(for: session)

        XCTAssertEqual(lines.count, 1)
        XCTAssertLessThanOrEqual(lines[0].text.count, 180)
        XCTAssertEqual(lines[0].isStreaming, true)
    }

    func testLiveActivityTranscriptUsesCachedMessagesForUnselectedActiveSession() {
        let viewModel = AppViewModel()
        let selected = OpenCodeSession(id: "ses_selected", title: "Selected", workspaceID: nil, directory: "/tmp/project", projectID: nil, parentID: nil)
        let background = OpenCodeSession(id: "ses_background", title: "Background", workspaceID: nil, directory: "/tmp/project", projectID: nil, parentID: nil)

        viewModel.directoryState.selectedSession = selected
        viewModel.directoryState.sessionStatuses[background.id] = "busy"
        viewModel.cachedMessagesBySessionID[background.id] = [
            .local(role: "user", text: "Ship it", messageID: "msg_user", sessionID: background.id),
            .local(role: "assistant", text: "Shipping now", messageID: "msg_assistant", sessionID: background.id),
        ]

        let lines = viewModel.liveActivityTranscriptLines(for: background)

        XCTAssertEqual(lines.map(\.text), ["Shipping now"])
        XCTAssertEqual(lines.last?.isStreaming, true)
    }

    func testDefaultModelPrefersFreeFallbackWhenServerHasNoDefault() {
        let viewModel = AppViewModel()
        viewModel.availableProviders = [
            OpenCodeProvider(
                id: "openai",
                name: "OpenAI",
                models: [
                    "gpt-5.5-fast": OpenCodeModel(
                        id: "gpt-5.5-fast",
                        providerID: "openai",
                        name: "GPT-5.5 Fast",
                        capabilities: OpenCodeModelCapabilities(reasoning: true),
                        variants: nil
                    ),
                ]
            ),
            OpenCodeProvider(
                id: "opencode",
                name: "OpenCode Zen",
                models: [
                    "minimax-m2.5-free": OpenCodeModel(
                        id: "minimax-m2.5-free",
                        providerID: "opencode",
                        name: "MiniMax M2.5 Free",
                        capabilities: OpenCodeModelCapabilities(reasoning: false),
                        variants: nil
                    ),
                ]
            ),
        ]
        viewModel.defaultModelsByProviderID = [:]

        XCTAssertEqual(viewModel.defaultModelReference(), OpenCodeModelReference(providerID: "opencode", modelID: "minimax-m2.5-free"))
    }

    func testDefaultModelUsesServerDefaultBeforeFreeFallback() {
        let viewModel = AppViewModel()
        viewModel.availableProviders = [
            OpenCodeProvider(
                id: "openai",
                name: "OpenAI",
                models: [
                    "gpt-5.4-mini": OpenCodeModel(
                        id: "gpt-5.4-mini",
                        providerID: "openai",
                        name: "GPT-5.4 mini",
                        capabilities: OpenCodeModelCapabilities(reasoning: true),
                        variants: nil
                    ),
                ]
            ),
            OpenCodeProvider(
                id: "opencode",
                name: "OpenCode Zen",
                models: [
                    "minimax-m2.5-free": OpenCodeModel(
                        id: "minimax-m2.5-free",
                        providerID: "opencode",
                        name: "MiniMax M2.5 Free",
                        capabilities: OpenCodeModelCapabilities(reasoning: false),
                        variants: nil
                    ),
                ]
            ),
        ]
        viewModel.defaultModelsByProviderID = ["openai": "gpt-5.4-mini"]

        XCTAssertEqual(viewModel.defaultModelReference(), OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.4-mini"))
    }
}
