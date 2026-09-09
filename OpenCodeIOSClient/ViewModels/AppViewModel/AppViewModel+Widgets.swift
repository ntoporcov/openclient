import Foundation

extension AppViewModel {
    func widgetSnapshotInput(
        includeModelOptions: Bool = false,
        commandsAreAuthoritative: Bool = false,
        modelsAreAuthoritative: Bool = false
    ) -> WidgetSnapshotInput {
        let sessions = allSessions.filter(\.isRootSession)
        var providers: [OpenCodeProvider] = []
        var visibleModelsByProviderID: [String: [OpenCodeModel]] = [:]
        if includeModelOptions {
            var modelCount = 0
            for provider in modelConfigurationStore.sortedProviders {
                let models = Array(
                    modelConfigurationStore.visibleModels(for: provider)
                        .prefix(WidgetSnapshotBuilder.modelPerProviderLimit)
                )
                guard !models.isEmpty else { continue }
                providers.append(provider)
                visibleModelsByProviderID[provider.id] = models
                modelCount += models.count
                if modelCount >= WidgetSnapshotBuilder.modelLimit { break }
            }
        }
        var sessionTitlesByID: [String: String] = [:]
        var permissionsBySessionID: [String: [OpenCodePermission]] = [:]
        var questionsBySessionID: [String: [OpenCodeQuestionRequest]] = [:]
        for session in sessions {
            sessionTitlesByID[session.id] = childSessionTitle(for: session)
            permissionsBySessionID[session.id] = permissions(for: session.id)
            questionsBySessionID[session.id] = questions(for: session.id)
        }
        return WidgetSnapshotInput(
            backendMode: backendMode,
            config: config,
            projects: projects,
            currentProject: currentProject,
            effectiveDirectory: effectiveSelectedDirectory,
            sessions: sessions,
            sessionTitlesByID: sessionTitlesByID,
            statuses: sessionStatuses,
            previews: sessionPreviews,
            pinnedSessionIDs: pinnedSessionIDs,
            permissionsBySessionID: permissionsBySessionID,
            questionsBySessionID: questionsBySessionID,
            commands: directoryCommands,
            providers: providers,
            visibleModelsByProviderID: visibleModelsByProviderID,
            profile: isConnected ? connectionStore.apiProfile.flatMap { OpenCodeProfileIdentity(rawValue: $0.rawValue) } : nil,
            projectsAreAuthoritative: isConnected && !isLoading,
            commandsAreAuthoritative: commandsAreAuthoritative,
            modelsAreAuthoritative: modelsAreAuthoritative,
            supportsNewSession: isConnected && backendConnection?.isClosed == false && backendConnection?.sessionSelection != nil,
            supportsCommands: isConnected && backendConnection?.isClosed == false && backendConnection?.sessionSelection != nil && backendConnection?.commands != nil,
            defaultDirectory: projectStore.defaultServerDirectory
        )
    }

    func scheduleWidgetSnapshotPublication(includeModelOptions: Bool = false) {
        widgetSnapshotPublisher.invalidate(includeModelOptions: includeModelOptions)
    }

    func publishWidgetSnapshots(includeModelOptions: Bool = false) {
        scheduleWidgetSnapshotPublication(includeModelOptions: includeModelOptions)
    }

    func removeWidgetSessionSnapshot(for sessionID: String) {
        guard config.hasCredentials, isConnected,
              let profile = connectionStore.apiProfile.flatMap({ OpenCodeProfileIdentity(rawValue: $0.rawValue) }) else { return }
        widgetSnapshotPublisher.removeSession(owner: .init(profile: profile, serverID: config.recentServerID), sessionID: sessionID)
    }
}
