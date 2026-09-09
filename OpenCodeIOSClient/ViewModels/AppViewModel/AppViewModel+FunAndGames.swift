import Foundation
import SwiftUI

extension AppViewModel {
    var allowsFunAndGames: Bool {
        guard !isBrowsingLocalCache, let connection = backendConnection, !connection.isClosed, connection.healthy else { return false }
        if connectionStore.apiProfile == .v2 {
            // Wait for core project bootstrap to provide a usable execution location.
            // A command catalog alone does not establish the game lifecycle.
            return projectStore.defaultServerDirectory?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
        }
        return supportsProjectActionExecution && backendMode != .serverV2
            && backendConnection?.openCodeCompatibility?.profile == .legacy
            && (connectionStore.apiProfile == .legacy || config.apiPreference == .legacy)
    }

    var funAndGamesOwner: FunAndGamesOwner {
        .init(backendID: backendConnection?.descriptor.id ?? config.recentServerID,
              profile: connectionStore.apiProfile == .v2 ? .v2 : .legacy)
    }

    func bindFunAndGamesScope() {
        guard funAndGamesStore.ownerProvider == nil else { return }
        funAndGamesStore.ownerProvider = { [weak self] in
            self?.funAndGamesOwner ?? .init(backendID: "disconnected", profile: .legacy)
        }
    }

    func presentFindPlaceModelSheet() {
        guard allowsFunAndGames else { return }
        bindFunAndGamesScope()
        withAnimation(opencodeSelectionAnimation) {
            isShowingFindPlaceModelSheet = true
        }
    }

    func presentFindBugLanguageSheet() {
        guard allowsFunAndGames else { return }
        bindFunAndGamesScope()
        pendingFindBugLanguage = nil
        withAnimation(opencodeSelectionAnimation) {
            isShowingFindBugLanguageSheet = true
        }
    }

    func selectFindBugLanguage(_ language: FindBugGameLanguage) {
        guard allowsFunAndGames else { return }
        bindFunAndGamesScope()
        pendingFindBugLanguage = language
        withAnimation(opencodeSelectionAnimation) {
            isShowingFindBugLanguageSheet = false
            isShowingFindBugModelSheet = true
        }
    }

    func startFindPlaceGame(model reference: OpenCodeModelReference) async {
        guard allowsFunAndGames else { return }
        bindFunAndGamesScope()
        if connectionStore.apiProfile == .v2 {
            await startV2Game(.findPlace, model: reference)
            return
        }
        let requestClient = client
        let generation = directoryStoreRegistry.generation
        let isCurrent = { [self] in
            !Task.isCancelled && allowsFunAndGames && config == requestClient.config
                && directoryStoreRegistry.generation == generation
        }
        isLoading = true
        defer { if config == requestClient.config, directoryStoreRegistry.generation == generation { isLoading = false } }

        let globalProject = projects.first(where: { $0.id == "global" }) ?? OpenCodeProject(
            id: "global",
            worktree: "",
            vcs: nil,
            name: "Global",
            sandboxes: nil,
            icon: nil,
            time: nil
        )

        do {
            withAnimation(opencodeSelectionAnimation) {
                currentProject = globalProject
                isShowingFindPlaceModelSheet = false
            }
            prepareDirectorySelection(nil)
            try await reloadSessions()
            guard isCurrent() else { return }
            await loadComposerOptions()
            guard isCurrent() else { return }

            let city = FindPlaceGame.randomCity()
            let weather = await FindPlaceWeatherProvider.summary(for: city)
            guard isCurrent() else { return }
            if let weatherError = weather.errorDescription {
                appendDebugLog("find-place WeatherKit fallback city=\(city.id) error=\(weatherError)")
            } else {
                appendDebugLog("find-place WeatherKit success city=\(city.id)")
            }
            let session = try await requestClient.createSession(title: String(localized: "Find the Place"), directory: nil)
            guard isCurrent() else { return }
            upsertVisibleSession(session)
            try await reloadSessions()
            guard isCurrent() else { return }
            upsertVisibleSession(session)

            selectedModelsBySessionID[session.id] = reference
            funAndGamesStore.recordFindPlaceSession(FindPlaceGameSession(sessionID: session.id, city: city, weather: weather))
            withAnimation(opencodeSelectionAnimation) {
                selectedProjectContentTab = .sessions
                selectedSession = session
                isLoadingSelectedSession = true
                messages = []
                sessionInteractionStore.replaceTodos([])
            }
            restoreMessageDraft(for: session)
            streamDirectory = session.directory
            try await loadMessages(for: session)
            guard isCurrent() else { return }
            await sendMessage(
                FindPlaceGame.starterPrompt(city: city, weather: weather),
                in: session,
                userVisible: false,
                appendOptimisticMessage: false,
                meterPrompt: false
            )
            guard isCurrent() else { return }
            errorMessage = nil
        } catch {
            guard isCurrent() else { return }
            errorMessage = error.localizedDescription
        }
    }

    func startFindBugGame(model reference: OpenCodeModelReference) async {
        guard allowsFunAndGames, let language = pendingFindBugLanguage else { return }
        bindFunAndGamesScope()
        if connectionStore.apiProfile == .v2 {
            await startV2Game(.findBug(language), model: reference)
            return
        }
        let requestClient = client
        let generation = directoryStoreRegistry.generation
        let isCurrent = { [self] in
            !Task.isCancelled && allowsFunAndGames && config == requestClient.config
                && directoryStoreRegistry.generation == generation
        }

        isLoading = true
        defer { if config == requestClient.config, directoryStoreRegistry.generation == generation { isLoading = false } }

        let globalProject = projects.first(where: { $0.id == "global" }) ?? OpenCodeProject(
            id: "global",
            worktree: "",
            vcs: nil,
            name: "Global",
            sandboxes: nil,
            icon: nil,
            time: nil
        )

        do {
            withAnimation(opencodeSelectionAnimation) {
                currentProject = globalProject
                isShowingFindBugModelSheet = false
            }
            prepareDirectorySelection(nil)
            try await reloadSessions()
            guard isCurrent() else { return }
            await loadComposerOptions()
            guard isCurrent() else { return }

            let session = try await requestClient.createSession(title: String(localized: "Find the Bug"), directory: nil)
            guard isCurrent() else { return }
            upsertVisibleSession(session)
            try await reloadSessions()
            guard isCurrent() else { return }
            upsertVisibleSession(session)

            selectedModelsBySessionID[session.id] = reference
            funAndGamesStore.recordFindBugSession(FindBugGameSession(sessionID: session.id, language: language))
            pendingFindBugLanguage = nil
            withAnimation(opencodeSelectionAnimation) {
                selectedProjectContentTab = .sessions
                selectedSession = session
                isLoadingSelectedSession = true
                messages = []
                sessionInteractionStore.replaceTodos([])
            }
            restoreMessageDraft(for: session)
            streamDirectory = session.directory
            try await loadMessages(for: session)
            guard isCurrent() else { return }
            await sendMessage(
                FindBugGame.starterPrompt(language: language),
                in: session,
                userVisible: false,
                appendOptimisticMessage: false,
                meterPrompt: false
            )
            guard isCurrent() else { return }
            errorMessage = nil
        } catch {
            guard isCurrent() else { return }
            errorMessage = error.localizedDescription
        }
    }

    private func startV2Game(_ game: FunAndGamesGame, model: OpenCodeModelReference) async {
        guard !isLoading, let connection = try? requireBackendConnection() else { return }
        let owner = funAndGamesOwner
        let generation = directoryStoreRegistry.generation
        var navigationGeneration = sessionNavigationGeneration
        let isCurrent: @MainActor @Sendable () -> Bool = { [self] in
            !Task.isCancelled && isCurrentBackendConnection(connection) && funAndGamesOwner == owner
                && directoryStoreRegistry.generation == generation && sessionNavigationGeneration == navigationGeneration
        }
        isLoading = true
        defer { if isCurrentBackendConnection(connection) { isLoading = false } }
        do {
            let result = try await FunAndGamesCoordinator(store: funAndGamesStore).start(
                game: game, model: model, owner: owner, connection: connection, isCurrent: isCurrent,
                sessionCreated: { [self] setup in
                    guard isCurrent(), let session = setup.session else { throw BackendError.disconnected }
                    currentProject = setup.project ?? projects.first { $0.id == session.projectID }
                    selectedModelsBySessionID[session.id] = setup.model
                    selectedAgentNamesBySessionID[session.id] = "plan"
                    isShowingFindPlaceModelSheet = false
                    isShowingFindBugModelSheet = false
                    _ = beginSessionNavigation(session)
                    navigationGeneration = sessionNavigationGeneration
                    directoryStore.insertV2Session(session)
                    let hydrated = await hydrateV2Transcript(for: session, navigationGeneration: navigationGeneration,
                        expectedDirectoryKey: directoryStoreRegistry.activeKey)
                    guard hydrated else { throw OpenCodeAPIError.invalidResponse }
                }
            )
            guard isCurrent() else { return }
            if result?.phase == .admitted {
                if let setup = result, let session = setup.session {
                    selectedModelsBySessionID[session.id] = setup.model
                    selectedAgentNamesBySessionID[session.id] = "plan"
                }
                pendingFindBugLanguage = nil
                errorMessage = nil
            }
        } catch {
            guard isCurrent() else { return }
            errorMessage = error.localizedDescription
        }
    }

    func findPlaceGame(for sessionID: String) -> FindPlaceGameSession? {
        if let game = funAndGamesStore.findPlaceGame(for: sessionID) {
            return game
        }

        return FunAndGamesStore.inferredFindPlaceGame(in: gameInferenceMessages(for: sessionID), sessionID: sessionID)
    }

    func findBugGame(for sessionID: String) -> FindBugGameSession? {
        if let game = funAndGamesStore.findBugGame(for: sessionID) {
            return game
        }

        return FunAndGamesStore.inferredFindBugGame(in: gameInferenceMessages(for: sessionID), sessionID: sessionID)
    }

    func isFunAndGamesSession(_ sessionID: String) -> Bool {
        findPlaceGame(for: sessionID) != nil || findBugGame(for: sessionID) != nil
    }

    func isKnownFunAndGamesSession(_ sessionID: String) -> Bool {
        findPlaceSessionsByID[sessionID] != nil || findBugSessionsByID[sessionID] != nil
    }

    func shouldMeterPrompts(for sessionID: String) -> Bool {
        !isFunAndGamesSession(sessionID)
    }

    @discardableResult
    func inferFunAndGames(from messages: [OpenCodeMessageEnvelope], forSessionID sessionID: String) -> Bool {
        bindFunAndGamesScope()
        let changed = funAndGamesStore.inferGames(from: messages, forSessionID: sessionID)
        if changed {
            objectWillChange.send()
        }
        return changed
    }

    @discardableResult
    func inferFunAndGames(from event: OpenCodeTypedEvent) -> Bool {
        bindFunAndGamesScope()
        let changed = funAndGamesStore.inferGame(from: event)
        if changed {
            objectWillChange.send()
        }
        return changed
    }

    private func gameInferenceMessages(for sessionID: String) -> [OpenCodeMessageEnvelope] {
        if selectedSession?.id == sessionID, !messages.isEmpty {
            return messages
        }

        let syncedMessages = directoryStore.syncState.messageEnvelopes(forSessionID: sessionID)
        if !syncedMessages.isEmpty {
            return syncedMessages
        }

        if let cachedMessages = cachedMessagesBySessionID[sessionID], !cachedMessages.isEmpty {
            return cachedMessages
        }

        return messages.filter { $0.info.sessionID == sessionID }
    }
}
