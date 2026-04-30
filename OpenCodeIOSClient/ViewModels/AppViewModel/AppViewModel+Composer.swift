import Foundation
import SwiftUI

extension AppViewModel {
    private static let preferredFallbackModelReference = OpenCodeModelReference(providerID: "opencode", modelID: "minimax-m2.5-free")

    func addDraftAttachments(_ attachments: [OpenCodeComposerAttachment]) {
        guard !attachments.isEmpty else { return }

        let existingIDs = Set(draftAttachments.map(\.id))
        let newItems = attachments.filter { !existingIDs.contains($0.id) }
        guard !newItems.isEmpty else { return }

        withAnimation(opencodeSelectionAnimation) {
            draftAttachments.append(contentsOf: newItems)
        }
    }

    func removeDraftAttachment(_ attachment: OpenCodeComposerAttachment) {
        withAnimation(opencodeSelectionAnimation) {
            draftAttachments.removeAll { $0.id == attachment.id }
        }
    }

    func clearDraftAttachments() {
        withAnimation(opencodeSelectionAnimation) {
            draftAttachments.removeAll()
        }
    }

    func messageDraftStorageKey(for session: OpenCodeSession) -> String {
        messageDraftStorageKey(forSessionID: session.id)
    }

    func messageDraftStorageKey(forSessionID sessionID: String) -> String {
        let scope: String
        if isUsingAppleIntelligence {
            scope = ["apple-intelligence", activeAppleIntelligenceWorkspaceID ?? "global"].joined(separator: "|")
        } else {
            scope = ["opencode", NewSessionDefaultsStore.normalizedBaseURL(config.baseURL) ?? config.baseURL].joined(separator: "|")
        }

        return [scope, sessionID].joined(separator: "|")
    }

    func restoreMessageDraft(for session: OpenCodeSession) {
        let draft = messageDraftsByChatKey[messageDraftStorageKey(for: session)]
        draftMessage = draft?.text ?? ""
        draftAttachments = []
        composerResetToken = UUID()
    }

    func setDraftMessage(_ text: String, forSessionID sessionID: String) {
        guard selectedSession?.id == sessionID else { return }
        draftMessage = text
        persistCurrentMessageDraft(forSessionID: sessionID)
    }

    func hasMessageDraft(for session: OpenCodeSession) -> Bool {
        if selectedSession?.id == session.id,
           !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return messageDraftsByChatKey[messageDraftStorageKey(for: session)]?.isEmpty == false
    }

    func restoreMessageDraftIfComposerIsEmpty(for session: OpenCodeSession) {
        guard selectedSession?.id == session.id else { return }
        guard draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard let draft = messageDraftsByChatKey[messageDraftStorageKey(for: session)], !draft.isEmpty else { return }

        draftMessage = draft.text
        draftAttachments = []
        composerResetToken = UUID()
    }

    func persistCurrentMessageDraft(forSessionID sessionID: String? = nil, removesEmpty: Bool = true) {
        guard let sessionID = sessionID ?? selectedSession?.id else { return }

        let key = messageDraftStorageKey(forSessionID: sessionID)
        let draft = OpenCodeMessageDraft(text: draftMessage)
        if draft.isEmpty {
            guard removesEmpty else { return }
            messageDraftsByChatKey.removeValue(forKey: key)
        } else {
            messageDraftsByChatKey[key] = draft
        }
        saveMessageDraftsByChatKey(messageDraftsByChatKey)
    }

    func preserveCurrentMessageDraftForNavigation(forSessionID sessionID: String? = nil) {
        persistCurrentMessageDraft(forSessionID: sessionID, removesEmpty: false)
    }

    func clearPersistedMessageDraft(forSessionID sessionID: String? = nil) {
        guard let sessionID = sessionID ?? selectedSession?.id else { return }
        messageDraftsByChatKey.removeValue(forKey: messageDraftStorageKey(forSessionID: sessionID))
        saveMessageDraftsByChatKey(messageDraftsByChatKey)
    }

    func loadMessageDraftsByChatKey() -> [String: OpenCodeMessageDraft] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.messageDraftsByChat) else { return [:] }
        return (try? JSONDecoder().decode([String: OpenCodeMessageDraft].self, from: data)) ?? [:]
    }

    func saveMessageDraftsByChatKey(_ drafts: [String: OpenCodeMessageDraft]) {
        guard let data = try? JSONEncoder().encode(drafts) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.messageDraftsByChat)
    }

    var selectableAgents: [OpenCodeAgent] {
        availableAgents
            .filter { ($0.hidden ?? false) == false && $0.mode != "subagent" }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var sortedProviders: [OpenCodeProvider] {
        availableProviders.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    var currentServerDefaultsKey: String? {
        NewSessionDefaultsStore.normalizedBaseURL(config.baseURL)
    }

    var validModelReferences: Set<OpenCodeModelReference> {
        Set(availableProviders.flatMap { provider in
            provider.models.values.map { OpenCodeModelReference(providerID: provider.id, modelID: $0.id) }
        })
    }

    func presentConfigurationsSheet() {
        sanitizeNewSessionDefaults()
        withAnimation(opencodeSelectionAnimation) {
            isShowingConfigurationsSheet = true
        }
    }

    func loadNewSessionDefaults() {
        let preferences = NewSessionDefaultsStore.load()
        guard let key = currentServerDefaultsKey else {
            newSessionDefaults = NewSessionDefaults()
            return
        }

        newSessionDefaults = preferences.defaultsByBaseURL[key] ?? NewSessionDefaults()
        sanitizeNewSessionDefaults()
    }

    func saveNewSessionDefaults() {
        guard let key = currentServerDefaultsKey else { return }

        sanitizeNewSessionDefaults()
        var preferences = NewSessionDefaultsStore.load()
        preferences.defaultsByBaseURL[key] = newSessionDefaults
        NewSessionDefaultsStore.save(preferences)
    }

    func loadFunAndGamesPreferences() {
        let scopedPreferences = FunAndGamesPreferencesStore.load()
        guard let key = currentServerDefaultsKey else {
            funAndGamesPreferences = FunAndGamesPreferences()
            return
        }

        funAndGamesPreferences = scopedPreferences.preferencesByBaseURL[key] ?? FunAndGamesPreferences()
    }

    func saveFunAndGamesPreferences() {
        guard let key = currentServerDefaultsKey else { return }

        var scopedPreferences = FunAndGamesPreferencesStore.load()
        scopedPreferences.preferencesByBaseURL[key] = funAndGamesPreferences
        FunAndGamesPreferencesStore.save(scopedPreferences)
    }

    func setShowsFunAndGamesSection(_ showsSection: Bool) {
        funAndGamesPreferences.showsSection = showsSection
        saveFunAndGamesPreferences()
    }

    func setNewSessionDefaultAgent(_ name: String?) {
        newSessionDefaults.agentName = name
        saveNewSessionDefaults()
    }

    func setNewSessionDefaultModel(_ reference: OpenCodeModelReference?) {
        newSessionDefaults.providerID = reference?.providerID
        newSessionDefaults.modelID = reference?.modelID

        if let variant = newSessionDefaults.reasoningVariant,
           !reasoningVariants(for: configurationEffectiveModelReference).contains(variant) {
            newSessionDefaults.reasoningVariant = nil
        }

        saveNewSessionDefaults()
    }

    func setNewSessionDefaultReasoning(_ variant: String?) {
        newSessionDefaults.reasoningVariant = variant
        saveNewSessionDefaults()
    }

    func newSessionDefaultModelReference() -> OpenCodeModelReference? {
        guard let providerID = newSessionDefaults.providerID,
              let modelID = newSessionDefaults.modelID else {
            return nil
        }

        let reference = OpenCodeModelReference(providerID: providerID, modelID: modelID)
        return validModelReferences.contains(reference) ? reference : nil
    }

    func model(for reference: OpenCodeModelReference?) -> OpenCodeModel? {
        guard let reference else { return nil }
        return availableProviders.first(where: { $0.id == reference.providerID })?.models[reference.modelID]
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
        return model(for: reference)
    }

    func effectiveAgentName(for session: OpenCodeSession) -> String? {
        selectedAgentName(for: session) ?? selectableAgents.first?.name
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

    func effectiveModelReference(for session: OpenCodeSession) -> OpenCodeModelReference? {
        if let selected = selectedModelReference(for: session) {
            return selected
        }

        return defaultModelReference()
    }

    func effectiveModel(for session: OpenCodeSession) -> OpenCodeModel? {
        guard let reference = effectiveModelReference(for: session) else { return nil }
        return model(for: reference)
    }

    func reasoningVariants(for session: OpenCodeSession) -> [String] {
        guard let model = effectiveModel(for: session), model.capabilities.reasoning else { return [] }
        return (model.variants ?? [:]).keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] {
        guard let model = model(for: reference), model.capabilities.reasoning else { return [] }
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
            loadNewSessionDefaults()
            loadFunAndGamesPreferences()
            sanitizeComposerSelections()
        } catch {
            availableAgents = []
            availableProviders = []
            defaultModelsByProviderID = [:]
            loadNewSessionDefaults()
            loadFunAndGamesPreferences()
        }
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

    func sanitizeComposerSelections() {
        let validAgentNames = Set(selectableAgents.map(\.name))
        selectedAgentNamesBySessionID = selectedAgentNamesBySessionID.filter { validAgentNames.contains($0.value) }

        selectedModelsBySessionID = selectedModelsBySessionID.filter { validModelReferences.contains($0.value) }

        selectedVariantsBySessionID = selectedVariantsBySessionID.filter { sessionID, variant in
            guard let session = sessions.first(where: { $0.id == sessionID }) else { return false }
            return reasoningVariants(for: session).contains(variant)
        }

        sanitizeNewSessionDefaults()
    }

    func seedComposerSelectionsForNewSession(_ session: OpenCodeSession) {
        if selectedAgentNamesBySessionID[session.id] == nil,
           let defaultAgentName = newSessionDefaults.agentName,
           selectableAgents.contains(where: { $0.name == defaultAgentName }) {
            selectedAgentNamesBySessionID[session.id] = defaultAgentName
        }

        if selectedModelsBySessionID[session.id] == nil,
           let defaultModel = newSessionDefaultModelReference() {
            selectedModelsBySessionID[session.id] = defaultModel
        }

        if selectedVariantsBySessionID[session.id] == nil,
           let defaultVariant = newSessionDefaults.reasoningVariant,
           reasoningVariants(for: session).contains(defaultVariant) {
            selectedVariantsBySessionID[session.id] = defaultVariant
        }
    }

    func syncComposerSelections(for session: OpenCodeSession) {
        let lastUserMessage = directoryState.messages.reversed().first {
            ($0.info.role ?? "").lowercased() == "user"
        }

        guard let lastUserMessage else {
            seedComposerSelectionsForNewSession(session)
            return
        }

        if let agent = lastUserMessage.info.agent,
           selectableAgents.contains(where: { $0.name == agent }) {
            selectedAgentNamesBySessionID[session.id] = agent
        } else {
            selectedAgentNamesBySessionID[session.id] = nil
        }

        if let model = lastUserMessage.info.model {
            let reference = OpenCodeModelReference(providerID: model.providerID, modelID: model.modelID)

            if validModelReferences.contains(reference) {
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
