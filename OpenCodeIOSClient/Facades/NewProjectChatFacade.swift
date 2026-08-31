import Combine
import Foundation

@MainActor
final class NewProjectChatFacade: ObservableObject {
    private unowned let viewModel: AppViewModel
    private var observations: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel

        Publishers.MergeMany([
            viewModel.projectStore.$projects.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.projectStore.$currentProject.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.projectPreferencesStore.$projectWorkspacesEnabledByScope.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$availableAgents.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$allProviders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$availableProviders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$modelVisibilityPreferences.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$defaultModelsByProviderID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$newSessionDefaults.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)
    }

    var projects: [OpenCodeProject] { viewModel.projects }
    var currentProject: OpenCodeProject? { viewModel.currentProject }
    var paywallReason: OpenClientPaywallReason? { viewModel.commerceFacade.paywallReason }
    var selectableAgents: [OpenCodeAgent] { viewModel.selectableAgents }
    var sortedProviders: [OpenCodeProvider] { viewModel.sortedProviders }
    var newSessionDefaults: NewSessionDefaults { viewModel.newSessionDefaults }

    func dismissNewChat() { viewModel.dismissNewProjectChatSheet() }
    func visibleModels(for provider: OpenCodeProvider) -> [OpenCodeModel] {
        viewModel.modelConfigurationStore.visibleModels(for: provider)
    }
    func formattedVariantTitle(_ variant: String) -> String { viewModel.formattedVariantTitle(variant) }
    func defaultModelReference() -> OpenCodeModelReference? { viewModel.defaultModelReference() }
    func newSessionDefaultModelReference() -> OpenCodeModelReference? { viewModel.newSessionDefaultModelReference() }
    func model(for reference: OpenCodeModelReference?) -> OpenCodeModel? { viewModel.model(for: reference) }
    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] { viewModel.reasoningVariants(for: reference) }
    func workspaceDirectories(for project: OpenCodeProject) -> [String] { viewModel.workspaceDirectories(for: project) }
    func isWorkspacesEnabled(for project: OpenCodeProject) -> Bool { viewModel.isProjectWorkspacesEnabled(for: project) }
    func workspaceKey(_ directory: String) -> String { viewModel.workspaceKey(directory) }
    func workspaceDisplayName(for directory: String?, in project: OpenCodeProject?) -> String? {
        viewModel.workspaceDisplayName(for: directory, in: project)
    }

    @discardableResult
    func startNewChat(
        title: String,
        prompt: String,
        agentMentions: [OpenCodeAgentMention],
        attachments: [OpenCodeComposerAttachment],
        messageID: String,
        partID: String,
        composerSelection: NewProjectChatComposerSelection,
        projectID: String,
        workspaceDirectory: String?,
        workspaceSelection: NewSessionWorkspaceSelection?,
        newWorkspaceName: String
    ) async -> Bool {
        await viewModel.startNewProjectChat(
            title: title,
            prompt: prompt,
            agentMentions: agentMentions,
            attachments: attachments,
            messageID: messageID,
            partID: partID,
            composerSelection: composerSelection,
            projectID: projectID,
            workspaceDirectory: workspaceDirectory,
            workspaceSelection: workspaceSelection,
            newWorkspaceName: newWorkspaceName
        )
    }

}
