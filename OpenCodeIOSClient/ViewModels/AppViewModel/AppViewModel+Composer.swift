import Foundation

extension AppViewModel {
    var selectableAgents: [OpenCodeAgent] {
        availableAgents
            .filter { ($0.hidden ?? false) == false && $0.mode != "subagent" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var sortedProviders: [OpenCodeProvider] {
        availableProviders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    func agentToolbarTitle(for session: OpenCodeSession) -> String {
        effectiveAgentName(for: session) ?? "Agent"
    }

    func modelToolbarTitle(for session: OpenCodeSession) -> String {
        effectiveModel(for: session)?.name ?? "Model"
    }

    func selectedAgentName(for session: OpenCodeSession) -> String? {
        selectedAgentNamesBySessionID[session.id]
    }

    func selectedModelReference(for session: OpenCodeSession) -> OpenCodeModelReference? {
        selectedModelsBySessionID[session.id]
    }

    func selectedModel(for session: OpenCodeSession) -> OpenCodeModel? {
        guard let reference = selectedModelsBySessionID[session.id] else { return nil }
        return availableProviders.first(where: { $0.id == reference.providerID })?.models[reference.modelID]
    }

    func effectiveAgentName(for session: OpenCodeSession) -> String? {
        selectedAgentName(for: session) ?? selectableAgents.first?.name
    }

    func effectiveModelReference(for session: OpenCodeSession) -> OpenCodeModelReference? {
        if let selected = selectedModelReference(for: session) {
            return selected
        }

        for provider in sortedProviders {
            guard let defaultModelID = defaultModelsByProviderID[provider.id],
                  provider.models[defaultModelID] != nil else { continue }
            return OpenCodeModelReference(providerID: provider.id, modelID: defaultModelID)
        }

        guard let provider = sortedProviders.first,
              let model = provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }).first else {
            return nil
        }
        return OpenCodeModelReference(providerID: provider.id, modelID: model.id)
    }

    func effectiveModel(for session: OpenCodeSession) -> OpenCodeModel? {
        guard let reference = effectiveModelReference(for: session) else { return nil }
        return availableProviders.first(where: { $0.id == reference.providerID })?.models[reference.modelID]
    }

    func reasoningVariants(for session: OpenCodeSession) -> [String] {
        guard let model = effectiveModel(for: session), model.capabilities.reasoning else { return [] }
        return (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func selectedVariant(for session: OpenCodeSession) -> String? {
        selectedVariantsBySessionID[session.id]
    }

    func reasoningToolbarTitle(for session: OpenCodeSession) -> String {
        if let selectedVariant = selectedVariant(for: session) {
            return formattedVariantTitle(selectedVariant)
        }
        return "Default"
    }

    func selectAgent(named name: String?, for session: OpenCodeSession) {
        guard let name else {
            selectedAgentNamesBySessionID[session.id] = nil
            return
        }
        selectedAgentNamesBySessionID[session.id] = name
    }

    func selectModel(_ reference: OpenCodeModelReference?, for session: OpenCodeSession) {
        guard let reference else {
            selectedModelsBySessionID[session.id] = nil
            selectedVariantsBySessionID[session.id] = nil
            return
        }

        selectedModelsBySessionID[session.id] = reference
        let availableVariants = reasoningVariants(for: session)
        if let selectedVariant = selectedVariantsBySessionID[session.id], !availableVariants.contains(selectedVariant) {
            selectedVariantsBySessionID[session.id] = nil
        }
    }

    func selectVariant(_ variant: String?, for session: OpenCodeSession) {
        guard let variant else {
            selectedVariantsBySessionID[session.id] = nil
            return
        }
        selectedVariantsBySessionID[session.id] = variant
    }

    func formattedVariantTitle(_ variant: String) -> String {
        variant.replacingOccurrences(of: "_", with: " ").capitalized
    }

    func loadComposerOptions() async {
        do {
            async let agents = client.listAgents(directory: effectiveSelectedDirectory)
            async let providers = client.listProviders(directory: effectiveSelectedDirectory)
            async let defaults = client.providerDefaults(directory: effectiveSelectedDirectory)
            availableAgents = try await agents
            availableProviders = try await providers
            defaultModelsByProviderID = try await defaults
            sanitizeComposerSelections()
        } catch {
            availableAgents = []
            availableProviders = []
            defaultModelsByProviderID = [:]
        }
    }

    func sanitizeComposerSelections() {
        let validAgentNames = Set(selectableAgents.map(\.name))
        selectedAgentNamesBySessionID = selectedAgentNamesBySessionID.filter { validAgentNames.contains($0.value) }

        let validModels = Set(availableProviders.flatMap { provider in
            provider.models.values.map { OpenCodeModelReference(providerID: provider.id, modelID: $0.id) }
        })
        selectedModelsBySessionID = selectedModelsBySessionID.filter { validModels.contains($0.value) }

        selectedVariantsBySessionID = selectedVariantsBySessionID.filter { sessionID, variant in
            guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
            return reasoningVariants(for: session).contains(variant)
        }
    }

    func syncComposerSelections(for session: OpenCodeSession) {
        let lastUserMessage = directoryState.messages.reversed().first {
            ($0.info.role ?? "").lowercased() == "user"
        }

        if let agent = lastUserMessage?.info.agent,
           selectableAgents.contains(where: { $0.name == agent }) {
            selectedAgentNamesBySessionID[session.id] = agent
        } else {
            selectedAgentNamesBySessionID[session.id] = nil
        }

        if let model = lastUserMessage?.info.model {
            let reference = OpenCodeModelReference(providerID: model.providerID, modelID: model.modelID)
            let validModels = Set(availableProviders.flatMap { provider in
                provider.models.values.map { OpenCodeModelReference(providerID: provider.id, modelID: $0.id) }
            })

            if validModels.contains(reference) {
                selectedModelsBySessionID[session.id] = reference
            } else {
                selectedModelsBySessionID[session.id] = nil
            }

            if let variant = model.variant,
               reasoningVariants(for: session).contains(variant) {
                selectedVariantsBySessionID[session.id] = variant
            } else {
                selectedVariantsBySessionID[session.id] = nil
            }
            return
        }

        selectedModelsBySessionID[session.id] = nil
        selectedVariantsBySessionID[session.id] = nil
    }
}
