import XCTest
@testable import OpenClient

@MainActor
final class AppViewModelTests: XCTestCase {
    private let pinnedCommandTestStorageKey = "PinnedCommandStoreTests"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.messageDraftsByChat)
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.appleIntelligenceWorkspaces)
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.pinnedSessionsByScope)
        UserDefaults.standard.removeObject(forKey: pinnedCommandTestStorageKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.messageDraftsByChat)
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.appleIntelligenceWorkspaces)
        UserDefaults.standard.removeObject(forKey: AppViewModel.StorageKey.pinnedSessionsByScope)
        UserDefaults.standard.removeObject(forKey: pinnedCommandTestStorageKey)
        super.tearDown()
    }

    func testPinnedCommandsPersistPerScopeAndIgnoreDuplicates() {
        let store = PinnedCommandStore(storageKey: pinnedCommandTestStorageKey)
        let build = makeCommand("build")
        let test = makeCommand("test")

        store.pin(build, scopeKey: "project-a")
        store.pin(build, scopeKey: "project-a")
        store.pin(test, scopeKey: "project-b")

        XCTAssertEqual(store.pinnedNames(for: "project-a"), ["build"])
        XCTAssertEqual(store.pinnedNames(for: "project-b"), ["test"])

        let restored = PinnedCommandStore(storageKey: pinnedCommandTestStorageKey)
        XCTAssertEqual(restored.pinnedNames(for: "project-a"), ["build"])
        XCTAssertEqual(restored.pinnedNames(for: "project-b"), ["test"])
    }

    func testPinnedCommandDerivationPreservesOrderAndFiltersUnavailableCommands() {
        let store = PinnedCommandStore(storageKey: pinnedCommandTestStorageKey)
        let build = makeCommand("build")
        let test = makeCommand("test")
        let deploy = makeCommand("deploy")

        store.pin(deploy, scopeKey: "project-a")
        store.pin(build, scopeKey: "project-a")
        store.pin(test, scopeKey: "project-a")

        let visible = store.pinnedCommands(from: [test, build], scopeKey: "project-a")

        XCTAssertEqual(visible.map(\.name), ["build", "test"])
    }

    func testChatStoreApplyCanonicalMessagesCachesInactiveSessionOnly() {
        let store = ChatStore(messages: [makeMessage(id: "active", text: "active", sessionID: "ses_active")])
        let loaded = [makeMessage(id: "inactive", text: "inactive", sessionID: "ses_inactive")]

        store.applyCanonicalMessages(loaded, forSessionID: "ses_inactive", isActiveSession: false)

        XCTAssertEqual(store.cachedMessagesBySessionID["ses_inactive"]?.map(\.id), ["inactive"])
        XCTAssertEqual(store.messages.map(\.id), ["active"])
        XCTAssertFalse(store.isLoadingSelectedSession)
    }

    func testChatStoreApplyCanonicalMessagesMergesActiveSessionAndFinishesLoading() {
        let streamed = makeMessage(id: "msg_assistant", text: "Hello world", sessionID: "ses_active")
        let staleCanonical = makeMessage(id: "msg_assistant", text: "", sessionID: "ses_active")
        let store = ChatStore(messages: [streamed], isLoadingSelectedSession: true)

        store.applyCanonicalMessages([staleCanonical], forSessionID: "ses_active", isActiveSession: true)

        XCTAssertEqual(store.cachedMessagesBySessionID["ses_active"]?.map(\.id), ["msg_assistant"])
        XCTAssertEqual(store.messages.first?.parts.first?.text, "Hello world")
        XCTAssertFalse(store.isLoadingSelectedSession)
    }

    func testChatStoreOptimisticRollbackRemovesInsertedMessage() {
        let store = ChatStore()
        let message = makeMessage(id: "msg_optimistic", text: "hello", sessionID: "ses_active", role: "user")

        store.insertOptimisticUserMessage(message)
        store.rollbackOptimisticUserMessage(messageID: "msg_optimistic")

        XCTAssertTrue(store.messages.isEmpty)
    }

    func testChatStoreAppendsAppleIntelligenceExchangeWithoutDuplicateUserWhenRequested() {
        let store = ChatStore(messages: [makeMessage(id: "msg_user", text: "hello", sessionID: "ses_ai", role: "user")])
        let user = makeMessage(id: "msg_user", text: "hello", sessionID: "ses_ai", role: "user")
        let assistant = makeMessage(id: "msg_assistant", text: "", sessionID: "ses_ai")

        store.appendLocalAppleIntelligenceExchange(
            userMessage: user,
            assistantMessage: assistant,
            appendUserMessage: false
        )

        XCTAssertEqual(store.messages.map(\.id), ["msg_user", "msg_assistant"])
    }

    func testChatStoreUpdatesAppleIntelligenceAssistantMessageAndCreatesFallback() {
        let store = ChatStore()

        store.updateLocalAppleIntelligenceAssistantMessage(
            messageID: "msg_assistant",
            partID: "part_assistant",
            sessionID: "ses_ai",
            text: "Local response"
        )

        XCTAssertEqual(store.messages.map(\.id), ["msg_assistant"])
        XCTAssertEqual(store.messages.first?.info.agent, "Apple Intelligence")
        XCTAssertEqual(store.messages.first?.parts.first?.text, "Local response")
    }

    func testPinnedCommandUnpinRemovesOnlySelectedScope() {
        let store = PinnedCommandStore(storageKey: pinnedCommandTestStorageKey)
        let build = makeCommand("build")

        store.pin(build, scopeKey: "project-a")
        store.pin(build, scopeKey: "project-b")
        store.unpin(build, scopeKey: "project-a")

        XCTAssertEqual(store.pinnedNames(for: "project-a"), [])
        XCTAssertEqual(store.pinnedNames(for: "project-b"), ["build"])
    }

    func testPinnedSessionsCanBeTemporarilyMissingWithoutMutatingStorage() {
        let viewModel = AppViewModel()
        let visible = makeSession(id: "ses_visible")
        let hidden = makeSession(id: "ses_hidden")

        viewModel.selectedDirectory = "/tmp/project"
        viewModel.allSessions = [visible]
        viewModel.setPinnedSessionIDs([visible.id, hidden.id])

        XCTAssertEqual(viewModel.pinnedRootSessions.map(\.id), [visible.id])
        XCTAssertEqual(viewModel.pinnedSessionIDs, [visible.id, hidden.id])

        let restored = AppViewModel()
        restored.selectedDirectory = "/tmp/project"
        XCTAssertEqual(restored.pinnedSessionIDs, [visible.id, hidden.id])
    }

    func testSessionDeletedEventRemovesPinnedSession() {
        let viewModel = AppViewModel()
        let deleted = makeSession(id: "ses_deleted")
        let kept = makeSession(id: "ses_kept")

        viewModel.isConnected = true
        viewModel.selectedDirectory = "/tmp/project"
        viewModel.allSessions = [deleted, kept]
        viewModel.setPinnedSessionIDs([deleted.id, kept.id])
        viewModel.setPinnedSessionIDs([deleted.id], for: "other-scope")

        viewModel.handleManagedEvent(
            OpenCodeManagedEvent(
                directory: "/tmp/project",
                envelope: OpenCodeEventEnvelope(type: "session.deleted", properties: .init()),
                typed: .sessionDeleted(deleted)
            )
        )

        XCTAssertEqual(viewModel.pinnedSessionIDs, [kept.id])
        XCTAssertNil(viewModel.pinnedSessionIDsByScope["other-scope"])
    }

    func testMessageDraftRestoresPerSession() {
        let viewModel = AppViewModel()
        let first = OpenCodeSession(id: "ses_first", title: "First", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)
        let second = OpenCodeSession(id: "ses_second", title: "Second", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.selectedSession = first
        viewModel.draftMessage = "first draft"
        viewModel.persistCurrentMessageDraft()

        viewModel.selectedSession = second
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
        viewModel.messages = [message]

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
        viewModel.allSessions = [session]
        viewModel.selectedSession = session
        viewModel.messages = [optimistic]
        viewModel.sessionStatuses = [session.id: "idle"]

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

        XCTAssertEqual(viewModel.messages.filter { $0.id == "msg_user" }.count, 1)
        XCTAssertEqual(viewModel.messages.first?.parts.first?.text, "hello apple intelligence")
        XCTAssertEqual(viewModel.messages.count, 2)
        XCTAssertEqual(viewModel.messages.last?.info.role, "assistant")
    }

    func testMessageDraftPersistsAcrossViewModels() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(id: "ses_persisted", title: "Persisted", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.selectedSession = session
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

        viewModel.selectedSession = session
        viewModel.draftMessage = "   \n"
        viewModel.persistCurrentMessageDraft()

        XCTAssertFalse(viewModel.hasMessageDraft(for: session))
    }

    func testMessageDraftCanRestoreAfterEmptyComposerRace() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(id: "ses_race", title: "Race", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.selectedSession = session
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

        viewModel.selectedSession = first
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

        viewModel.selectedSession = first
        viewModel.setDraftMessage("saved draft", forSessionID: first.id)
        viewModel.prepareSessionSelection(second)

        viewModel.setDraftMessage("", forSessionID: first.id)

        XCTAssertTrue(viewModel.hasMessageDraft(for: first))
        XCTAssertEqual(viewModel.messageDraftsByChatKey[viewModel.messageDraftStorageKey(for: first)]?.text, "saved draft")
    }

    func testClearingDraftRemovesPersistedSlashCommand() {
        let viewModel = AppViewModel()
        let session = OpenCodeSession(id: "ses_command", title: "Command", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        viewModel.selectedSession = session
        viewModel.saveMessageDraft("/test", forSessionID: session.id)
        viewModel.clearPersistedMessageDraft(forSessionID: session.id)

        XCTAssertFalse(viewModel.hasMessageDraft(for: session))
        XCTAssertNil(viewModel.messageDraftsByChatKey[viewModel.messageDraftStorageKey(for: session)])
    }

    func testComposerStoreDeduplicatesAttachmentsAndResetsActiveDraft() {
        let store = ComposerStore(draftMessage: "hello")
        let attachment = OpenCodeComposerAttachment(id: "att_1", kind: .file, filename: "README.md", mime: "text/markdown", dataURL: "data:text/plain;base64,AA==")

        store.addAttachments([attachment, attachment])
        XCTAssertEqual(store.draftAttachments.map(\.id), ["att_1"])

        store.resetActiveDraft()

        XCTAssertEqual(store.draftMessage, "")
        XCTAssertEqual(store.draftAttachments, [])
    }

    func testComposerStoreRestoresDraftOnlyWhenActiveDraftIsEmpty() {
        let store = ComposerStore()
        store.saveDraft("saved", forKey: "chat|one", updateActiveDraft: false)

        XCTAssertTrue(store.restoreDraftIfActiveIsEmpty(forKey: "chat|one"))
        XCTAssertEqual(store.draftMessage, "saved")

        store.saveDraft("new saved", forKey: "chat|one", updateActiveDraft: false)
        XCTAssertFalse(store.restoreDraftIfActiveIsEmpty(forKey: "chat|one"))
        XCTAssertEqual(store.draftMessage, "saved")
    }

    func testSessionInteractionStoreFiltersAndRemovesPendingInteractions() {
        let selectedPermission = OpenCodePermission(id: "perm_1", sessionID: "ses_selected", permission: "edit", patterns: [], always: nil, metadata: nil, tool: nil)
        let otherPermission = OpenCodePermission(id: "perm_2", sessionID: "ses_other", permission: "edit", patterns: [], always: nil, metadata: nil, tool: nil)
        let selectedQuestion = OpenCodeQuestionRequest(id: "q_1", sessionID: "ses_selected", questions: [], tool: nil)
        let store = SessionInteractionStore(
            permissions: [selectedPermission, otherPermission],
            questions: [selectedQuestion]
        )

        XCTAssertEqual(store.permissions(forSessionID: "ses_selected").map(\.id), ["perm_1"])
        XCTAssertTrue(store.hasPermissionRequest(forSessionID: "ses_selected"))

        store.removePermission(id: "perm_1")
        store.removeQuestion(id: "q_1")

        XCTAssertEqual(store.permissions.map(\.id), ["perm_2"])
        XCTAssertTrue(store.questions.isEmpty)
    }

    func testSessionListStoreFiltersVisibleSessionsToActiveDirectory() {
        let store = SessionListStore()
        let current = OpenCodeSession(id: "ses_current", title: "Current", workspaceID: nil, directory: "/tmp/current", projectID: "proj_current", parentID: nil)
        let previous = OpenCodeSession(id: "ses_previous", title: "Previous", workspaceID: nil, directory: "/tmp/previous", projectID: "proj_previous", parentID: nil)

        let scoped = store.sessions([current, previous], scopedTo: "/tmp/current")

        XCTAssertEqual(scoped.map(\.id), ["ses_current"])
    }

    func testSessionListStoreFiltersGlobalSessionsWhenNoDirectoryIsActive() {
        let store = SessionListStore()
        let global = OpenCodeSession(id: "ses_global", title: "Global", workspaceID: nil, directory: nil, projectID: nil, parentID: nil)
        let project = OpenCodeSession(id: "ses_project", title: "Project", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)

        let scoped = store.sessions([global, project], scopedTo: nil)

        XCTAssertEqual(scoped.map(\.id), ["ses_global"])
    }

    func testProjectFilesStoreSortsTreeNodesAndTracksExpansionLoadNeed() {
        let store = ProjectFilesStore()
        let file = makeFileNode(name: "z.swift", path: "z.swift", absolute: "/tmp/project/z.swift")
        let directory = makeFileNode(name: "Sources", path: "Sources", absolute: "/tmp/project/Sources", type: "directory")

        store.applyLoadedRootNodes([file, directory])
        let shouldLoadChildren = store.toggleDirectory(directory)

        XCTAssertEqual(store.fileTreeRootNodes.map(\.name), ["Sources", "z.swift"])
        XCTAssertTrue(store.isExpandedDirectory(directory.absolute))
        XCTAssertTrue(shouldLoadChildren)
    }

    func testProjectFilesStoreSelectsReasonableVCSFileAndPreservesValidSelection() {
        let store = ProjectFilesStore(selectedVCSFile: "Sources/App.swift")
        let statuses = [
            OpenCodeVCSFileStatus(path: "Sources/App.swift", added: 1, removed: 0, status: "modified"),
            OpenCodeVCSFileStatus(path: "README.md", added: 2, removed: 1, status: "modified"),
        ]

        store.applyLoadedVCSStatus(statuses) { $0 }
        XCTAssertEqual(store.selectedVCSFile, "Sources/App.swift")

        store.selectedVCSFile = "missing.swift"
        store.applyLoadedVCSDiff([
            OpenCodeVCSFileDiff(file: "README.md", patch: "", additions: 2, deletions: 1, status: "modified"),
        ], mode: .git) { $0 }

        XCTAssertEqual(store.selectedVCSFile, "README.md")
        XCTAssertEqual(store.selectedFilePath, "README.md")
    }

    func testProjectFilesStoreMatchesChangedFilesAcrossAbsoluteAndRelativePaths() {
        let store = ProjectFilesStore(vcsFileStatuses: [
            OpenCodeVCSFileStatus(path: "Sources/App.swift", added: 3, removed: 1, status: "modified"),
        ])
        let directory = makeFileNode(name: "Sources", path: "Sources", absolute: "/tmp/project/Sources", type: "directory")

        XCTAssertTrue(store.isChangedFile("/tmp/project/Sources/App.swift", effectiveDirectory: "/tmp/project"))

        let aggregate = store.aggregateStatus(for: directory, effectiveDirectory: "/tmp/project")
        XCTAssertEqual(aggregate?.fileCount, 1)
        XCTAssertEqual(aggregate?.additions, 3)
        XCTAssertEqual(aggregate?.deletions, 1)
    }

    func testMCPStoreDerivesSortedServersAndConnectedCount() {
        let store = MCPStore(statuses: [
            "zeta": OpenCodeMCPStatus(status: "disabled", error: nil),
            "alpha": OpenCodeMCPStatus(status: "connected", error: nil),
        ])

        XCTAssertEqual(store.servers.map(\.name), ["alpha", "zeta"])
        XCTAssertEqual(store.connectedServerCount, 1)
    }

    func testMCPStoreTracksLoadingAndLoadedStatuses() {
        let store = MCPStore()

        XCTAssertTrue(store.shouldLoadStatus())
        store.beginLoading()
        XCTAssertFalse(store.shouldLoadStatus())

        store.applyLoadedStatuses([
            "server": OpenCodeMCPStatus(status: "connected", error: nil),
        ])
        store.finishLoading()

        XCTAssertTrue(store.isReady)
        XCTAssertFalse(store.isLoading)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(store.isConnected(name: "server"))
    }

    func testMCPStorePreventsDuplicateToggleTracking() {
        let store = MCPStore()

        XCTAssertTrue(store.beginToggling(name: "server"))
        XCTAssertFalse(store.beginToggling(name: "server"))

        store.finishToggling(name: "server")
        XCTAssertTrue(store.togglingServerNames.isEmpty)
    }

    func testMCPSnapshotContainsOnlyMCPViewState() {
        let viewModel = AppViewModel()
        viewModel.mcpStatuses = [
            "server": OpenCodeMCPStatus(status: "connected", error: nil),
        ]
        viewModel.isLoadingMCP = true
        viewModel.togglingMCPServerNames = ["server"]

        let snapshot = viewModel.mcpSnapshot

        XCTAssertEqual(snapshot.servers.map(\.name), ["server"])
        XCTAssertEqual(snapshot.connectedServerCount, 1)
        XCTAssertTrue(snapshot.isLoading)
        XCTAssertEqual(snapshot.togglingServerNames, ["server"])
    }

    func testChatComposerSnapshotContainsPreparedComposerState() {
        let viewModel = AppViewModel()
        let session = makeSession(id: "ses_composer")
        viewModel.selectedSession = session
        viewModel.directoryCommands = [makeCommand("explain")]
        viewModel.messages = [makeMessage(id: "msg_user", text: "Fork this", sessionID: session.id, role: "user")]
        viewModel.draftAttachments = [
            OpenCodeComposerAttachment(id: "att_1", kind: .file, filename: "notes.txt", mime: "text/plain", dataURL: "data:text/plain;base64,QQ=="),
        ]
        viewModel.mcpStatuses = [
            "server": OpenCodeMCPStatus(status: "connected", error: nil),
        ]
        viewModel.isLoadingMCP = true

        let snapshot = viewModel.chatComposerSnapshot(for: session, isBusy: true)

        XCTAssertEqual(snapshot.commands.map(\.name), ["explain", "compact", "fork"])
        XCTAssertEqual(snapshot.attachmentCount, 1)
        XCTAssertTrue(snapshot.isBusy)
        XCTAssertTrue(snapshot.canFork)
        XCTAssertEqual(snapshot.forkableMessages.map(\.text), ["Fork this"])
        XCTAssertEqual(snapshot.mcp.connectedServerCount, 1)
        XCTAssertTrue(snapshot.mcp.isLoading)
        XCTAssertEqual(snapshot.actionSignature, "ses_composer|/tmp/project||proj_test|")
    }

    func testChatComposerOverlaySnapshotContainsPendingComposerState() {
        let viewModel = AppViewModel()
        let sessionID = "ses_overlay"
        viewModel.todos = [
            OpenCodeTodo(content: "Active todo", status: "in_progress", priority: "high"),
            OpenCodeTodo(content: "Done todo", status: "completed", priority: "low"),
        ]
        viewModel.draftAttachments = [
            OpenCodeComposerAttachment(id: "att_1", kind: .file, filename: "notes.txt", mime: "text/plain", dataURL: "data:text/plain;base64,QQ=="),
        ]
        viewModel.permissions = [
            OpenCodePermission(id: "perm_1", sessionID: sessionID, permission: "bash", patterns: ["ls"], always: nil, metadata: nil, tool: nil),
            OpenCodePermission(id: "perm_other", sessionID: "other", permission: "edit", patterns: nil, always: nil, metadata: nil, tool: nil),
        ]
        viewModel.questions = [
            OpenCodeQuestionRequest(id: "question_1", sessionID: sessionID, questions: [], tool: nil),
            OpenCodeQuestionRequest(id: "question_other", sessionID: "other", questions: [], tool: nil),
        ]

        let snapshot = viewModel.chatComposerOverlaySnapshot(forSessionID: sessionID)

        XCTAssertTrue(snapshot.showsAccessoryArea)
        XCTAssertEqual(snapshot.attachmentIDs, ["att_1"])
        XCTAssertEqual(snapshot.incompleteTodoIDs, ["Active todo"])
        XCTAssertEqual(snapshot.permissions.map(\.id), ["perm_1"])
        XCTAssertEqual(snapshot.questions.map(\.id), ["question_1"])
    }

    func testChatSessionHeaderSnapshotContainsChildSessionTitles() {
        let viewModel = AppViewModel()
        let parent = OpenCodeSession(id: "ses_parent", title: "Parent Chat", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: nil)
        let child = OpenCodeSession(id: "ses_child", title: "Fix issue (@build subagent)", workspaceID: nil, directory: "/tmp/project", projectID: "proj_test", parentID: parent.id)
        viewModel.allSessions = [parent, child]

        let snapshot = viewModel.chatSessionHeaderSnapshot(for: child)

        XCTAssertTrue(snapshot.isChildSession)
        XCTAssertEqual(snapshot.parentSession?.id, parent.id)
        XCTAssertEqual(snapshot.parentTitle, "Parent Chat")
        XCTAssertEqual(snapshot.childTitle, "Fix issue")
        XCTAssertEqual(snapshot.navigationTitle, "Fix issue")
    }

    func testProjectFilesSnapshotContainsPreparedViewState() {
        let viewModel = AppViewModel()
        viewModel.vcsFileStatuses = [
            OpenCodeVCSFileStatus(path: "Sources/App.swift", added: 3, removed: 1, status: "modified"),
        ]
        viewModel.selectedVCSFile = "Sources/App.swift"
        viewModel.projectFilesMode = .changes

        let snapshot = viewModel.projectFilesSnapshot

        XCTAssertEqual(snapshot.fileStatuses.map(\.path), ["Sources/App.swift"])
        XCTAssertEqual(snapshot.summary.additions, 3)
        XCTAssertEqual(snapshot.selectedVCSFile, "Sources/App.swift")
        XCTAssertEqual(snapshot.filesMode, .changes)
        XCTAssertNil(snapshot.selectedFileDiff)
    }

    func testProjectFilesSnapshotContainsSelectedDiffAndFileContent() {
        let viewModel = AppViewModel()
        let path = "Sources/App.swift"
        viewModel.selectedVCSFile = path
        viewModel.selectedProjectFilePath = path
        viewModel.projectFilesStore.vcsDiffsByMode[.git] = [
            OpenCodeVCSFileDiff(file: path, patch: "@@", additions: 1, deletions: 0, status: "modified"),
        ]
        viewModel.projectFilesStore.fileContentsByPath[path] = OpenCodeFileContent(
            type: "text",
            content: "print(\"hi\")",
            diff: nil,
            encoding: "utf-8",
            mimeType: "text/x-swift"
        )

        let snapshot = viewModel.projectFilesSnapshot

        XCTAssertEqual(snapshot.selectedFileDiff?.file, path)
        XCTAssertEqual(snapshot.selectedFileContent?.content, "print(\"hi\")")
    }

    func testSendDirectoryKeepsExistingSessionScope() {
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
            sandboxes: nil,
            icon: nil,
            time: nil
        )

        XCTAssertEqual(viewModel.sendDirectory(for: session), "/tmp/session-dir")
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
            sandboxes: nil,
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
            sandboxes: nil,
            icon: nil,
            time: nil
        )
        viewModel.selectedSession = selectedSession
        viewModel.sessionStatuses[selectedSession.id] = "busy"
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

        XCTAssertEqual(viewModel.sessionStatuses[selectedSession.id], "idle")
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
            sandboxes: nil,
            icon: nil,
            time: nil
        )
        viewModel.selectedSession = selectedSession
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
            sandboxes: nil,
            icon: nil,
            time: nil
        )
        viewModel.selectedSession = selectedSession
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

    func testLiveMessageEventsDoNotStartFallbackRefresh() {
        let viewModel = AppViewModel()
        let selectedSession = makeSession(id: "ses_selected")

        viewModel.isConnected = true
        viewModel.selectedDirectory = "/tmp/project"
        viewModel.currentProject = OpenCodeProject(
            id: "proj_test",
            worktree: "/tmp/project",
            vcs: "git",
            name: "project",
            sandboxes: nil,
            icon: nil,
            time: nil
        )
        viewModel.selectedSession = selectedSession

        viewModel.handleManagedEvent(
            OpenCodeManagedEvent(
                directory: "/tmp/project",
                envelope: OpenCodeEventEnvelope(
                    type: "message.updated",
                    properties: OpenCodeEventProperties(
                        sessionID: selectedSession.id,
                        info: OpenCodeEventInfo(message: OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: selectedSession.id, time: nil, agent: nil, model: nil)),
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
                typed: .messageUpdated(OpenCodeMessage(id: "msg_assistant", role: "assistant", sessionID: selectedSession.id, time: nil, agent: nil, model: nil))
            )
        )

        XCTAssertNil(viewModel.liveRefreshTask)
    }

    func testActiveLiveActivityMessageEventBypassesSelectedDirectoryGateAndUpdatesCache() {
        let viewModel = AppViewModel()
        let selected = makeSession(id: "ses_selected")
        let live = OpenCodeSession(
            id: "ses_live",
            title: "Live",
            workspaceID: nil,
            directory: "/tmp/live-project",
            projectID: "proj_live",
            parentID: nil
        )

        viewModel.isConnected = true
        viewModel.selectedDirectory = "/tmp/selected-project"
        viewModel.selectedSession = selected
        viewModel.activeLiveActivitySessionIDs = [live.id]

        viewModel.handleManagedEvent(
            OpenCodeManagedEvent(
                directory: "/tmp/live-project",
                envelope: OpenCodeEventEnvelope(
                    type: "message.part.delta",
                    properties: OpenCodeEventProperties(
                        sessionID: live.id,
                        messageID: "msg_live_assistant",
                        partID: "prt_live_text",
                        field: "text",
                        delta: "Streaming live"
                    )
                ),
                typed: .messagePartDelta(
                    sessionID: live.id,
                    messageID: "msg_live_assistant",
                    partID: "prt_live_text",
                    field: "text",
                    delta: "Streaming live"
                )
            )
        )

        let cachedText = viewModel.cachedMessagesBySessionID[live.id]?.first?.parts.first?.text
        XCTAssertEqual(cachedText, "Streaming live")
    }

    func testActiveLiveActivityPromptEventBypassesSelectedDirectoryGate() {
        let viewModel = AppViewModel()
        let selected = makeSession(id: "ses_selected")
        let permission = OpenCodePermission(
            id: "perm_live",
            sessionID: "ses_live",
            permission: "bash",
            patterns: ["xcodebuild test"],
            always: nil,
            metadata: nil,
            tool: nil
        )

        viewModel.isConnected = true
        viewModel.selectedDirectory = "/tmp/selected-project"
        viewModel.selectedSession = selected
        viewModel.activeLiveActivitySessionIDs = [permission.sessionID]

        viewModel.handleManagedEvent(
            OpenCodeManagedEvent(
                directory: "/tmp/live-project",
                envelope: OpenCodeEventEnvelope(
                    type: "permission.asked",
                    properties: OpenCodeEventProperties(
                        sessionID: permission.sessionID,
                        id: permission.id,
                        permission: permission.permission,
                        patterns: permission.patterns
                    )
                ),
                typed: .permissionAsked(permission)
            )
        )

        XCTAssertEqual(viewModel.permissions(for: permission.sessionID).map(\.id), [permission.id])
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

        viewModel.selectedSession = session
        viewModel.sessionStatuses[session.id] = "busy"
        viewModel.messages = [
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

        viewModel.selectedSession = session
        viewModel.sessionStatuses[session.id] = "busy"
        viewModel.messages = [
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

        viewModel.selectedSession = session
        viewModel.sessionStatuses[session.id] = "busy"
        viewModel.messages = [
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

        viewModel.selectedSession = selected
        viewModel.sessionStatuses[background.id] = "busy"
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

    func testModelConfigurationStoreDerivesSelectableAgentsAndDefaultModel() {
        let store = ModelConfigurationStore(
            availableAgents: [
                OpenCodeAgent(name: "build", description: nil, mode: "primary", hidden: nil, model: nil, variant: nil),
                OpenCodeAgent(name: "hidden", description: nil, mode: "primary", hidden: true, model: nil, variant: nil),
                OpenCodeAgent(name: "sub", description: nil, mode: "subagent", hidden: nil, model: nil, variant: nil),
                OpenCodeAgent(name: "all", description: nil, mode: "all", hidden: nil, model: nil, variant: nil),
            ],
            availableProviders: [makeProvider(id: "openai", name: "OpenAI", modelID: "gpt-5.4-mini", modelName: "GPT-5.4 mini")],
            defaultModelsByProviderID: ["openai": "gpt-5.4-mini"]
        )

        XCTAssertEqual(store.selectableAgents.map(\.name), ["all", "build"])
        XCTAssertEqual(store.mentionableAgents.map(\.name), ["all", "sub"])
        XCTAssertEqual(store.defaultModelReference(), OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.4-mini"))
    }

    func testModelConfigurationStoreSanitizesInvalidDefaultsAndSelections() {
        let store = ModelConfigurationStore(
            availableAgents: [OpenCodeAgent(name: "valid", description: nil, mode: "primary", hidden: nil, model: nil, variant: nil)],
            availableProviders: [makeProvider(id: "openai", name: "OpenAI", modelID: "gpt-5.4-mini", modelName: "GPT-5.4 mini")],
            selectedAgentNamesBySessionID: ["ses_valid": "valid", "ses_invalid": "missing"],
            selectedModelsBySessionID: [
                "ses_valid": OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.4-mini"),
                "ses_invalid": OpenCodeModelReference(providerID: "missing", modelID: "missing"),
            ],
            selectedVariantsBySessionID: ["ses_valid": "invalid"],
            newSessionDefaults: NewSessionDefaults(agentName: "missing", providerID: "missing", modelID: "missing", reasoningVariant: "invalid")
        )

        store.sanitizeComposerSelections(validSessionIDs: ["ses_valid"])

        XCTAssertEqual(store.selectedAgentNamesBySessionID, ["ses_valid": "valid"])
        XCTAssertEqual(store.selectedModelsBySessionID, ["ses_valid": OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.4-mini")])
        XCTAssertTrue(store.selectedVariantsBySessionID.isEmpty)
        XCTAssertEqual(store.newSessionDefaults, NewSessionDefaults())
    }

    func testModelConfigurationStoreSeedsAndClearsSessionSelections() {
        let reference = OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.4-mini")
        let store = ModelConfigurationStore(
            availableAgents: [OpenCodeAgent(name: "valid", description: nil, mode: "primary", hidden: nil, model: nil, variant: nil)],
            availableProviders: [makeProvider(id: "openai", name: "OpenAI", modelID: "gpt-5.4-mini", modelName: "GPT-5.4 mini")],
            newSessionDefaults: NewSessionDefaults(agentName: "valid", providerID: "openai", modelID: "gpt-5.4-mini", reasoningVariant: nil)
        )

        store.seedSelectionsForNewSession(sessionID: "ses_new")
        XCTAssertEqual(store.selectedAgentNamesBySessionID["ses_new"], "valid")
        XCTAssertEqual(store.selectedModelsBySessionID["ses_new"], reference)

        store.selectModel(nil, forSessionID: "ses_new")
        XCTAssertNil(store.selectedModelsBySessionID["ses_new"])
        XCTAssertNil(store.selectedVariantsBySessionID["ses_new"])
    }

    private func makeCommand(_ name: String) -> OpenCodeCommand {
        OpenCodeCommand(
            name: name,
            description: nil,
            agent: nil,
            model: nil,
            source: "test",
            template: "",
            subtask: nil,
            hints: []
        )
    }

    private func makeSession(id: String) -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            title: id,
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "proj_test",
            parentID: nil
        )
    }

    private func makeProvider(id: String, name: String, modelID: String, modelName: String, reasoning: Bool = false) -> OpenCodeProvider {
        OpenCodeProvider(
            id: id,
            name: name,
            models: [
                modelID: OpenCodeModel(
                    id: modelID,
                    providerID: id,
                    name: modelName,
                    capabilities: OpenCodeModelCapabilities(reasoning: reasoning),
                    variants: nil
                ),
            ]
        )
    }

    private func makeMessage(id: String, text: String, sessionID: String, role: String = "assistant") -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(id: id, role: role, sessionID: sessionID, time: nil, agent: nil, model: nil),
            parts: [
                OpenCodePart(id: "part_\(id)", messageID: id, sessionID: sessionID, type: "text", mime: nil, filename: nil, url: nil, reason: nil, tool: nil, callID: nil, state: nil, text: text),
            ]
        )
    }

    private func makeFileNode(name: String, path: String, absolute: String, type: String = "file") -> OpenCodeFileNode {
        OpenCodeFileNode(name: name, path: path, absolute: absolute, type: type, ignored: nil)
    }
}
