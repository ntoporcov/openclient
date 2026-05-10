import Combine
import Foundation

@MainActor
final class ModelConfigurationStore: ObservableObject {
    static let preferredFallbackModelReference = OpenCodeModelReference(providerID: "opencode", modelID: "minimax-m2.5-free")

    @Published var availableAgents: [OpenCodeAgent]
    @Published var availableProviders: [OpenCodeProvider]
    @Published var defaultModelsByProviderID: [String: String]
    @Published var selectedAgentNamesBySessionID: [String: String]
    @Published var selectedModelsBySessionID: [String: OpenCodeModelReference]
    @Published var selectedVariantsBySessionID: [String: String]
    @Published var newSessionDefaults: NewSessionDefaults

    init(
        availableAgents: [OpenCodeAgent] = [],
        availableProviders: [OpenCodeProvider] = [],
        defaultModelsByProviderID: [String: String] = [:],
        selectedAgentNamesBySessionID: [String: String] = [:],
        selectedModelsBySessionID: [String: OpenCodeModelReference] = [:],
        selectedVariantsBySessionID: [String: String] = [:],
        newSessionDefaults: NewSessionDefaults = NewSessionDefaults()
    ) {
        self.availableAgents = availableAgents
        self.availableProviders = availableProviders
        self.defaultModelsByProviderID = defaultModelsByProviderID
        self.selectedAgentNamesBySessionID = selectedAgentNamesBySessionID
        self.selectedModelsBySessionID = selectedModelsBySessionID
        self.selectedVariantsBySessionID = selectedVariantsBySessionID
        self.newSessionDefaults = newSessionDefaults
    }

    func reset() {
        availableAgents = []
        availableProviders = []
        defaultModelsByProviderID = [:]
        selectedAgentNamesBySessionID = [:]
        selectedModelsBySessionID = [:]
        selectedVariantsBySessionID = [:]
        newSessionDefaults = NewSessionDefaults()
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
        availableProviders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var validModelReferences: Set<OpenCodeModelReference> {
        Set(availableProviders.flatMap { provider in
            provider.models.values.map { OpenCodeModelReference(providerID: provider.id, modelID: $0.id) }
        })
    }

    func applyComposerOptions(
        agents: [OpenCodeAgent],
        providers: [OpenCodeProvider],
        defaults: [String: String]
    ) {
        availableAgents = agents
        availableProviders = providers
        defaultModelsByProviderID = defaults
    }

    func clearComposerOptions() {
        availableAgents = []
        availableProviders = []
        defaultModelsByProviderID = [:]
    }

    func model(for reference: OpenCodeModelReference?) -> OpenCodeModel? {
        guard let reference else { return nil }
        return availableProviders.first(where: { $0.id == reference.providerID })?.models[reference.modelID]
    }

    func newSessionDefaultModelReference() -> OpenCodeModelReference? {
        guard let providerID = newSessionDefaults.providerID,
              let modelID = newSessionDefaults.modelID else {
            return nil
        }

        let reference = OpenCodeModelReference(providerID: providerID, modelID: modelID)
        return validModelReferences.contains(reference) ? reference : nil
    }

    func defaultModelReference() -> OpenCodeModelReference? {
        for provider in sortedProviders {
            guard let defaultModelID = defaultModelsByProviderID[provider.id],
                  provider.models[defaultModelID] != nil else { continue }
            return OpenCodeModelReference(providerID: provider.id, modelID: defaultModelID)
        }

        if model(for: Self.preferredFallbackModelReference) != nil {
            return Self.preferredFallbackModelReference
        }

        guard let provider = sortedProviders.first,
              let model = provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first else {
            return nil
        }
        return OpenCodeModelReference(providerID: provider.id, modelID: model.id)
    }

    var configurationEffectiveModelReference: OpenCodeModelReference? {
        newSessionDefaultModelReference() ?? defaultModelReference()
    }

    var configurationReasoningVariants: [String] {
        reasoningVariants(for: configurationEffectiveModelReference)
    }

    var configurationModelTitle: String {
        guard let reference = newSessionDefaultModelReference(),
              let model = model(for: reference) else {
            return "System Default"
        }

        return model.name
    }

    var configurationAgentTitle: String {
        guard let name = newSessionDefaults.agentName,
              selectableAgents.contains(where: { $0.name == name }) else {
            return "System Default"
        }

        return name.capitalized
    }

    var configurationReasoningTitle: String {
        guard let variant = newSessionDefaults.reasoningVariant,
              configurationReasoningVariants.contains(variant) else {
            return "System Default"
        }

        return formattedVariantTitle(variant)
    }

    func setNewSessionDefaultAgent(_ name: String?) {
        newSessionDefaults.agentName = name
    }

    func setNewSessionDefaultModel(_ reference: OpenCodeModelReference?) {
        newSessionDefaults.providerID = reference?.providerID
        newSessionDefaults.modelID = reference?.modelID

        if let variant = newSessionDefaults.reasoningVariant,
           !reasoningVariants(for: configurationEffectiveModelReference).contains(variant) {
            newSessionDefaults.reasoningVariant = nil
        }
    }

    func setNewSessionDefaultReasoning(_ variant: String?) {
        newSessionDefaults.reasoningVariant = variant
    }

    func selectedAgentName(for sessionID: String) -> String? {
        selectedAgentNamesBySessionID[sessionID]
    }

    func selectedModelReference(for sessionID: String) -> OpenCodeModelReference? {
        selectedModelsBySessionID[sessionID]
    }

    func selectedModel(for sessionID: String) -> OpenCodeModel? {
        model(for: selectedModelReference(for: sessionID))
    }

    func effectiveAgentName(for sessionID: String) -> String? {
        selectedAgentName(for: sessionID) ?? selectableAgents.first?.name
    }

    func effectiveModelReference(for sessionID: String) -> OpenCodeModelReference? {
        selectedModelReference(for: sessionID) ?? defaultModelReference()
    }

    func effectiveModel(for sessionID: String) -> OpenCodeModel? {
        model(for: effectiveModelReference(for: sessionID))
    }

    func reasoningVariants(forSessionID sessionID: String) -> [String] {
        guard let model = effectiveModel(for: sessionID), model.capabilities.reasoning else { return [] }
        return (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] {
        guard let model = model(for: reference), model.capabilities.reasoning else { return [] }
        return (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func selectedVariant(for sessionID: String) -> String? {
        selectedVariantsBySessionID[sessionID]
    }

    func selectAgent(named name: String?, forSessionID sessionID: String) {
        selectedAgentNamesBySessionID[sessionID] = name
    }

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

    func selectVariant(_ variant: String?, forSessionID sessionID: String) {
        selectedVariantsBySessionID[sessionID] = variant
    }

    func sanitizeNewSessionDefaults() {
        if let name = newSessionDefaults.agentName,
           !selectableAgents.contains(where: { $0.name == name }) {
            newSessionDefaults.agentName = nil
        }

        if let reference = newSessionDefaultModelReference() {
            newSessionDefaults.providerID = reference.providerID
            newSessionDefaults.modelID = reference.modelID
        } else {
            newSessionDefaults.providerID = nil
            newSessionDefaults.modelID = nil
        }

        if let variant = newSessionDefaults.reasoningVariant,
           !configurationReasoningVariants.contains(variant) {
            newSessionDefaults.reasoningVariant = nil
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
        if selectedAgentNamesBySessionID[sessionID] == nil,
           let defaultAgentName = newSessionDefaults.agentName,
           selectableAgents.contains(where: { $0.name == defaultAgentName }) {
            selectedAgentNamesBySessionID[sessionID] = defaultAgentName
        }

        if selectedModelsBySessionID[sessionID] == nil,
           let defaultModel = newSessionDefaultModelReference() {
            selectedModelsBySessionID[sessionID] = defaultModel
        }

        if selectedVariantsBySessionID[sessionID] == nil,
           let defaultVariant = newSessionDefaults.reasoningVariant,
           reasoningVariants(forSessionID: sessionID).contains(defaultVariant) {
            selectedVariantsBySessionID[sessionID] = defaultVariant
        }
    }

    func syncSelections(
        forSessionID sessionID: String,
        agent: String?,
        model: OpenCodeMessageModelReference?
    ) -> Bool {
        if let agent, selectableAgents.contains(where: { $0.name == agent }) {
            selectedAgentNamesBySessionID[sessionID] = agent
        } else {
            selectedAgentNamesBySessionID[sessionID] = nil
        }

        guard let model else {
            selectedModelsBySessionID[sessionID] = nil
            selectedVariantsBySessionID[sessionID] = nil
            return false
        }

        let reference = OpenCodeModelReference(providerID: model.providerID, modelID: model.modelID)
        if validModelReferences.contains(reference) {
            selectedModelsBySessionID[sessionID] = reference
        } else {
            selectedModelsBySessionID[sessionID] = nil
        }

        if let variant = model.variant,
           reasoningVariants(forSessionID: sessionID).contains(variant) {
            selectedVariantsBySessionID[sessionID] = variant
        } else {
            selectedVariantsBySessionID[sessionID] = nil
        }

        return true
    }

    func formattedVariantTitle(_ variant: String) -> String {
        variant.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
