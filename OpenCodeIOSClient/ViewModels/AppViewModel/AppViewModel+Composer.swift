import Foundation
import SwiftUI

extension AppViewModel {
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
        let didChangeStoredDraft = composerStore.saveDraft(
            text,
            agentMentions: agentMentions ?? (selectedSession?.id == sessionID ? draftAgentMentions : composerStore.draftsByChatKey[key]?.agentMentions ?? []),
            forKey: key,
            removesEmpty: removesEmpty,
            updateActiveDraft: updateActiveDraft && selectedSession?.id == sessionID
        )
        guard didChangeStoredDraft else { return }
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

    func setVoiceModeModel(_ reference: OpenCodeModelReference?) {
        objectWillChange.send()
        modelConfigurationStore.setVoiceModeModel(reference)
        saveNewSessionDefaults()
    }

    func newSessionDefaultModelReference() -> OpenCodeModelReference? {
        modelConfigurationStore.newSessionDefaultModelReference()
    }

    func voiceModeModelReference() -> OpenCodeModelReference? {
        modelConfigurationStore.voiceModeModelReference()
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
        if isKnownFunAndGamesSession(session.id) {
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

    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] {
        modelConfigurationStore.reasoningVariants(for: reference)
    }

    func selectedVariant(for session: OpenCodeSession) -> String? {
        modelConfigurationStore.selectedVariant(for: session.id)
    }

    func selectAgent(named name: String?, for session: OpenCodeSession) {
        chatFacade.selectAgent(named: name, for: session)
    }

    func selectModel(_ reference: OpenCodeModelReference?, for session: OpenCodeSession) {
        chatFacade.selectModel(reference, for: session)
    }

    func selectVariant(_ variant: String?, for session: OpenCodeSession) {
        chatFacade.selectReasoningVariant(variant, for: session)
    }

    func formattedVariantTitle(_ variant: String) -> String {
        modelConfigurationStore.formattedVariantTitle(variant)
    }

    func loadComposerOptions() async {
        let directory = effectiveSelectedDirectory
        let providerScope = providerConfigurationScope(directory: directory)
        do {
            async let agents = client.listAgents(directory: directory)
            async let providerState = client.providerState(directory: directory)
            let loadedProviderState = try await providerState
            objectWillChange.send()
            modelConfigurationStore.availableAgents = try await agents
            modelConfigurationStore.applyProviderState(loadedProviderState)
            modelConfigurationStore.markProvidersLoaded(for: providerScope)
            loadNewSessionDefaults()
            loadFunAndGamesPreferences()
            loadProjectListPreferences()
            sanitizeComposerSelections()
            scheduleWidgetSnapshotPublication(includeModelOptions: true)
        } catch {
            objectWillChange.send()
            modelConfigurationStore.clearComposerOptions()
            loadNewSessionDefaults()
            loadFunAndGamesPreferences()
            loadProjectListPreferences()
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

    func syncComposerSelections(for session: OpenCodeSession, sourceMessages: [OpenCodeMessageEnvelope]? = nil) {
        let source = sourceMessages ?? chatFacade.messageSource(for: session)
        let lastUserMessage = source.reversed().first { message in
            message.info.sessionID == session.id && (message.info.role ?? "").lowercased() == "user"
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
