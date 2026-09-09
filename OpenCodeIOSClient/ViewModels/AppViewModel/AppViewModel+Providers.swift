import Foundation

struct OpenCodeCustomProviderDraft: Equatable, Sendable {
    struct ModelRow: Identifiable, Equatable, Sendable {
        let id = UUID()
        var modelID: String = ""
        var name: String = ""
    }

    struct HeaderRow: Identifiable, Equatable, Sendable {
        let id = UUID()
        var key: String = ""
        var value: String = ""
    }

    var providerID: String = ""
    var name: String = ""
    var baseURL: String = ""
    var apiKey: String = ""
    var models: [ModelRow] = [ModelRow()]
    var headers: [HeaderRow] = [HeaderRow()]
}

extension AppViewModel {
    var sortedConnectedProviders: [OpenCodeProvider] { modelConfigurationStore.sortedConnectedProviders }
    var addableProviders: [OpenCodeProvider] { modelConfigurationStore.addableProviders }
    var popularAddableProviders: [OpenCodeProvider] { modelConfigurationStore.popularAddableProviders }
    var isLoadingProviders: Bool { modelConfigurationStore.isLoadingProviders }
    var providerErrorMessage: String? { modelConfigurationStore.providerErrorMessage }

    func providerSourceTitle(_ provider: OpenCodeProvider) -> String {
        modelConfigurationStore.sourceTitle(for: provider)
    }

    func canDisconnectProvider(_ provider: OpenCodeProvider) -> Bool {
        compatibilityClient(for: .providerConfiguration) != nil
            && connectionStore.apiProfile != .v2 && modelConfigurationStore.canDisconnect(provider)
    }

    func models(for provider: OpenCodeProvider) -> [OpenCodeModel] {
        modelConfigurationStore.models(for: provider)
    }

    func authMethods(for provider: OpenCodeProvider) -> [OpenCodeProviderAuthMethod] {
        guard compatibilityClient(for: .providerConfiguration) != nil, connectionStore.apiProfile != .v2 else { return [] }
        return modelConfigurationStore.providerAuthMethodsByProviderID[provider.id] ?? [OpenCodeProviderAuthMethod(type: "api", label: "API Key", prompts: nil)]
    }

    func modelEntries(for provider: OpenCodeProvider) -> [ModelConfigurationModelEntry] {
        modelConfigurationStore.modelEntries(for: provider)
    }

    func modelVisibilityStates(for provider: OpenCodeProvider) -> [String: Bool] {
        modelConfigurationStore.modelVisibilityStates(for: provider)
    }

    func isModelVisible(provider: OpenCodeProvider, model: OpenCodeModel) -> Bool {
        modelConfigurationStore.isModelVisible(OpenCodeModelReference(providerID: provider.id, modelID: model.id))
    }

    func isModelVisible(_ reference: OpenCodeModelReference) -> Bool {
        modelConfigurationStore.isModelVisible(reference)
    }

    func setModelVisibility(provider: OpenCodeProvider, model: OpenCodeModel, isVisible: Bool) {
        objectWillChange.send()
        modelConfigurationStore.setModelVisibility(OpenCodeModelReference(providerID: provider.id, modelID: model.id), isVisible: isVisible)
        scheduleWidgetSnapshotPublication(includeModelOptions: true)
    }

    func setModelVisibility(_ reference: OpenCodeModelReference, isVisible: Bool) {
        objectWillChange.send()
        modelConfigurationStore.setModelVisibility(reference, isVisible: isVisible)
        scheduleWidgetSnapshotPublication(includeModelOptions: true)
    }

    func isProviderFullyVisible(_ provider: OpenCodeProvider) -> Bool {
        modelConfigurationStore.isProviderFullyVisible(provider)
    }

    func setProviderVisibility(_ provider: OpenCodeProvider, isVisible: Bool) {
        objectWillChange.send()
        modelConfigurationStore.setProviderVisibility(provider, isVisible: isVisible)
        scheduleWidgetSnapshotPublication(includeModelOptions: true)
    }

    func providerConfigurationScope(directory: String?) -> String {
        "\(config.recentServerID)|\(directory ?? "global")"
    }

    func loadProvidersForConfiguration(ifNeeded: Bool = false) async {
        guard !Task.isCancelled else { return }
        guard connectionStore.apiProfile != .v2, let requestClient = compatibilityClient(for: .providerConfiguration) else {
            await loadComposerOptions()
            return
        }
        guard connectionStore.apiProfile != nil || config.apiPreference == .legacy else { return }
        let directory = effectiveSelectedDirectory
        let scope = providerConfigurationScope(directory: directory)
        let profile = connectionStore.apiProfile
        if ifNeeded, !modelConfigurationStore.shouldLoadProviders(for: scope) {
            return
        }

        if ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] != nil, !modelConfigurationStore.allProviders.isEmpty {
            modelConfigurationStore.isLoadingProviders = false
            modelConfigurationStore.providerErrorMessage = nil
            modelConfigurationStore.markProvidersLoaded(for: scope)
            return
        }

        objectWillChange.send()
        modelConfigurationStore.isLoadingProviders = true
        modelConfigurationStore.providerErrorMessage = nil
        do {
            async let providerState = requestClient.providerState(directory: directory)
            async let authMethods = requestClient.providerAuthMethods(directory: directory)
            let loadedState = try await providerState
            let loadedAuthMethods = try await authMethods
            guard !Task.isCancelled, connectionStore.apiProfile == profile,
                  config == requestClient.config, effectiveSelectedDirectory == directory else { return }
            if try await repairAccidentallyDisabledAuthProviders(providerState: loadedState, authMethods: loadedAuthMethods, client: requestClient) {
                await loadProvidersForConfiguration()
                return
            }
            guard !Task.isCancelled, connectionStore.apiProfile == profile,
                  config == requestClient.config, effectiveSelectedDirectory == directory else { return }
            objectWillChange.send()
            modelConfigurationStore.applyProviderState(loadedState)
            modelConfigurationStore.applyProviderAuthMethods(loadedAuthMethods)
            modelConfigurationStore.markProvidersLoaded(for: scope)
            modelConfigurationStore.isLoadingProviders = false
            sanitizeComposerSelections()
            await widgetSnapshotPublisher.publishNow(includeModelOptions: true, modelsAreAuthoritative: true)
        } catch {
            guard !Task.isCancelled, connectionStore.apiProfile == profile,
                  config == requestClient.config, effectiveSelectedDirectory == directory else { return }
            objectWillChange.send()
            modelConfigurationStore.isLoadingProviders = false
            modelConfigurationStore.providerErrorMessage = error.localizedDescription
        }
    }

    func connectProviderWithAPIKey(providerID: String, key: String) async -> Bool {
        guard allowsProviderMutation, let client = compatibilityClient(for: .providerConfiguration) else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            errorMessage = String(localized: "API key is required.")
            return false
        }

        objectWillChange.send()
        modelConfigurationStore.connectingProviderID = providerID
        do {
            try await client.setProviderAPIKey(providerID: providerID, key: trimmed)
            try? await client.disposeGlobal()
            await loadProvidersForConfiguration()
            objectWillChange.send()
            modelConfigurationStore.connectingProviderID = nil
            return true
        } catch {
            objectWillChange.send()
            modelConfigurationStore.connectingProviderID = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func authorizeProviderOAuth(providerID: String, methodIndex: Int, inputs: [String: String]) async -> OpenCodeProviderAuthAuthorization? {
        guard allowsProviderMutation, let client = compatibilityClient(for: .providerConfiguration) else { return nil }
        objectWillChange.send()
        modelConfigurationStore.connectingProviderID = providerID
        do {
            let authorization = try await client.authorizeProviderOAuth(
                providerID: providerID,
                method: methodIndex,
                inputs: inputs.isEmpty ? nil : inputs,
                directory: effectiveSelectedDirectory
            )
            objectWillChange.send()
            modelConfigurationStore.connectingProviderID = nil
            return authorization
        } catch {
            objectWillChange.send()
            modelConfigurationStore.connectingProviderID = nil
            errorMessage = error.localizedDescription
            return nil
        }
    }

    func completeProviderOAuth(providerID: String, methodIndex: Int, code: String? = nil) async -> Bool {
        guard allowsProviderMutation, let client = compatibilityClient(for: .providerConfiguration) else { return false }
        let trimmedCode = code?.trimmingCharacters(in: .whitespacesAndNewlines)
        objectWillChange.send()
        modelConfigurationStore.connectingProviderID = providerID
        do {
            let didComplete = try await client.completeProviderOAuth(
                providerID: providerID,
                method: methodIndex,
                code: trimmedCode?.isEmpty == true ? nil : trimmedCode,
                directory: effectiveSelectedDirectory
            )
            guard didComplete else {
                objectWillChange.send()
                modelConfigurationStore.connectingProviderID = nil
                errorMessage = String(localized: "OAuth authorization did not complete.")
                return false
            }
            try? await client.disposeGlobal()
            await loadProvidersForConfiguration()
            objectWillChange.send()
            modelConfigurationStore.connectingProviderID = nil
            return true
        } catch {
            objectWillChange.send()
            modelConfigurationStore.connectingProviderID = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func disconnectProvider(_ provider: OpenCodeProvider) async -> Bool {
        guard allowsProviderMutation, let client = compatibilityClient(for: .providerConfiguration) else { return false }
        guard canDisconnectProvider(provider) else {
            errorMessage = String(localized: "\(provider.name) is managed by environment variables on the server.")
            return false
        }

        objectWillChange.send()
        modelConfigurationStore.disconnectingProviderID = provider.id
        modelConfigurationStore.removeConnectedProvider(id: provider.id)
        do {
            if modelConfigurationStore.isConfigCustomProvider(provider) {
                try? await client.removeProviderAuth(providerID: provider.id)
                try await disableProviderInGlobalConfig(providerID: provider.id, client: client)
            } else {
                try await client.removeProviderAuth(providerID: provider.id)
                try? await client.disposeGlobal()
            }
            await loadProvidersForConfiguration()
            objectWillChange.send()
            modelConfigurationStore.disconnectingProviderID = nil
            return true
        } catch {
            objectWillChange.send()
            modelConfigurationStore.disconnectingProviderID = nil
            errorMessage = error.localizedDescription
            return false
        }
    }

    func saveCustomProvider(_ draft: OpenCodeCustomProviderDraft) async -> Bool {
        if connectionStore.apiProfile == .v2 {
            errorMessage = String(localized: "Custom provider configuration is unavailable on this v2 server. Configure it on the server instead.")
            return false
        }
        guard allowsProviderMutation, let client = compatibilityClient(for: .providerConfiguration) else { return false }
        let providerID = draft.providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let baseURL = draft.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let apiKey = draft.apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard providerID.range(of: #"^[a-z0-9][a-z0-9-_]*$"#, options: .regularExpression) != nil else {
            errorMessage = String(localized: "Provider ID must use lowercase letters, numbers, dashes, or underscores.")
            return false
        }
        guard !name.isEmpty else { errorMessage = String(localized: "Provider name is required."); return false }
        guard baseURL.hasPrefix("http://") || baseURL.hasPrefix("https://") else { errorMessage = String(localized: "Base URL must start with http:// or https://."); return false }

        let modelPairs = draft.models.map { ($0.modelID.trimmingCharacters(in: .whitespacesAndNewlines), $0.name.trimmingCharacters(in: .whitespacesAndNewlines)) }
        guard !modelPairs.isEmpty, modelPairs.allSatisfy({ !$0.0.isEmpty && !$0.1.isEmpty }) else {
            errorMessage = String(localized: "Each custom model needs an ID and name.")
            return false
        }
        guard Set(modelPairs.map(\.0)).count == modelPairs.count else { errorMessage = String(localized: "Custom model IDs must be unique."); return false }

        let headers = draft.headers
            .map { ($0.key.trimmingCharacters(in: .whitespacesAndNewlines), $0.value.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { !$0.0.isEmpty || !$0.1.isEmpty }
        guard headers.allSatisfy({ !$0.0.isEmpty && !$0.1.isEmpty }) else { errorMessage = String(localized: "Each custom header needs a key and value."); return false }
        guard Set(headers.map { $0.0.lowercased() }).count == headers.count else { errorMessage = String(localized: "Custom header keys must be unique."); return false }

        do {
            let disabled = try await disabledProviders(client: client).filter { $0 != providerID }
            let env = apiKey.matchingEnvironmentReference
            var options: [String: OpenCodeJSONValue] = ["baseURL": .string(baseURL)]
            if !headers.isEmpty {
                options["headers"] = .object(Dictionary(uniqueKeysWithValues: headers.map { ($0.0, .string($0.1)) }))
            }
            let config = OpenCodeProviderConfig(
                npm: "@ai-sdk/openai-compatible",
                name: name,
                env: env.map { [$0] },
                options: options,
                models: Dictionary(uniqueKeysWithValues: modelPairs.map { ($0.0, OpenCodeProviderConfig.Model(name: $0.1)) })
            )
            if !apiKey.isEmpty, env == nil {
                try await client.setProviderAPIKey(providerID: providerID, key: apiKey)
            }
            try await client.updateGlobalConfig(OpenCodeGlobalConfigPatch(provider: [providerID: config], disabledProviders: disabled))
            try? await client.disposeGlobal()
            await loadProvidersForConfiguration()
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private var allowsProviderMutation: Bool {
        guard compatibilityClient(for: .providerConfiguration) != nil else {
            errorMessage = String(localized: "Provider Unavailable")
            return false
        }
        guard connectionStore.apiProfile == .legacy || (connectionStore.apiProfile == nil && config.apiPreference == .legacy) else {
            errorMessage = String(localized: "Manage provider connections in the OpenCode web app for this v2 server.")
            return false
        }
        return true
    }

    private func disableProviderInGlobalConfig(providerID: String, client: OpenCodeAPIClient) async throws {
        let before = try await disabledProviders(client: client)
        let next = before.contains(providerID) ? before : before + [providerID]
        try await client.updateGlobalConfig(OpenCodeGlobalConfigPatch(provider: nil, disabledProviders: next))
    }

    private func repairAccidentallyDisabledAuthProviders(providerState: OpenCodeProviderListResponse, authMethods: [String: [OpenCodeProviderAuthMethod]], client: OpenCodeAPIClient) async throws -> Bool {
        guard allowsProviderMutation else { return false }
        let providerIDs = Set(providerState.all.map(\.id))
        let hiddenAuthProviderIDs = Set(authMethods.keys).subtracting(providerIDs)
        guard !hiddenAuthProviderIDs.isEmpty else { return false }

        let disabled = try await disabledProviders(client: client)
        guard allowsProviderMutation, config == client.config else { return false }
        let repaired = disabled.filter { !hiddenAuthProviderIDs.contains($0) }
        guard repaired.count != disabled.count else { return false }
        try await client.updateGlobalConfig(OpenCodeGlobalConfigPatch(provider: nil, disabledProviders: repaired))
        try? await client.disposeGlobal()
        return true
    }

    private func disabledProviders(client: OpenCodeAPIClient) async throws -> [String] {
        let config = try await client.globalConfig()
        guard let values = config.objectValue?["disabled_providers"]?.arrayValue else { return [] }
        return values.compactMap(\.stringValue)
    }
}

private extension String {
    var matchingEnvironmentReference: String? {
        let pattern = #"^\{env:([^}]+)\}$"#
        guard let range = range(of: pattern, options: .regularExpression) else { return nil }
        let value = String(self[range])
        return value
            .replacingOccurrences(of: "{env:", with: "")
            .replacingOccurrences(of: "}", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
