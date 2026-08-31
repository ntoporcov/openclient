import Combine
import Foundation

@MainActor
final class ModelConfigurationStore: ObservableObject {
    static let preferredFallbackModelReference = OpenCodeModelReference(providerID: "opencode", modelID: "minimax-m2.5-free")
    static let popularProviderIDs = ["opencode", "opencode-go", "anthropic", "github-copilot", "openai", "google", "openrouter", "vercel"]
    static let visibleModelLimitPerProvider = 80

    private static let visibilityDefaultsKey = "opencode.modelVisibility.v1"

    @Published var availableAgents: [OpenCodeAgent]
    @Published var allProviders: [OpenCodeProvider] {
        didSet { invalidateModelCaches() }
    }
    @Published var availableProviders: [OpenCodeProvider]
    @Published var connectedProviderIDs: Set<String>
    @Published var providerAuthMethodsByProviderID: [String: [OpenCodeProviderAuthMethod]]
    @Published var isLoadingProviders: Bool
    @Published var providerErrorMessage: String?
    @Published var connectingProviderID: String?
    @Published var disconnectingProviderID: String?
    @Published private(set) var modelVisibilityPreferences: [String: ModelVisibilityPreference]
    @Published var defaultModelsByProviderID: [String: String]
    @Published var selectedAgentNamesBySessionID: [String: String]
    @Published var selectedModelsBySessionID: [String: OpenCodeModelReference]
    @Published var selectedVariantsBySessionID: [String: String]
    @Published var newSessionDefaults: NewSessionDefaults
    private var latestModelReferencesCache: Set<OpenCodeModelReference>?
    private var visibleModelsCache: [String: [OpenCodeModel]] = [:]
    private var loadedProviderScope: String?
    private let internetReleaseDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
    private let fullReleaseDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()

    init(
        availableAgents: [OpenCodeAgent] = [],
        allProviders: [OpenCodeProvider] = [],
        availableProviders: [OpenCodeProvider] = [],
        connectedProviderIDs: Set<String> = [],
        providerAuthMethodsByProviderID: [String: [OpenCodeProviderAuthMethod]] = [:],
        isLoadingProviders: Bool = false,
        providerErrorMessage: String? = nil,
        connectingProviderID: String? = nil,
        disconnectingProviderID: String? = nil,
        defaultModelsByProviderID: [String: String] = [:],
        selectedAgentNamesBySessionID: [String: String] = [:],
        selectedModelsBySessionID: [String: OpenCodeModelReference] = [:],
        selectedVariantsBySessionID: [String: String] = [:],
        newSessionDefaults: NewSessionDefaults = NewSessionDefaults()
    ) {
        self.availableAgents = availableAgents
        self.allProviders = allProviders
        self.availableProviders = availableProviders
        self.connectedProviderIDs = connectedProviderIDs
        self.providerAuthMethodsByProviderID = providerAuthMethodsByProviderID
        self.isLoadingProviders = isLoadingProviders
        self.providerErrorMessage = providerErrorMessage
        self.connectingProviderID = connectingProviderID
        self.disconnectingProviderID = disconnectingProviderID
        self.modelVisibilityPreferences = Self.loadModelVisibilityPreferences()
        self.defaultModelsByProviderID = defaultModelsByProviderID
        self.selectedAgentNamesBySessionID = selectedAgentNamesBySessionID
        self.selectedModelsBySessionID = selectedModelsBySessionID
        self.selectedVariantsBySessionID = selectedVariantsBySessionID
        self.newSessionDefaults = newSessionDefaults
    }

    func reset() {
        availableAgents = []
        allProviders = []
        availableProviders = []
        connectedProviderIDs = []
        providerAuthMethodsByProviderID = [:]
        isLoadingProviders = false
        providerErrorMessage = nil
        connectingProviderID = nil
        disconnectingProviderID = nil
        defaultModelsByProviderID = [:]
        selectedAgentNamesBySessionID = [:]
        selectedModelsBySessionID = [:]
        selectedVariantsBySessionID = [:]
        newSessionDefaults = NewSessionDefaults()
        loadedProviderScope = nil
    }

    var selectableAgents: [OpenCodeAgent] {
        availableAgents
            .filter { ($0.hidden ?? false) == false && $0.mode != "subagent" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var mentionableAgents: [OpenCodeAgent] {
        availableAgents
            .filter { ($0.hidden ?? false) == false && $0.mode != "primary" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var sortedProviders: [OpenCodeProvider] {
        sortedProviderList(availableProviders)
    }

    var sortedConnectedProviders: [OpenCodeProvider] {
        sortedProviderList(availableProviders)
    }

    var sortedAllProviders: [OpenCodeProvider] {
        sortedProviderList(allProviders)
    }

    var addableProviders: [OpenCodeProvider] {
        sortedProviderList(allProviders)
    }

    var popularAddableProviders: [OpenCodeProvider] {
        addableProviders.filter { Self.popularProviderIDs.contains($0.id) }
    }

    var validModelReferences: Set<OpenCodeModelReference> {
        Set(availableProviders.flatMap { provider in
            provider.models.values.map { OpenCodeModelReference(providerID: provider.id, modelID: $0.id) }
        })
    }

    func applyComposerOptions(agents: [OpenCodeAgent], providers: [OpenCodeProvider], defaults: [String: String]) {
        availableAgents = agents
        allProviders = normalizeProviders(providers)
        availableProviders = allProviders
        connectedProviderIDs = Set(allProviders.map(\.id))
        defaultModelsByProviderID = defaults
    }

    func applyProviderState(_ state: OpenCodeProviderListResponse) {
        allProviders = normalizeProviders(state.all)
        connectedProviderIDs = Set(state.connected)
        availableProviders = sortedProviderList(allProviders.filter { connectedProviderIDs.contains($0.id) })
        defaultModelsByProviderID = state.default
    }

    func removeConnectedProvider(id: String) {
        connectedProviderIDs.remove(id)
        availableProviders = sortedProviderList(availableProviders.filter { $0.id != id })
        if defaultModelsByProviderID[id] != nil {
            defaultModelsByProviderID.removeValue(forKey: id)
        }
    }

    func applyProviderAuthMethods(_ methods: [String: [OpenCodeProviderAuthMethod]]) {
        providerAuthMethodsByProviderID = methods
    }

    func shouldLoadProviders(for scope: String) -> Bool {
        loadedProviderScope != scope || allProviders.isEmpty
    }

    func markProvidersLoaded(for scope: String) {
        loadedProviderScope = scope
    }

    func clearComposerOptions() {
        availableAgents = []
        allProviders = []
        availableProviders = []
        connectedProviderIDs = []
        providerAuthMethodsByProviderID = [:]
        defaultModelsByProviderID = [:]
    }

    func model(for reference: OpenCodeModelReference?) -> OpenCodeModel? {
        guard let reference else { return nil }
        return allProviders.first(where: { $0.id == reference.providerID })?.models[reference.modelID]
            ?? availableProviders.first(where: { $0.id == reference.providerID })?.models[reference.modelID]
    }

    func provider(id: String) -> OpenCodeProvider? {
        allProviders.first { $0.id == id } ?? availableProviders.first { $0.id == id }
    }

    func sourceTitle(for provider: OpenCodeProvider) -> String {
        switch provider.source {
        case "env": return String(localized: "Environment")
        case "api": return String(localized: "API Key")
        case "config": return String(localized: "Config")
        case "custom": return String(localized: "Custom")
        default: return connectedProviderIDs.contains(provider.id) ? String(localized: "Connected") : String(localized: "Available")
        }
    }

    func canDisconnect(_ provider: OpenCodeProvider) -> Bool {
        provider.source != "env"
    }

    func isConfigCustomProvider(_ provider: OpenCodeProvider) -> Bool {
        provider.source == "custom"
    }

    func models(for provider: OpenCodeProvider) -> [OpenCodeModel] {
        provider.models.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func modelEntries(for provider: OpenCodeProvider) -> [ModelConfigurationModelEntry] {
        provider.models.map { key, model in
            ModelConfigurationModelEntry(
                reference: OpenCodeModelReference(providerID: provider.id, modelID: key),
                model: model
            )
        }
        .sorted { lhs, rhs in
            lhs.model.name.localizedCaseInsensitiveCompare(rhs.model.name) == .orderedAscending
        }
    }

    func modelVisibilityStates(for provider: OpenCodeProvider) -> [String: Bool] {
        let latestReferences = latestModelReferences
        return Dictionary(uniqueKeysWithValues: modelEntries(for: provider).map { entry in
            (entry.id, isModelVisible(entry.reference, latestReferences: latestReferences))
        })
    }

    func visibleModels(for provider: OpenCodeProvider) -> [OpenCodeModel] {
        if let cached = visibleModelsCache[provider.id] {
            return cached
        }

        let latestReferences = latestModelReferences
        var result: [OpenCodeModel] = []
        for entry in modelEntries(for: provider) where isModelVisible(entry.reference, latestReferences: latestReferences) {
            result.append(entry.model)
            if result.count >= Self.visibleModelLimitPerProvider {
                break
            }
        }
        visibleModelsCache[provider.id] = result
        return result
    }

    func isModelVisible(_ reference: OpenCodeModelReference) -> Bool {
        isModelVisible(reference, latestReferences: latestModelReferences)
    }

    private func isModelVisible(_ reference: OpenCodeModelReference, latestReferences: Set<OpenCodeModelReference>) -> Bool {
        if let state = modelVisibilityPreferences[modelVisibilityKey(reference)]?.visibility {
            return state == .show
        }
        guard let model = model(for: reference) else { return false }
        if model.name.contains("(latest)") { return true }
        guard let releaseDate = parsedReleaseDate(model.releaseDate) else { return true }
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        return latestReferences.contains(reference) || releaseDate > cutoff
    }

    func setModelVisibility(_ reference: OpenCodeModelReference, isVisible: Bool) {
        modelVisibilityPreferences[modelVisibilityKey(reference)] = ModelVisibilityPreference(
            providerID: reference.providerID,
            modelID: reference.modelID,
            visibility: isVisible ? .show : .hide
        )
        visibleModelsCache.removeAll()
        persistModelVisibilityPreferences()
    }

    func isProviderFullyVisible(_ provider: OpenCodeProvider) -> Bool {
        let providerModels = models(for: provider)
        let latestReferences = latestModelReferences
        return !providerModels.isEmpty && providerModels.allSatisfy { model in
            isModelVisible(OpenCodeModelReference(providerID: provider.id, modelID: model.id), latestReferences: latestReferences)
        }
    }

    func setProviderVisibility(_ provider: OpenCodeProvider, isVisible: Bool) {
        for model in models(for: provider) {
            setModelVisibility(OpenCodeModelReference(providerID: provider.id, modelID: model.id), isVisible: isVisible)
        }
    }

    func newSessionDefaultModelReference() -> OpenCodeModelReference? {
        guard let providerID = newSessionDefaults.providerID, let modelID = newSessionDefaults.modelID else { return nil }
        let reference = OpenCodeModelReference(providerID: providerID, modelID: modelID)
        return validModelReferences.contains(reference) ? reference : nil
    }

    func voiceModeModelReference() -> OpenCodeModelReference? {
        guard let providerID = newSessionDefaults.voiceModeProviderID,
              let modelID = newSessionDefaults.voiceModeModelID else { return nil }
        let reference = OpenCodeModelReference(providerID: providerID, modelID: modelID)
        return validModelReferences.contains(reference) ? reference : nil
    }

    func defaultModelReference() -> OpenCodeModelReference? {
        for provider in sortedProviders {
            guard let defaultModelID = defaultModelsByProviderID[provider.id], provider.models[defaultModelID] != nil else { continue }
            return OpenCodeModelReference(providerID: provider.id, modelID: defaultModelID)
        }
        if model(for: Self.preferredFallbackModelReference) != nil { return Self.preferredFallbackModelReference }
        guard let provider = sortedProviders.first,
              let model = provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first else {
            return nil
        }
        return OpenCodeModelReference(providerID: provider.id, modelID: model.id)
    }

    var configurationEffectiveModelReference: OpenCodeModelReference? { newSessionDefaultModelReference() ?? defaultModelReference() }
    var configurationReasoningVariants: [String] { reasoningVariants(for: configurationEffectiveModelReference) }

    var configurationModelTitle: String {
        guard let reference = newSessionDefaultModelReference(), let model = model(for: reference) else { return String(localized: "System Default") }
        return model.name
    }

    var configurationVoiceModeModelTitle: String {
        guard let reference = voiceModeModelReference(), let model = model(for: reference) else {
            return String(localized: "Use New Session Default")
        }
        return model.name
    }

    var configurationAgentTitle: String {
        guard let name = newSessionDefaults.agentName, selectableAgents.contains(where: { $0.name == name }) else { return String(localized: "System Default") }
        return name.capitalized
    }

    var configurationReasoningTitle: String {
        guard let variant = newSessionDefaults.reasoningVariant, configurationReasoningVariants.contains(variant) else { return String(localized: "System Default") }
        return formattedVariantTitle(variant)
    }

    func setNewSessionDefaultAgent(_ name: String?) { newSessionDefaults.agentName = name }

    func setNewSessionDefaultModel(_ reference: OpenCodeModelReference?) {
        newSessionDefaults.providerID = reference?.providerID
        newSessionDefaults.modelID = reference?.modelID
        if let variant = newSessionDefaults.reasoningVariant, !reasoningVariants(for: configurationEffectiveModelReference).contains(variant) {
            newSessionDefaults.reasoningVariant = nil
        }
    }

    func setVoiceModeModel(_ reference: OpenCodeModelReference?) {
        newSessionDefaults.voiceModeProviderID = reference?.providerID
        newSessionDefaults.voiceModeModelID = reference?.modelID
    }

    func setNewSessionDefaultReasoning(_ variant: String?) { newSessionDefaults.reasoningVariant = variant }
    func selectedAgentName(for sessionID: String) -> String? { selectedAgentNamesBySessionID[sessionID] }
    func selectedModelReference(for sessionID: String) -> OpenCodeModelReference? { selectedModelsBySessionID[sessionID] }
    func selectedModel(for sessionID: String) -> OpenCodeModel? { model(for: selectedModelReference(for: sessionID)) }
    func effectiveAgentName(for sessionID: String) -> String? { selectedAgentName(for: sessionID) ?? selectableAgents.first?.name }
    func effectiveModelReference(for sessionID: String) -> OpenCodeModelReference? { selectedModelReference(for: sessionID) ?? defaultModelReference() }
    func effectiveModel(for sessionID: String) -> OpenCodeModel? { model(for: effectiveModelReference(for: sessionID)) }

    func reasoningVariants(forSessionID sessionID: String) -> [String] {
        guard let model = effectiveModel(for: sessionID), model.capabilities.reasoning else { return [] }
        return (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] {
        guard let model = model(for: reference), model.capabilities.reasoning else { return [] }
        return (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func selectedVariant(for sessionID: String) -> String? { selectedVariantsBySessionID[sessionID] }
    func selectAgent(named name: String?, forSessionID sessionID: String) { selectedAgentNamesBySessionID[sessionID] = name }

    func selectModel(_ reference: OpenCodeModelReference?, forSessionID sessionID: String) {
        guard let reference else {
            selectedModelsBySessionID[sessionID] = nil
            selectedVariantsBySessionID[sessionID] = nil
            return
        }
        selectedModelsBySessionID[sessionID] = reference
        let availableVariants = reasoningVariants(forSessionID: sessionID)
        if let selectedVariant = selectedVariantsBySessionID[sessionID], !availableVariants.contains(selectedVariant) {
            selectedVariantsBySessionID[sessionID] = nil
        }
    }

    func selectVariant(_ variant: String?, forSessionID sessionID: String) { selectedVariantsBySessionID[sessionID] = variant }

    func sanitizeNewSessionDefaults() {
        var sanitized = newSessionDefaults
        if let name = sanitized.agentName, !selectableAgents.contains(where: { $0.name == name }) { sanitized.agentName = nil }
        if let reference = newSessionDefaultModelReference() {
            sanitized.providerID = reference.providerID
            sanitized.modelID = reference.modelID
        } else {
            sanitized.providerID = nil
            sanitized.modelID = nil
        }
        if let variant = sanitized.reasoningVariant, !configurationReasoningVariants.contains(variant) { sanitized.reasoningVariant = nil }
        if let reference = voiceModeModelReference() {
            sanitized.voiceModeProviderID = reference.providerID
            sanitized.voiceModeModelID = reference.modelID
        } else {
            sanitized.voiceModeProviderID = nil
            sanitized.voiceModeModelID = nil
        }
        if sanitized != newSessionDefaults {
            newSessionDefaults = sanitized
        }
    }

    func sanitizeComposerSelections(validSessionIDs: Set<String>) {
        let validAgentNames = Set(selectableAgents.map(\.name))
        selectedAgentNamesBySessionID = selectedAgentNamesBySessionID.filter { validAgentNames.contains($0.value) }
        selectedModelsBySessionID = selectedModelsBySessionID.filter { validModelReferences.contains($0.value) }
        selectedVariantsBySessionID = selectedVariantsBySessionID.filter { sessionID, variant in
            validSessionIDs.contains(sessionID) && reasoningVariants(forSessionID: sessionID).contains(variant)
        }
        sanitizeNewSessionDefaults()
    }

    func seedSelectionsForNewSession(sessionID: String) {
        if selectedAgentNamesBySessionID[sessionID] == nil, let defaultAgentName = newSessionDefaults.agentName, selectableAgents.contains(where: { $0.name == defaultAgentName }) {
            selectedAgentNamesBySessionID[sessionID] = defaultAgentName
        }
        if selectedModelsBySessionID[sessionID] == nil, let defaultModel = newSessionDefaultModelReference() {
            selectedModelsBySessionID[sessionID] = defaultModel
        }
        if selectedVariantsBySessionID[sessionID] == nil, let defaultVariant = newSessionDefaults.reasoningVariant, reasoningVariants(forSessionID: sessionID).contains(defaultVariant) {
            selectedVariantsBySessionID[sessionID] = defaultVariant
        }
    }

    func seedSelectionsForVoiceSession(sessionID: String) {
        seedSelectionsForNewSession(sessionID: sessionID)
        if let reference = voiceModeModelReference() {
            selectModel(reference, forSessionID: sessionID)
        }
    }

    func syncSelections(forSessionID sessionID: String, agent: String?, model: OpenCodeMessageModelReference?) -> Bool {
        let nextAgent = agent.flatMap { candidate in
            selectableAgents.contains(where: { $0.name == candidate }) ? candidate : nil
        }
        if selectedAgentNamesBySessionID[sessionID] != nextAgent {
            selectedAgentNamesBySessionID[sessionID] = nextAgent
        }
        guard let model else {
            if selectedModelsBySessionID[sessionID] != nil {
                selectedModelsBySessionID[sessionID] = nil
            }
            if selectedVariantsBySessionID[sessionID] != nil {
                selectedVariantsBySessionID[sessionID] = nil
            }
            return false
        }
        let reference = OpenCodeModelReference(providerID: model.providerID, modelID: model.modelID)
        let nextReference = validModelReferences.contains(reference) ? reference : nil
        if selectedModelsBySessionID[sessionID] != nextReference {
            selectedModelsBySessionID[sessionID] = nextReference
        }
        let nextVariant = model.variant.flatMap { variant in
            reasoningVariants(forSessionID: sessionID).contains(variant) ? variant : nil
        }
        if selectedVariantsBySessionID[sessionID] != nextVariant {
            selectedVariantsBySessionID[sessionID] = nextVariant
        }
        return true
    }

    func formattedVariantTitle(_ variant: String) -> String { variant.replacingOccurrences(of: "_", with: " ").capitalized }

    private var latestModelReferences: Set<OpenCodeModelReference> {
        if let latestModelReferencesCache {
            return latestModelReferencesCache
        }

        var newestByProviderFamily: [String: (reference: OpenCodeModelReference, date: Date)] = [:]
        let cutoff = Calendar.current.date(byAdding: .month, value: -6, to: Date()) ?? .distantPast
        for provider in allProviders {
            for model in provider.models.values {
                guard let date = parsedReleaseDate(model.releaseDate), date > cutoff else { continue }
                let key = "\(provider.id):\(model.family ?? model.name)"
                let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                if let current = newestByProviderFamily[key], current.date >= date { continue }
                newestByProviderFamily[key] = (reference, date)
            }
        }
        let references = Set(newestByProviderFamily.values.map(\.reference))
        latestModelReferencesCache = references
        return references
    }

    private func invalidateModelCaches() {
        latestModelReferencesCache = nil
        visibleModelsCache.removeAll()
    }

    private func sortedProviderList(_ providers: [OpenCodeProvider]) -> [OpenCodeProvider] {
        providers.sorted { lhs, rhs in
            let lhsRank = Self.popularProviderIDs.firstIndex(of: lhs.id)
            let rhsRank = Self.popularProviderIDs.firstIndex(of: rhs.id)
            if let lhsRank, let rhsRank { return lhsRank < rhsRank }
            if lhsRank != nil { return true }
            if rhsRank != nil { return false }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    private func normalizeProviders(_ providers: [OpenCodeProvider]) -> [OpenCodeProvider] {
        providers.map { provider in
            OpenCodeProvider(
                id: provider.id,
                name: provider.name,
                models: provider.models.filter { $0.value.status != "deprecated" },
                source: provider.source,
                env: provider.env,
                key: provider.key,
                options: provider.options
            )
        }
    }

    private func modelVisibilityKey(_ reference: OpenCodeModelReference) -> String { "\(reference.providerID):\(reference.modelID)" }

    private func parsedReleaseDate(_ value: String?) -> Date? {
        guard let value else { return nil }
        return internetReleaseDateFormatter.date(from: value)
            ?? fullReleaseDateFormatter.date(from: value)
    }

    private static func loadModelVisibilityPreferences() -> [String: ModelVisibilityPreference] {
        guard let data = UserDefaults.standard.data(forKey: visibilityDefaultsKey), let values = try? JSONDecoder().decode([ModelVisibilityPreference].self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: values.map { ("\($0.providerID):\($0.modelID)", $0) })
    }

    private func persistModelVisibilityPreferences() {
        guard let data = try? JSONEncoder().encode(Array(modelVisibilityPreferences.values)) else { return }
        UserDefaults.standard.set(data, forKey: Self.visibilityDefaultsKey)
    }
}

@MainActor
final class PluginStore: ObservableObject {
    @Published private(set) var plugins: [OpenCodeConfiguredPlugin]
    @Published private(set) var isLoading: Bool
    @Published private(set) var isReady: Bool
    @Published private(set) var errorMessage: String?

    private var activeScope: String?

    init(
        plugins: [OpenCodeConfiguredPlugin] = [],
        isLoading: Bool = false,
        isReady: Bool = false,
        errorMessage: String? = nil
    ) {
        self.plugins = plugins
        self.isLoading = isLoading
        self.isReady = isReady
        self.errorMessage = errorMessage
    }

    func beginLoading(scope: String) {
        if activeScope != scope {
            plugins = []
            isReady = false
        }
        activeScope = scope
        isLoading = true
        errorMessage = nil
    }

    func apply(_ config: OpenCodeResolvedConfig, scope: String) {
        guard activeScope == scope else { return }
        plugins = config.plugins
        isReady = true
        errorMessage = nil
    }

    func apply(error: Error, scope: String) {
        guard activeScope == scope else { return }
        plugins = []
        isReady = true
        errorMessage = error.localizedDescription
    }

    func finishLoading(scope: String) {
        guard activeScope == scope else { return }
        isLoading = false
    }

    func reset() {
        plugins = []
        isLoading = false
        isReady = false
        errorMessage = nil
        activeScope = nil
    }
}

struct ModelVisibilityPreference: Codable, Hashable, Sendable {
    enum Visibility: String, Codable, Hashable, Sendable {
        case show
        case hide
    }

    let providerID: String
    let modelID: String
    let visibility: Visibility
}

struct ModelConfigurationModelEntry: Identifiable, Hashable, Sendable {
    let reference: OpenCodeModelReference
    let model: OpenCodeModel

    var id: String { "\(reference.providerID):\(reference.modelID)" }
}
