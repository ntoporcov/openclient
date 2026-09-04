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
    private var activeSessionID: String?
    private var launchID: UUID?
    private var submissionTask: Task<Void, Never>?
    private var isAwaitingPaywallRecovery = false
    private var isAwaitingForegroundSubmissionRecovery = false
    private var isApplicationActive = true
    private var observations: Set<AnyCancellable> = []
    private var directoryObservation: AnyCancellable?

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        conversationController = ConversationModeController(voiceStore: viewModel.speechVoiceStore)

        conversationController.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &observations)

        conversationController.$sendRequestToken
            .dropFirst()
            .sink { [weak self] _ in self?.submitCapturedTurn() }
            .store(in: &observations)

        viewModel.chatStore.$messages
            .dropFirst()
            .sink { [weak self] _ in self?.refreshConversationState() }
            .store(in: &observations)

        viewModel.sessionInteractionStore.objectWillChange
            .sink { [weak self] _ in
                DispatchQueue.main.async { self?.refreshConversationState() }
            }
            .store(in: &observations)

        viewModel.projectStore.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
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
        guard viewModel.backendMode == .server, viewModel.isConnected else { return }
        stopCurrentConversation()
        phase = .choosingProject
    }

    func start(project: OpenCodeProject, workspaceDirectory: String? = nil) {
        guard viewModel.backendMode == .server, viewModel.isConnected else { return }
        stopCurrentConversation()
        selectedProjectID = project.id
        self.workspaceDirectory = project.id == "global" ? nil : workspaceDirectory ?? project.worktree
        launchID = UUID()
        phase = .listening
        conversationController.start(initialTranscript: "")
        conversationController.startLiveActivity(
            title: projectTitle(project),
            directory: self.workspaceDirectory,
            workspaceID: nil,
            sessionID: nil
        )
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
        guard isPresented, !isChoosingProject else { return }
        guard isActive else {
            conversationController.pause()
            return
        }
        guard viewModel.commerceFacade.paywallReason == nil else { return }
        switch phase {
        case .listening:
            conversationController.resume(isSessionBusy: false)
        case .creatingSession:
            conversationController.resume(isSessionBusy: true)
        case .conversation:
            refreshConversationState()
        case .inactive, .choosingProject:
            break
        }
        recoverPendingSubmissionIfPossible()
    }

    func projectTitle(_ project: OpenCodeProject) -> String {
        if project.id == "global" {
            return String(localized: "Global", comment: "Name of the special project containing sessions shared across the server context.")
        }
        return project.name ?? URL(fileURLWithPath: project.worktree).lastPathComponent
    }

    private func submitCapturedTurn() {
        guard conversationController.state == .submitting else { return }
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
        let defaults = viewModel.modelConfigurationStore.newSessionDefaults
        let voiceModelReference = defaults.voiceModeProviderID.flatMap { providerID in
            defaults.voiceModeModelID.map { OpenCodeModelReference(providerID: providerID, modelID: $0) }
        }
        let defaultModelReference = defaults.providerID.flatMap { providerID in
            defaults.modelID.map { OpenCodeModelReference(providerID: providerID, modelID: $0) }
        }
        let modelReference = voiceModelReference ?? defaultModelReference
        let previousSessionID = viewModel.selectedSession?.id
        var createdSession: OpenCodeSession?
        conversationController.didSubmit(baselineMessageIDs: baselineMessageIDs)
        phase = .creatingSession

        submissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didStart = await self.viewModel.startNewProjectChat(
                prompt: prompt,
                composerSelection: NewProjectChatComposerSelection(
                    agentName: defaults.agentName,
                    modelReference: modelReference,
                    reasoningVariant: defaults.reasoningVariant
                ),
                projectID: project.id,
                workspaceDirectory: self.workspaceDirectory,
                onSessionCreated: { createdSession = $0 }
            )
            guard !Task.isCancelled, self.launchID == launchID else { return }
            self.submissionTask = nil
            guard didStart, let session = self.viewModel.selectedSession else {
                let reusableSession = createdSession
                    ?? self.viewModel.selectedSession.flatMap { $0.id != previousSessionID ? $0 : nil }
                if let createdSession = reusableSession {
                    if self.viewModel.selectedSession?.id != createdSession.id {
                        self.viewModel.prepareSessionSelection(createdSession)
                        await self.viewModel.selectSession(createdSession)
                    }
                    self.activeSessionID = createdSession.id
                    self.conversationController.updateLiveActivitySessionID(createdSession.id)
                    self.phase = .conversation
                    self.bindDirectoryStore(
                        self.viewModel.directoryStoreRegistry.ownerStore(forSessionID: createdSession.id)
                            ?? self.viewModel.directoryStoreRegistry.activeStore
                    )
                    self.viewModel.appShellFacade.selectProjectContent()
                    self.viewModel.chatDetailPresentationRequest &+= 1
                    self.recoverFailedSubmission()
                    return
                }
                self.phase = .listening
                if self.viewModel.commerceFacade.paywallReason != nil {
                    self.isAwaitingPaywallRecovery = true
                } else {
                    self.recoverFailedSubmission(errorMessage: self.viewModel.errorMessage)
                }
                return
            }

            self.activeSessionID = session.id
            self.conversationController.updateLiveActivitySessionID(session.id)
            self.phase = .conversation
            self.bindDirectoryStore(
                self.viewModel.directoryStoreRegistry.ownerStore(forSessionID: session.id)
                    ?? self.viewModel.directoryStoreRegistry.activeStore
            )
            self.viewModel.appShellFacade.selectProjectContent()
            self.viewModel.chatDetailPresentationRequest &+= 1
            self.refreshConversationState()
        }
    }

    private func submitTurn(in session: OpenCodeSession) {
        guard phase == .conversation else {
            conversationController.submissionDidNotStart()
            return
        }
        let prompt = conversationController.transcript
        let baselineMessageIDs = Set(
            (viewModel.directoryStoreRegistry.snapshot(forSessionID: session.id)?.messages ?? []).map(\.id)
        )
        guard let launchID else {
            conversationController.submissionDidNotStart()
            return
        }
        conversationController.didSubmit(baselineMessageIDs: baselineMessageIDs)

        submissionTask = Task { @MainActor [weak self] in
            guard let self else { return }
            let didSend = await self.viewModel.sendMessage(
                prompt,
                in: session,
                userVisible: true
            )
            guard !Task.isCancelled, self.launchID == launchID else { return }
            self.submissionTask = nil
            if didSend {
                self.refreshConversationState()
            } else {
                self.recoverFailedSubmission(errorMessage: self.viewModel.errorMessage)
            }
        }
    }

    private func refreshConversationState() {
        guard phase == .conversation, let activeSessionID else { return }
        let store = viewModel.directoryStoreRegistry.ownerStore(forSessionID: activeSessionID)
            ?? viewModel.directoryStoreRegistry.activeStore
        let snapshot = viewModel.directoryStoreRegistry.snapshot(forSessionID: activeSessionID)
        let isBusy = snapshot?.status == "busy"
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
        let messages = snapshot?.messages.isEmpty == false
            ? snapshot?.messages ?? []
            : viewModel.chatStore.messages.filter { $0.info.sessionID == activeSessionID }

        if hasBlockingInteraction {
            conversationController.pause()
        } else {
            conversationController.resume(isSessionBusy: isBusy)
            conversationController.update(messages: messages, isSessionBusy: isBusy)
        }
    }

    private func activeSession() -> OpenCodeSession? {
        guard let activeSessionID else { return nil }
        return viewModel.directoryStoreRegistry.snapshot(forSessionID: activeSessionID)?.session
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
        conversationController.stop()
        activeSessionID = nil
        selectedProjectID = nil
        workspaceDirectory = nil
        isAwaitingPaywallRecovery = false
        isAwaitingForegroundSubmissionRecovery = false
    }

    private func paywallPresentationChanged(_ reason: OpenClientPaywallReason?) {
        guard isPresented else { return }
        if reason != nil {
            conversationController.pause()
            return
        }
        guard isApplicationActive else { return }
        switch phase {
        case .listening:
            conversationController.resume(isSessionBusy: false)
        case .creatingSession:
            conversationController.resume(isSessionBusy: true)
        case .conversation:
            refreshConversationState()
        case .inactive, .choosingProject:
            break
        }
        recoverPendingSubmissionIfPossible()
    }

    private func recoverFailedSubmission(errorMessage: String? = nil) {
        if conversationController.state == .paused {
            isAwaitingForegroundSubmissionRecovery = true
            isAwaitingPaywallRecovery = viewModel.commerceFacade.paywallReason != nil
        } else {
            conversationController.submissionDidNotStart()
        }
        if let errorMessage {
            conversationController.errorMessage = errorMessage
        }
    }

    private func recoverPendingSubmissionIfPossible() {
        guard isAwaitingPaywallRecovery || isAwaitingForegroundSubmissionRecovery,
              isApplicationActive,
              viewModel.commerceFacade.paywallReason == nil,
              conversationController.state != .paused else {
            return
        }
        isAwaitingPaywallRecovery = false
        isAwaitingForegroundSubmissionRecovery = false
        conversationController.submissionDidNotStart()
    }
}
