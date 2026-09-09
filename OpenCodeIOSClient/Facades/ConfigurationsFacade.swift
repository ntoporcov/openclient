import Combine
import Foundation

@MainActor
final class ConfigurationsFacade: ObservableObject {
    private unowned let viewModel: AppViewModel
    private var observations: Set<AnyCancellable> = []
    let v2ProviderStore = V2ProviderStore()
    @Published private(set) var configurationRevision = UUID()
    @Published private(set) var isProviderCatalogReady = false
    private var pluginRequestID = UUID()
    private var providerRequestID = UUID()
    private var providerReadTask: Task<Void, Never>?
    private var requestedProviderCatalog = false
    private var requestedPlugins = false
    private var pendingEventRefresh: Refresh = []
    private var eventRefreshTask: Task<Void, Never>?
    private var eventRefreshContext: V2ConfigurationContext?
    private var eventRefreshID = UUID()

    private struct Refresh: OptionSet {
        let rawValue: Int
        static let providers = Self(rawValue: 1)
        static let integrations = Self(rawValue: 2)
        static let plugins = Self(rawValue: 4)
    }

    var isV2Connection: Bool { viewModel.connectionStore.apiProfile == .v2 }
    var supportsProviderManagement: Bool { viewModel.compatibilityClient(for: .providerConfiguration) != nil }
    var v2Coordinator: V2ConfigurationCoordinator { .init(store: v2ProviderStore) }

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

        Publishers.MergeMany([
            viewModel.$config.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.connectionStore.$apiProfile.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.connectionStore.$isConnected.removeDuplicates().dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] _ in
            guard let self else { return }
            self.configurationRevision = UUID()
            self.pluginRequestID = UUID()
            self.providerRequestID = UUID()
            if self.providerReadTask != nil { self.viewModel.modelConfigurationStore.isLoadingProviders = false }
            self.providerReadTask?.cancel()
            self.providerReadTask = nil
            self.requestedProviderCatalog = false
            self.isProviderCatalogReady = false
            self.requestedPlugins = false
            self.cancelEventRefresh()
            self.v2ProviderStore.reset()
            self.viewModel.pluginStore.reset()
        }
        .store(in: &observations)
    }

    var modelConfigurationStore: ModelConfigurationStore { viewModel.modelConfigurationStore }
    var configurationAgentTitle: String { viewModel.configurationAgentTitle }
    var configurationModelTitle: String { viewModel.configurationModelTitle }
    var configurationReasoningTitle: String { viewModel.configurationReasoningTitle }
    var configurationVoiceModeModelTitle: String { viewModel.modelConfigurationStore.configurationVoiceModeModelTitle }
    var configurationReasoningVariants: [String] { viewModel.configurationReasoningVariants }
    var isLoadingProviders: Bool { viewModel.isLoadingProviders }
    var providerErrorMessage: String? { viewModel.providerErrorMessage }
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
    func loadProvidersForConfiguration() async { await loadProviderCatalog(ifNeeded: false) }
    func loadProvidersForConfigurationIfNeeded() async { await loadProviderCatalog(ifNeeded: true) }

    private func loadProviderCatalog(ifNeeded: Bool) async {
        guard !Task.isCancelled else { return }
        requestedProviderCatalog = true
        guard isV2Connection, supportsProviderManagement else {
            await viewModel.loadProvidersForConfiguration(ifNeeded: ifNeeded)
            return
        }
        guard let context = v2Context() else { return }
        let requestID = UUID()
        providerRequestID = requestID
        providerReadTask?.cancel()
        viewModel.modelConfigurationStore.isLoadingProviders = true
        defer {
            if providerRequestID == requestID, context.isCurrent() {
                viewModel.modelConfigurationStore.isLoadingProviders = false
                providerReadTask = nil
            }
        }
        // Preserve the existing composer/default/session hydration semantics, but cancel obsolete reads.
        let task = Task { [weak self] in
            guard !Task.isCancelled, context.isCurrent(), let self else { return }
            await self.viewModel.loadProvidersForConfiguration(ifNeeded: ifNeeded)
        }
        providerReadTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        guard !Task.isCancelled, !task.isCancelled, providerRequestID == requestID, context.isCurrent() else { return }
        if viewModel.providerErrorMessage == nil { isProviderCatalogReady = true }
    }

    func loadV2Integrations() async {
        guard let context = v2Context() else { return }
        await v2Coordinator.load(context)
    }

    private func v2Context() -> V2ConfigurationContext? {
        guard !Task.isCancelled, isV2Connection, viewModel.isConnected,
              let client = viewModel.compatibilityClient(for: .providerConfiguration) else { return nil }
        let directory = viewModel.effectiveSelectedDirectory
        let revision = configurationRevision
        let isCurrent: @MainActor () -> Bool = { [weak self, weak viewModel] in
            guard let self, let viewModel else { return false }
            return self.configurationRevision == revision && viewModel.connectionStore.apiProfile == .v2 && viewModel.isConnected
                && viewModel.config == client.config && viewModel.compatibilityClient(for: .providerConfiguration)?.session === client.session
                && viewModel.effectiveSelectedDirectory == directory
        }
        return .init(client: client, directory: directory, isCurrent: isCurrent, refreshModels: { [weak self] in
            guard isCurrent(), let self else { return }
            await self.loadProvidersForConfiguration()
        })
    }

    /// Handles location/global inventory events before the caller's session-ID guard.
    @discardableResult
    func consumeV2(_ event: OpenCodeV2ManagedEvent) -> Bool {
        guard isV2Connection, let data = event.data.objectValue else { return false }
        let changes: Refresh
        switch event.type {
        case "catalog.updated", "agent.updated", "command.updated":
            changes = [.providers]
        case "integration.updated", "credential.updated":
            changes = [.providers, .integrations]
        case "integration.connection.updated": // next-17155
            guard data["integrationID"]?.v2ConfigurationString != nil else { return false }
            changes = [.providers, .integrations]
        case "credential.switched": // pinned 41cb354c
            guard data["integrationID"]?.v2ConfigurationString != nil,
                  data["credentialID"] == .null || data["credentialID"]?.v2ConfigurationString != nil else { return false }
            changes = [.providers, .integrations]
        case "plugin.added": // next-17155
            guard data["id"]?.v2ConfigurationString != nil else { return false }
            changes = [.providers, .integrations, .plugins]
        case "plugin.updated":
            changes = [.providers, .integrations, .plugins]
        default: return false
        }
        // Unscoped events invalidate the current location; another directory does not.
        if let directory = viewModel.effectiveSelectedDirectory, let location = event.location,
           location.directory != directory { return true }
        queueEventRefresh(changes.intersection(relevantRefresh))
        return true
    }

    func refreshAfterEventReconnect() async {
        guard !Task.isCancelled else { return }
        queueEventRefresh(relevantRefresh)
        await eventRefreshTask?.value
    }

    private var relevantRefresh: Refresh {
        var refresh: Refresh = []
        if requestedProviderCatalog || isShowingConfigurationsSheet || !modelConfigurationStore.allProviders.isEmpty || isLoadingProviders {
            refresh.insert(.providers)
        }
        if v2ProviderStore.context != nil || v2ProviderStore.isLoading { refresh.insert(.integrations) }
        if requestedPlugins || pluginStore.isReady || pluginStore.isLoading { refresh.insert(.plugins) }
        return refresh
    }

    private func queueEventRefresh(_ refresh: Refresh) {
        guard !refresh.isEmpty, let context = v2Context() else { return }
        if let previous = eventRefreshContext, !previous.isCurrent() { cancelEventRefresh() }
        pendingEventRefresh.formUnion(refresh)
        // Fence reads immediately, not after the debounce. Authentication generation is untouched.
        if refresh.contains(.integrations) { v2ProviderStore.discoveryRequestID = UUID() }
        if refresh.contains(.plugins) { pluginRequestID = UUID() }
        if refresh.contains(.providers) {
            providerRequestID = UUID()
            providerReadTask?.cancel()
        }
        guard eventRefreshTask == nil else { return }
        let requestID = UUID()
        eventRefreshID = requestID
        eventRefreshContext = context
        eventRefreshTask = Task { [weak self] in
            defer {
                if let self, self.eventRefreshID == requestID {
                    self.eventRefreshTask = nil
                    self.eventRefreshContext = nil
                    self.pendingEventRefresh = []
                }
            }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(150)) } catch { return }
                guard let self, self.eventRefreshID == requestID, context.isCurrent() else { return }
                let refresh = self.pendingEventRefresh
                self.pendingEventRefresh = []
                if refresh.contains(.integrations) { await self.v2Coordinator.load(context) }
                guard !Task.isCancelled, self.eventRefreshID == requestID, context.isCurrent() else { return }
                if refresh.contains(.providers) { await context.refreshModels() }
                guard !Task.isCancelled, self.eventRefreshID == requestID, context.isCurrent() else { return }
                if refresh.contains(.plugins) { await self.loadPluginsForConfiguration() }
                guard !Task.isCancelled, self.eventRefreshID == requestID, context.isCurrent(), !self.pendingEventRefresh.isEmpty else { return }
            }
        }
    }

    private func cancelEventRefresh() {
        eventRefreshID = UUID()
        eventRefreshTask?.cancel()
        eventRefreshTask = nil
        eventRefreshContext = nil
        pendingEventRefresh = []
    }

    func loadPluginsForConfiguration() async {
        guard !Task.isCancelled, let client = viewModel.compatibilityClient(for: .providerConfiguration) else { return }
        guard viewModel.connectionStore.apiProfile != nil || viewModel.config.apiPreference == .legacy else { return }
        requestedPlugins = true
        let directory = viewModel.effectiveSelectedDirectory
        let profile = viewModel.connectionStore.apiProfile
        let revision = configurationRevision
        let requestID = UUID()
        pluginRequestID = requestID
        let scope = "\(viewModel.config.recentServerID)|\(profile?.rawValue ?? "legacy")|\(directory ?? "global")"
        let isCurrent = { [self] in
            pluginRequestID == requestID && configurationRevision == revision && viewModel.config == client.config
                && viewModel.compatibilityClient(for: .providerConfiguration)?.session === client.session
                && viewModel.connectionStore.apiProfile == profile && viewModel.effectiveSelectedDirectory == directory
        }
        viewModel.pluginStore.beginLoading(scope: scope)
        defer { if isCurrent() { viewModel.pluginStore.finishLoading(scope: scope) } }

        do {
            if profile == .v2 {
                let plugins = try await client.v2Plugins(directory: directory)
                guard !Task.isCancelled, isCurrent() else { return }
                viewModel.pluginStore.apply(plugins, scope: scope)
            } else {
                let config = try await client.resolvedConfig(directory: directory)
                guard !Task.isCancelled, isCurrent() else { return }
                viewModel.pluginStore.apply(config, scope: scope)
            }
        } catch {
            guard !Task.isCancelled, isCurrent() else { return }
            viewModel.pluginStore.apply(error: error, scope: scope)
        }
    }
    func disconnectProvider(_ provider: OpenCodeProvider) async { _ = await viewModel.disconnectProvider(provider) }
    func canDisconnectProvider(_ provider: OpenCodeProvider) -> Bool { viewModel.canDisconnectProvider(provider) }
    func providerSourceTitle(_ provider: OpenCodeProvider) -> String {
        isV2Connection || !supportsProviderManagement ? String(localized: "Available") : viewModel.providerSourceTitle(provider)
    }

    static func providerAuthenticationSummary(_ labels: [String]) -> String {
        let unique = Array(NSOrderedSet(array: labels)) as? [String] ?? labels
        return unique.formatted()
    }

    static func v2ProviderGroups(_ integrations: [OpenCodeV2Integration], query: String) -> (popular: [OpenCodeV2Integration], other: [OpenCodeV2Integration]) {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let providers = integrations.filter {
            query.isEmpty || $0.name.localizedCaseInsensitiveContains(query) || $0.id.localizedCaseInsensitiveContains(query)
        }
        let popularIDs = ModelConfigurationStore.popularProviderIDs
        let popular = providers.filter { popularIDs.contains($0.id) }.sorted {
            (popularIDs.firstIndex(of: $0.id) ?? .max) < (popularIDs.firstIndex(of: $1.id) ?? .max)
        }
        let other = providers.filter { !popularIDs.contains($0.id) }.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        return (popular, other)
    }

    static func v2ProviderRoute(for integration: OpenCodeV2Integration) -> V2ProviderRoute {
        // Existing connections must stay reachable, even for a single-method provider.
        if integration.connections.isEmpty, integration.methods.count == 1, let method = integration.methods.first {
            return .method(integrationID: integration.id, methodID: method.id)
        }
        return .provider(integration.id)
    }

    static func canConnectV2Provider(method: OpenCodeV2IntegrationMethod, key: String, values: [String: OpenCodeJSONValue]) -> Bool {
        if case .key = method, key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        return (try? method.answer(values: values)) != nil
    }

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

enum V2ProviderRoute: Hashable {
    case provider(String)
    case method(integrationID: String, methodID: String)
}
