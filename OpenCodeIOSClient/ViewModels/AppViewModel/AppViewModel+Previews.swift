import Foundation

#if DEBUG
extension AppViewModel {
    static func preview(
        isConnected: Bool = true,
        currentProject: OpenCodeProject? = OpenCodePreviewData.repoProject,
        selectedDirectory: String? = OpenCodePreviewData.repoProject.worktree,
        sessions: [OpenCodeSession] = OpenCodePreviewData.sessions,
        selectedSession: OpenCodeSession? = OpenCodePreviewData.primarySession,
        messages: [OpenCodeMessageEnvelope] = OpenCodePreviewData.messages,
        todos: [OpenCodeTodo] = OpenCodePreviewData.todos,
        permissions: [OpenCodePermission] = [],
        questions: [OpenCodeQuestionRequest] = [],
        sessionStatuses: [String: String] = [OpenCodePreviewData.primarySession.id: "busy"],
        errorMessage: String? = nil,
        showSavedServerPrompt: Bool = false,
        hasSavedServer: Bool = false,
        isShowingCreateSessionSheet: Bool = false,
        draftTitle: String = "",
        draftMessage: String = "Polish the chat spacing a bit.",
        toolMessageDetails: [String: OpenCodeMessageEnvelope] = OpenCodePreviewData.toolMessageDetails
    ) -> AppViewModel {
        let viewModel = AppViewModel()
        viewModel.config = OpenCodePreviewData.config
        viewModel.isConnected = isConnected
        viewModel.projects = OpenCodePreviewData.projects
        viewModel.currentProject = currentProject
        viewModel.selectedDirectory = selectedDirectory
        viewModel.directoryState = OpenCodeDirectoryState(
            sessions: sessions,
            selectedSession: selectedSession,
            messages: messages,
            sessionStatuses: sessionStatuses,
            todos: todos,
            permissions: permissions,
            questions: questions
        )
        viewModel.toolMessageDetails = toolMessageDetails
        viewModel.sessionPreviews = OpenCodePreviewData.sessionPreviews
        viewModel.availableAgents = OpenCodePreviewData.agents
        viewModel.availableProviders = OpenCodePreviewData.providers
        viewModel.defaultModelsByProviderID = OpenCodePreviewData.defaultModelsByProviderID
        viewModel.errorMessage = errorMessage
        viewModel.showSavedServerPrompt = showSavedServerPrompt
        viewModel.hasSavedServer = hasSavedServer
        viewModel.isShowingCreateSessionSheet = isShowingCreateSessionSheet
        viewModel.draftTitle = draftTitle
        viewModel.draftMessage = draftMessage
        viewModel.selectAgent(named: OpenCodePreviewData.agents.first?.name, for: OpenCodePreviewData.primarySession)
        viewModel.selectModel(OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.4"), for: OpenCodePreviewData.primarySession)
        viewModel.selectVariant("balanced", for: OpenCodePreviewData.primarySession)
        return viewModel
    }
}
#endif
