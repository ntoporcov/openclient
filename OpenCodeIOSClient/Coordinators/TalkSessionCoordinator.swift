import Combine
import Foundation

@MainActor
final class TalkSessionCoordinator: ObservableObject {
    enum Phase: Equatable {
        case inactive
        case choosingProject
        case listening
        case creatingSession
        case conversation
    }

    @Published private(set) var phase: Phase = .inactive
    @Published private(set) var selectedProjectID: String?

    let conversationController: ConversationModeController

    private unowned let viewModel: AppViewModel
    private var workspaceDirectory: String?
    private(set) var activeSessionID: String?
    private(set) var pendingMessageID: String?
    private var createdSession: OpenCodeSession?
    private var connectionID: UUID?
    private var composerSelection: NewProjectChatComposerSelection?
    private var submissionContextID: String?
    private var launchID: UUID?
    private var submissionTask: Task<Void, Never>?
    private var isApplicationActive = true
    private var observations: Set<AnyCancellable> = []
    private var directoryObservation: AnyCancellable?

    init(viewModel: AppViewModel, conversationController: ConversationModeController? = nil) {
        self.viewModel = viewModel
        self.conversationController = conversationController ?? ConversationModeController(voiceStore: viewModel.speechVoiceStore)

        self.conversationController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)

        self.conversationController.$sendRequestToken
            .dropFirst()
            .sink { [weak self] _ in self?.submitCapturedTurn() }
            .store(in: &observations)

        viewModel.chatStore.$messages
            .dropFirst()
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshConversationState() }
            }
            .store(in: &observations)

        Publishers.Merge(viewModel.connectionStore.objectWillChange, viewModel.chatStore.objectWillChange)
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshConversationState() }
            }
            .store(in: &observations)

        viewModel.sessionInteractionStore.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshConversationState() }
            }
            .store(in: &observations)

        viewModel.projectStore.objectWillChange
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async { self?.refreshConversationState() }
            }
            .store(in: &observations)

        viewModel.commerceFacade.store.$paywallReason
            .dropFirst()
            .sink { [weak self] reason in self?.paywallPresentationChanged(reason) }
            .store(in: &observations)

        bindDirectoryStore(viewModel.directoryStoreRegistry.activeStore)
        viewModel.directoryStoreRegistry.$activeStore
            .dropFirst()
            .sink { [weak self] store in
                guard let self else { return }
                if let activeSessionID = self.activeSessionID,
                   let owner = self.viewModel.directoryStoreRegistry.ownerStore(forSessionID: activeSessionID) {
                    self.bindDirectoryStore(owner)
                } else {
                    self.bindDirectoryStore(store)
                }
                self.refreshConversationState()
            }
            .store(in: &observations)
    }

    var isPresented: Bool { phase != .inactive }
    var isChoosingProject: Bool { phase == .choosingProject }
    var projects: [OpenCodeProject] { viewModel.projects }

    func presentProjectSelection() {
        guard viewModel.projectFacade.allowsNewTalk, isApplicationActive else { return }
        stopCurrentConversation()
        phase = .choosingProject
    }

    func start(project: OpenCodeProject, workspaceDirectory: String? = nil) {
        guard viewModel.projectFacade.allowsNewTalk, isApplicationActive,
              viewModel.commerceFacade.paywallReason == nil else { return }
        stopCurrentConversation()
        connectionID = viewModel.backendConnection?.id
        selectedProjectID = project.id
        self.workspaceDirectory = project.id == "global" ? nil : workspaceDirectory ?? project.worktree
        launchID = UUID()
        let defaults = viewModel.modelConfigurationStore.newSessionDefaults
        let model = viewModel.modelConfigurationStore.voiceModeModelReference()
            ?? defaults.providerID.flatMap { provider in
                defaults.modelID.map { OpenCodeModelReference(providerID: provider, modelID: $0) }
            }
        composerSelection = NewProjectChatComposerSelection(agentName: defaults.agentName,
            modelReference: model, reasoningVariant: defaults.reasoningVariant)
        phase = .listening
        conversationController.setAudioAvailable(true)
        conversationController.start(initialTranscript: "")
        if viewModel.chatFacade.supportsTalkLiveActivities {
            conversationController.startLiveActivity(
                title: projectTitle(project),
                directory: self.workspaceDirectory,
                workspaceID: nil,
                sessionID: nil
            )
        }
    }

    func selectProject(_ project: OpenCodeProject) {
        start(project: project)
    }

    func stop() {
        launchID = nil
        submissionTask?.cancel()
        submissionTask = nil
        stopCurrentConversation()
        phase = .inactive
    }

    func setHoldToTalkEnabled(_ isEnabled: Bool) {
        conversationController.setHoldToTalkEnabled(isEnabled)
    }

    func applicationActivityChanged(isActive: Bool) {
        isApplicationActive = isActive
        refreshConversationState()
    }

    func projectTitle(_ project: OpenCodeProject) -> String {
        if project.id == "global" {
            return String(localized: "Global", comment: "Name of the special project containing sessions shared across the server context.")
        }
        return project.name ?? URL(fileURLWithPath: project.worktree).lastPathComponent
    }

    private func submitCapturedTurn() {
        guard conversationController.state == .submitting, pendingMessageID == nil, submissionTask == nil,
              conversationController.submittedMessageID == nil,
              isApplicationActive, viewModel.commerceFacade.paywallReason == nil,
              connectionID == viewModel.backendConnection?.id, viewModel.projectFacade.allowsNewTalk else {
            conversationController.pause()
            return
        }
        if let session = activeSession() {
            submitTurn(in: session)
        } else {
            createSessionWithFirstTurn()
        }
    }

    private func createSessionWithFirstTurn() {
        guard phase == .listening,
              let launchID,
              let projectID = selectedProjectID,
              let project = viewModel.projects.first(where: { $0.id == projectID }) else {
            conversationController.submissionDidNotStart()
            return
        }

        let prompt = conversationController.transcript
        let baselineMessageIDs: Set<String> = []
        let selection = composerSelection
        let directory = workspaceDirectory
        let messageID = OpenCodeIdentifier.message()
        pendingMessageID = messageID
        let connectionID = connectionID
        // startNewProjectChat prepares its directory once before creating the session.
        let preparedNavigationGeneration = viewModel.sessionNavigationGeneration &+ 1
        conversationController.didSubmit(baselineMessageIDs: baselineMessageIDs)
        phase = .creatingSession

        submissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didStart = await self.viewModel.startNewProjectChat(
                prompt: prompt,
                messageID: messageID,
                composerSelection: selection,
                projectID: project.id,
                workspaceDirectory: directory,
                onSessionCreated: { [weak self] session in
                    guard let self, !Task.isCancelled, self.launchID == launchID,
                          self.viewModel.backendConnection?.id == connectionID else { return }
                    // The POST can wait for a whole turn, including pending forms.
                    // Bind the canonical chat before awaiting that first input.
                    self.createdSession = session
                    self.activeSessionID = session.id
                    guard self.viewModel.sessionNavigationGeneration == preparedNavigationGeneration,
                          self.viewModel.currentProject?.id == project.id,
                          self.viewModel.selectedSession == nil || self.viewModel.selectedSession?.id == session.id else {
                        self.launchID = nil
                        self.submissionTask?.cancel()
                        self.phase = .conversation
                        self.conversationController.setAudioAvailable(false)
                        return
                    }
                    if self.viewModel.connectionStore.apiProfile == .v2 {
                        _ = self.viewModel.beginSessionNavigation(session)
                    } else {
                        self.viewModel.prepareSessionSelection(session)
                    }
                    self.viewModel.chatFacade.setActiveChatSessionID(session.id)
                    self.submissionContextID = self.viewModel.chatFacade.promptContextID
                    self.bindDirectoryStore(self.viewModel.chatFacade.directoryStore(forSessionID: session.id))
                    self.phase = .conversation
                    self.conversationController.updateLiveActivitySessionID(session.id)
                    self.viewModel.appShellFacade.selectProjectContent()
                    self.viewModel.chatDetailPresentationRequest &+= 1
                    self.refreshConversationState()
                },
                isSubmissionCurrent: { [weak self] in
                    guard let self, self.launchID == launchID,
                          self.viewModel.backendConnection?.id == connectionID else { return false }
                    return self.submissionContextID == nil
                        || self.submissionContextID == self.viewModel.chatFacade.promptContextID
                }
            )
            guard !Task.isCancelled, self.launchID == launchID,
                  self.viewModel.backendConnection?.id == connectionID else { return }
            self.submissionTask = nil
            if let activeSessionID = self.activeSessionID,
               self.viewModel.selectedSession?.id != activeSessionID {
                self.conversationController.setAudioAvailable(false)
                return
            }
            if !didStart {
                self.conversationController.submissionAdmissionChanged(isAdmitted: false,
                    errorMessage: self.viewModel.commerceFacade.paywallReason == nil
                        ? self.viewModel.errorMessage ?? String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.")
                        : nil)
            }
            self.refreshConversationState()
        }
    }

    private func submitTurn(in session: OpenCodeSession) {
        guard phase == .conversation,
              !viewModel.chatFacade.hasPendingPromptAdmission(sessionID: session.id),
              viewModel.chatFacade.sessionForms(forSessionID: session.id).isEmpty else {
            conversationController.submissionAdmissionChanged(isAdmitted: false)
            return
        }
        submissionContextID = viewModel.chatFacade.promptContextID
        conversationController.submitTurn(in: session, chatFacade: viewModel.chatFacade)
    }

    private func refreshConversationState() {
        guard isPresented, !isChoosingProject else { return }
        guard connectionID == viewModel.backendConnection?.id else {
            stop()
            return
        }
        let available = isApplicationActive && viewModel.projectFacade.allowsNewTalk
            && viewModel.commerceFacade.paywallReason == nil
        conversationController.setAudioAvailable(available)
        guard available else { return }
        if phase == .listening || phase == .creatingSession {
            conversationController.resume(isSessionBusy: phase == .creatingSession)
            return
        }
        guard phase == .conversation, let activeSessionID else { return }
        guard viewModel.selectedSession?.id == activeSessionID,
              viewModel.currentProject?.id == selectedProjectID else {
            submissionTask?.cancel()
            submissionTask = nil
            conversationController.setAudioAvailable(false)
            return
        }
        if let submissionContextID, submissionContextID != viewModel.chatFacade.promptContextID {
            conversationController.setAudioAvailable(false)
            return
        }
        let store = viewModel.directoryStoreRegistry.ownerStore(forSessionID: activeSessionID)
            ?? viewModel.directoryStoreRegistry.activeStore
        let snapshot = viewModel.directoryStoreRegistry.snapshot(forSessionID: activeSessionID)
        let isBusy = snapshot?.status == "busy" || submissionTask != nil
        let permissions = SessionInteractionStore.permissions(
            forSessionTreeRootID: activeSessionID,
            sessions: store.sessions,
            permissionsBySessionID: store.syncState.permissionsBySessionID
        )
        let questions = SessionInteractionStore.questions(
            forSessionTreeRootID: activeSessionID,
            sessions: store.sessions,
            questionsBySessionID: store.syncState.questionsBySessionID
        )
        let hasBlockingInteraction = !permissions.isEmpty || !questions.isEmpty
            || !viewModel.chatFacade.sessionForms(forSessionID: activeSessionID).isEmpty
        let messages = snapshot?.messages.isEmpty == false
            ? snapshot?.messages ?? []
            : viewModel.chatStore.messages.filter { $0.info.sessionID == activeSessionID }

        if let pendingMessageID {
            let admission = viewModel.chatFacade.promptAdmissionPhase(messageID: pendingMessageID, sessionID: activeSessionID)
            if admission == .admitted {
                if submissionTask == nil { self.pendingMessageID = nil }
                conversationController.submissionAdmissionChanged(isAdmitted: true)
            } else if admission == .uncertain || admission == .rejected {
                conversationController.submissionAdmissionChanged(isAdmitted: false)
            }
        }
        if hasBlockingInteraction {
            conversationController.setAudioAvailable(false)
        } else {
            conversationController.refreshPromptAdmission(chatFacade: viewModel.chatFacade)
            conversationController.resume(isSessionBusy: isBusy)
            conversationController.update(messages: messages, isSessionBusy: isBusy)
        }
    }

    private func activeSession() -> OpenCodeSession? {
        guard let activeSessionID else { return nil }
        return viewModel.directoryStoreRegistry.snapshot(forSessionID: activeSessionID)?.session ?? createdSession
    }

    private func bindDirectoryStore(_ store: DirectoryStore) {
        directoryObservation = Publishers.Merge(
            store.objectWillChange.eraseToAnyPublisher(),
            store.syncStore.objectWillChange.eraseToAnyPublisher()
        )
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshConversationState() }
            }
    }

    private func stopCurrentConversation() {
        launchID = nil
        submissionTask?.cancel()
        submissionTask = nil
        conversationController.stop()
        activeSessionID = nil
        selectedProjectID = nil
        workspaceDirectory = nil
        createdSession = nil
        pendingMessageID = nil
        connectionID = nil
        composerSelection = nil
        submissionContextID = nil
    }

    private func paywallPresentationChanged(_ reason: OpenClientPaywallReason?) {
        if reason != nil {
            conversationController.setAudioAvailable(false)
        } else {
            DispatchQueue.main.async { [weak self] in self?.refreshConversationState() }
        }
    }
}
