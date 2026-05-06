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
        recentServerConfigs: [OpenCodeServerConfig]? = nil,
        isShowingAddServerSheet: Bool = false,
        isShowingCreateSessionSheet: Bool = false,
        draftTitle: String = "",
        draftMessage: String = "Polish the chat spacing a bit.",
        draftAttachments: [OpenCodeComposerAttachment] = OpenCodePreviewData.composerAttachments,
        toolMessageDetails: [String: OpenCodeMessageEnvelope] = OpenCodePreviewData.toolMessageDetails
    ) -> AppViewModel {
        let viewModel = AppViewModel()
        viewModel.config = OpenCodePreviewData.config
        viewModel.isConnected = isConnected
        viewModel.projects = OpenCodePreviewData.projects
        viewModel.currentProject = currentProject
        viewModel.selectedDirectory = selectedDirectory
        viewModel.allSessions = sessions
        viewModel.selectedSession = selectedSession
        viewModel.sessionStatuses = sessionStatuses
        viewModel.messages = messages
        viewModel.todos = todos
        viewModel.permissions = permissions
        viewModel.questions = questions
        viewModel.toolMessageDetails = toolMessageDetails
        viewModel.sessionPreviews = OpenCodePreviewData.sessionPreviews
        viewModel.availableAgents = OpenCodePreviewData.agents
        viewModel.availableProviders = OpenCodePreviewData.providers
        viewModel.defaultModelsByProviderID = OpenCodePreviewData.defaultModelsByProviderID
        viewModel.directoryCommands = OpenCodePreviewData.commands
        viewModel.errorMessage = errorMessage
        viewModel.showSavedServerPrompt = showSavedServerPrompt
        viewModel.hasSavedServer = hasSavedServer
        if let recentServerConfigs {
            viewModel.recentServerConfigs = recentServerConfigs
        } else if hasSavedServer {
            viewModel.recentServerConfigs = [OpenCodePreviewData.config]
        }
        viewModel.isShowingAddServerSheet = isShowingAddServerSheet
        viewModel.isShowingCreateSessionSheet = isShowingCreateSessionSheet
        viewModel.draftTitle = draftTitle
        viewModel.draftMessage = draftMessage
        viewModel.draftAttachments = draftAttachments
        viewModel.selectAgent(named: OpenCodePreviewData.agents.first?.name, for: OpenCodePreviewData.primarySession)
        viewModel.selectModel(OpenCodeModelReference(providerID: "openai", modelID: "gpt-5.4"), for: OpenCodePreviewData.primarySession)
        viewModel.selectVariant("balanced", for: OpenCodePreviewData.primarySession)
        return viewModel
    }
}
#endif
