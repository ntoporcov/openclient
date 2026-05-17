import Foundation
import SwiftUI

extension AppViewModel {
    struct ChatComposerOverlaySnapshot {
        let todos: [OpenCodeTodo]
        let attachments: [OpenCodeComposerAttachment]
        let permissions: [OpenCodePermission]
        let questions: [OpenCodeQuestionRequest]

        var showsAccessoryArea: Bool {
            todos.contains { !$0.isComplete } || !attachments.isEmpty
        }

        var attachmentIDs: [String] {
            attachments.map(\.id)
        }

        var incompleteTodoIDs: [String] {
            todos.filter { !$0.isComplete }.map(\.id)
        }
    }

    struct ChatComposerSnapshot {
        let commands: [OpenCodeCommand]
        let attachmentCount: Int
        let isBusy: Bool
        let canFork: Bool
        let forkableMessages: [OpenCodeForkableMessage]
        let forkSignature: String
        let mcp: MCPSnapshot
        let mcpSignature: String
        let actionSignature: String
    }

    func chatComposerOverlaySnapshot(forSessionID sessionID: String) -> ChatComposerOverlaySnapshot {
        ChatComposerOverlaySnapshot(
            todos: todos,
            attachments: draftAttachments,
            permissions: permissions(for: sessionID),
            questions: questions(for: sessionID)
        )
    }

    func chatComposerSnapshot(for session: OpenCodeSession, isBusy: Bool) -> ChatComposerSnapshot {
        let canFork = !forkableMessages.isEmpty
        let commands = commands(canFork: canFork)
        let forkSignature = forkableMessages
            .map { "\($0.id):\($0.text):\($0.created ?? 0)" }
            .joined(separator: "|")
        let mcpSnapshot = mcpSnapshot
        let mcpSignature = mcpSnapshot.servers
            .map { "\($0.name):\($0.status.status):\($0.status.error ?? "")" }
            .joined(separator: "|") + "|loading=\(mcpSnapshot.isLoading)|toggling=\(mcpSnapshot.togglingServerNames.sorted().joined(separator: ","))|error=\(mcpSnapshot.errorMessage ?? "")"
        let actionSignature = [
            session.id,
            session.directory ?? "",
            session.workspaceID ?? "",
            session.projectID ?? "",
            session.parentID ?? ""
        ].joined(separator: "|")

        return ChatComposerSnapshot(
            commands: commands,
            attachmentCount: draftAttachments.count,
            isBusy: isBusy,
            canFork: canFork,
            forkableMessages: forkableMessages,
            forkSignature: forkSignature,
            mcp: mcpSnapshot,
            mcpSignature: mcpSignature,
            actionSignature: actionSignature
        )
    }

    func addDraftAttachments(_ attachments: [OpenCodeComposerAttachment]) {
        withAnimation(opencodeSelectionAnimation) {
            objectWillChange.send()
            composerStore.addAttachments(attachments)
        }
    }

    func removeDraftAttachment(_ attachment: OpenCodeComposerAttachment) {
        withAnimation(opencodeSelectionAnimation) {
            objectWillChange.send()
            composerStore.removeAttachment(id: attachment.id)
        }
    }

    func clearDraftAttachments() {
        withAnimation(opencodeSelectionAnimation) {
            objectWillChange.send()
            composerStore.clearAttachments()
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
        objectWillChange.send()
        composerStore.restoreDraft(forKey: messageDraftStorageKey(for: session))
    }

    func setDraftMessage(_ text: String, forSessionID sessionID: String) {
        guard selectedSession?.id == sessionID else { return }
        saveMessageDraft(text, forSessionID: sessionID)
    }

    func setDraftAgentMentions(_ mentions: [OpenCodeAgentMention], forSessionID sessionID: String) {
        guard selectedSession?.id == sessionID else { return }
        objectWillChange.send()
        composerStore.draftAgentMentions = mentions
        saveMessageDraft(draftMessage, agentMentions: mentions, forSessionID: sessionID)
    }

    func hasMessageDraft(for session: OpenCodeSession) -> Bool {
        if selectedSession?.id == session.id,
           !draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }

        return composerStore.hasNonEmptyDraft(forKey: messageDraftStorageKey(for: session))
    }

    func restoreMessageDraftIfComposerIsEmpty(for session: OpenCodeSession) {
        guard selectedSession?.id == session.id else { return }
        objectWillChange.send()
        _ = composerStore.restoreDraftIfActiveIsEmpty(forKey: messageDraftStorageKey(for: session))
    }

    func persistCurrentMessageDraft(forSessionID sessionID: String? = nil, removesEmpty: Bool = true) {
        guard let sessionID = sessionID ?? selectedSession?.id else { return }

        saveMessageDraft(draftMessage, agentMentions: draftAgentMentions, forSessionID: sessionID, removesEmpty: removesEmpty, updateActiveDraft: false)
    }

    func saveMessageDraft(
        _ text: String,
        agentMentions: [OpenCodeAgentMention]? = nil,
        forSessionID sessionID: String,
        removesEmpty: Bool = true,
        updateActiveDraft: Bool = true
    ) {
        if updateActiveDraft, selectedSession?.id == sessionID {
            objectWillChange.send()
        }

        let key = messageDraftStorageKey(forSessionID: sessionID)
        composerStore.saveDraft(
            text,
            agentMentions: agentMentions ?? (selectedSession?.id == sessionID ? draftAgentMentions : composerStore.draftsByChatKey[key]?.agentMentions ?? []),
            forKey: key,
            removesEmpty: removesEmpty,
            updateActiveDraft: updateActiveDraft && selectedSession?.id == sessionID
        )
        saveMessageDraftsByChatKey()
    }

    func preserveCurrentMessageDraftForNavigation(forSessionID sessionID: String? = nil) {
        persistCurrentMessageDraft(forSessionID: sessionID, removesEmpty: false)
    }

    func clearPersistedMessageDraft(forSessionID sessionID: String? = nil) {
        guard let sessionID = sessionID ?? selectedSession?.id else { return }
        if selectedSession?.id == sessionID {
            objectWillChange.send()
        }
        composerStore.clearDraft(
            forKey: messageDraftStorageKey(forSessionID: sessionID),
            clearActive: selectedSession?.id == sessionID
        )
        saveMessageDraftsByChatKey()
    }

    func loadMessageDraftsByChatKey() -> [String: OpenCodeMessageDraft] {
        composerStore.loadDrafts(storageKey: StorageKey.messageDraftsByChat)
        return composerStore.draftsByChatKey
    }

    func saveMessageDraftsByChatKey(_ drafts: [String: OpenCodeMessageDraft]? = nil) {
        if let drafts {
            objectWillChange.send()
            composerStore.draftsByChatKey = drafts
        }
        composerStore.saveDrafts(storageKey: StorageKey.messageDraftsByChat)
    }

    var selectableAgents: [OpenCodeAgent] {
        modelConfigurationStore.selectableAgents
    }

    var mentionableAgents: [OpenCodeAgent] {
        modelConfigurationStore.mentionableAgents
    }

    var sortedProviders: [OpenCodeProvider] {
        modelConfigurationStore.sortedProviders
    }

    var currentServerDefaultsKey: String? {
        NewSessionDefaultsStore.normalizedBaseURL(config.baseURL)
    }

    var validModelReferences: Set<OpenCodeModelReference> {
        modelConfigurationStore.validModelReferences
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
        objectWillChange.send()
        modelConfigurationStore.setNewSessionDefaultAgent(name)
        saveNewSessionDefaults()
    }

    func setNewSessionDefaultModel(_ reference: OpenCodeModelReference?) {
        objectWillChange.send()
        modelConfigurationStore.setNewSessionDefaultModel(reference)
        saveNewSessionDefaults()
    }

    func setNewSessionDefaultReasoning(_ variant: String?) {
        objectWillChange.send()
        modelConfigurationStore.setNewSessionDefaultReasoning(variant)
        saveNewSessionDefaults()
    }

    func newSessionDefaultModelReference() -> OpenCodeModelReference? {
        modelConfigurationStore.newSessionDefaultModelReference()
    }

    func model(for reference: OpenCodeModelReference?) -> OpenCodeModel? {
        modelConfigurationStore.model(for: reference)
    }

    var configurationEffectiveModelReference: OpenCodeModelReference? {
        modelConfigurationStore.configurationEffectiveModelReference
    }

    var configurationReasoningVariants: [String] {
        modelConfigurationStore.configurationReasoningVariants
    }

    var configurationModelTitle: String {
        modelConfigurationStore.configurationModelTitle
    }

    var configurationAgentTitle: String {
        modelConfigurationStore.configurationAgentTitle
    }

    var configurationReasoningTitle: String {
        modelConfigurationStore.configurationReasoningTitle
    }

    func agentToolbarTitle(for session: OpenCodeSession) -> String {
        effectiveAgentName(for: session) ?? "Agent"
    }

    func modelToolbarTitle(for session: OpenCodeSession) -> String {
        effectiveModel(for: session)?.name ?? "Model"
    }

    func selectedAgentName(for session: OpenCodeSession) -> String? {
        modelConfigurationStore.selectedAgentName(for: session.id)
    }

    func selectedModelReference(for session: OpenCodeSession) -> OpenCodeModelReference? {
        modelConfigurationStore.selectedModelReference(for: session.id)
    }

    func selectedModel(for session: OpenCodeSession) -> OpenCodeModel? {
        modelConfigurationStore.selectedModel(for: session.id)
    }

    func effectiveAgentName(for session: OpenCodeSession) -> String? {
        if isFunAndGamesSession(session.id) {
            return "plan"
        }

        return modelConfigurationStore.effectiveAgentName(for: session.id)
    }

    func defaultModelReference() -> OpenCodeModelReference? {
        modelConfigurationStore.defaultModelReference()
    }

    func effectiveModelReference(for session: OpenCodeSession) -> OpenCodeModelReference? {
        modelConfigurationStore.effectiveModelReference(for: session.id)
    }

    func effectiveModel(for session: OpenCodeSession) -> OpenCodeModel? {
        modelConfigurationStore.effectiveModel(for: session.id)
    }

    func reasoningVariants(for session: OpenCodeSession) -> [String] {
        modelConfigurationStore.reasoningVariants(forSessionID: session.id)
    }

    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] {
        modelConfigurationStore.reasoningVariants(for: reference)
    }

    func selectedVariant(for session: OpenCodeSession) -> String? {
        modelConfigurationStore.selectedVariant(for: session.id)
    }

    func reasoningToolbarTitle(for session: OpenCodeSession) -> String {
        if let selectedVariant = selectedVariant(for: session) {
            return formattedVariantTitle(selectedVariant)
        }
        return "Default"
    }

    func selectAgent(named name: String?, for session: OpenCodeSession) {
        objectWillChange.send()
        modelConfigurationStore.selectAgent(named: name, forSessionID: session.id)
    }

    func selectModel(_ reference: OpenCodeModelReference?, for session: OpenCodeSession) {
        objectWillChange.send()
        modelConfigurationStore.selectModel(reference, forSessionID: session.id)
    }

    func selectVariant(_ variant: String?, for session: OpenCodeSession) {
        objectWillChange.send()
        modelConfigurationStore.selectVariant(variant, forSessionID: session.id)
    }

    func formattedVariantTitle(_ variant: String) -> String {
        modelConfigurationStore.formattedVariantTitle(variant)
    }

    func loadComposerOptions() async {
        do {
            async let agents = client.listAgents(directory: effectiveSelectedDirectory)
            async let providerConfiguration = client.providerConfiguration(directory: effectiveSelectedDirectory)
            let loadedProviderConfiguration = try await providerConfiguration
            objectWillChange.send()
            modelConfigurationStore.applyComposerOptions(
                agents: try await agents,
                providers: loadedProviderConfiguration.providers,
                defaults: loadedProviderConfiguration.default ?? [:]
            )
            loadNewSessionDefaults()
            loadFunAndGamesPreferences()
            sanitizeComposerSelections()
        } catch {
            objectWillChange.send()
            modelConfigurationStore.clearComposerOptions()
            loadNewSessionDefaults()
            loadFunAndGamesPreferences()
        }
    }

    func sanitizeNewSessionDefaults() {
        objectWillChange.send()
        modelConfigurationStore.sanitizeNewSessionDefaults()
    }

    func sanitizeComposerSelections() {
        objectWillChange.send()
        modelConfigurationStore.sanitizeComposerSelections(validSessionIDs: Set(sessions.map(\.id)))
    }

    func seedComposerSelectionsForNewSession(_ session: OpenCodeSession) {
        objectWillChange.send()
        modelConfigurationStore.seedSelectionsForNewSession(sessionID: session.id)
    }

    func syncComposerSelections(for session: OpenCodeSession) {
        let lastUserMessage = messages.reversed().first {
            ($0.info.role ?? "").lowercased() == "user"
        }

        guard let lastUserMessage else {
            seedComposerSelectionsForNewSession(session)
            return
        }
        objectWillChange.send()
        _ = modelConfigurationStore.syncSelections(
            forSessionID: session.id,
            agent: lastUserMessage.info.agent,
            model: lastUserMessage.info.model
        )
    }
}
