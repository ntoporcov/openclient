import Combine
import Foundation

@MainActor
final class ConfigurationsFacade: ObservableObject {
    private unowned let viewModel: AppViewModel
    private var observations: Set<AnyCancellable> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel
        Publishers.MergeMany([
            viewModel.modelConfigurationStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.projectPreferencesStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.$config.map { _ in () }.eraseToAnyPublisher(),
            viewModel.$isShowingConfigurationsSheet.map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)
    }

    var modelConfigurationStore: ModelConfigurationStore { viewModel.modelConfigurationStore }
    var configurationAgentTitle: String { viewModel.configurationAgentTitle }
    var configurationModelTitle: String { viewModel.configurationModelTitle }
    var configurationReasoningTitle: String { viewModel.configurationReasoningTitle }
    var configurationVoiceModeModelTitle: String { viewModel.modelConfigurationStore.configurationVoiceModeModelTitle }
    var configurationReasoningVariants: [String] { viewModel.configurationReasoningVariants }
    var isLoadingProviders: Bool { viewModel.isLoadingProviders }
    var sortedConnectedProviders: [OpenCodeProvider] { viewModel.sortedConnectedProviders }
    var popularAddableProviders: [OpenCodeProvider] { viewModel.popularAddableProviders }
    var addableProviders: [OpenCodeProvider] { viewModel.addableProviders }
    var sortedProviders: [OpenCodeProvider] { viewModel.sortedProviders }
    var selectableAgents: [OpenCodeAgent] { viewModel.selectableAgents }
    var newSessionDefaults: NewSessionDefaults { viewModel.newSessionDefaults }
    var errorMessage: String? { viewModel.errorMessage }
    var showsRecentSessionsInProjectList: Bool { viewModel.showsRecentSessionsInProjectList }
    var pluginStore: PluginStore { viewModel.pluginStore }

    var isShowingConfigurationsSheet: Bool {
        get { viewModel.isShowingConfigurationsSheet }
        set { viewModel.isShowingConfigurationsSheet = newValue }
    }

    func present() { viewModel.presentConfigurationsSheet() }
    func dismiss() { viewModel.isShowingConfigurationsSheet = false }
    func loadProvidersForConfiguration() async { await viewModel.loadProvidersForConfiguration() }
    func loadProvidersForConfigurationIfNeeded() async { await viewModel.loadProvidersForConfiguration(ifNeeded: true) }
    func loadPluginsForConfiguration() async {
        let directory = viewModel.effectiveSelectedDirectory
        let scope = "\(viewModel.config.recentServerID)|\(directory ?? "global")"
        viewModel.pluginStore.beginLoading(scope: scope)
        defer { viewModel.pluginStore.finishLoading(scope: scope) }

        do {
            let config = try await viewModel.client.resolvedConfig(directory: directory)
            viewModel.pluginStore.apply(config, scope: scope)
        } catch {
            viewModel.pluginStore.apply(error: error, scope: scope)
        }
    }
    func disconnectProvider(_ provider: OpenCodeProvider) async { _ = await viewModel.disconnectProvider(provider) }
    func canDisconnectProvider(_ provider: OpenCodeProvider) -> Bool { viewModel.canDisconnectProvider(provider) }
    func providerSourceTitle(_ provider: OpenCodeProvider) -> String { viewModel.providerSourceTitle(provider) }
    func models(for provider: OpenCodeProvider) -> [OpenCodeModel] { viewModel.models(for: provider) }
    func authMethods(for provider: OpenCodeProvider) -> [OpenCodeProviderAuthMethod] { viewModel.authMethods(for: provider) }
    func modelEntries(for provider: OpenCodeProvider) -> [ModelConfigurationModelEntry] { viewModel.modelEntries(for: provider) }
    func modelVisibilityStates(for provider: OpenCodeProvider) -> [String: Bool] { viewModel.modelVisibilityStates(for: provider) }
    func setModelVisibility(_ reference: OpenCodeModelReference, isVisible: Bool) {
        viewModel.setModelVisibility(reference, isVisible: isVisible)
    }
    func authorizeProviderOAuth(providerID: String, methodIndex: Int, inputs: [String: String]) async -> OpenCodeProviderAuthAuthorization? {
        await viewModel.authorizeProviderOAuth(providerID: providerID, methodIndex: methodIndex, inputs: inputs)
    }
    func completeProviderOAuth(providerID: String, methodIndex: Int, code: String?) async -> Bool {
        await viewModel.completeProviderOAuth(providerID: providerID, methodIndex: methodIndex, code: code)
    }
    func connectProviderWithAPIKey(providerID: String, key: String) async -> Bool {
        await viewModel.connectProviderWithAPIKey(providerID: providerID, key: key)
    }
    func saveCustomProvider(_ draft: OpenCodeCustomProviderDraft) async -> Bool { await viewModel.saveCustomProvider(draft) }
    func setNewSessionDefaultAgent(_ name: String?) { viewModel.setNewSessionDefaultAgent(name) }
    func setNewSessionDefaultModel(_ reference: OpenCodeModelReference?) { viewModel.setNewSessionDefaultModel(reference) }
    func setNewSessionDefaultReasoning(_ variant: String?) { viewModel.setNewSessionDefaultReasoning(variant) }
    func setVoiceModeModel(_ reference: OpenCodeModelReference?) { viewModel.setVoiceModeModel(reference) }
    func newSessionDefaultModelReference() -> OpenCodeModelReference? { viewModel.newSessionDefaultModelReference() }
    func voiceModeModelReference() -> OpenCodeModelReference? { viewModel.voiceModeModelReference() }
    func formattedVariantTitle(_ variant: String) -> String { viewModel.formattedVariantTitle(variant) }
    func setShowsRecentSessionsInProjectList(_ shows: Bool) { viewModel.setShowsRecentSessionsInProjectList(shows) }
    func loadRecentProjectSessionsAcrossProjects() async { await viewModel.loadRecentProjectSessionsAcrossProjects() }
}
