import Foundation

extension AppViewModel {
    func connect() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let bootstrap = try await OpenCodeBootstrap.bootstrapGlobal(client: client)
            isConnected = bootstrap.health.healthy
            serverVersion = bootstrap.health.version
            errorMessage = nil
            persistConfig()
            hasSavedServer = true
            showSavedServerPrompt = false
            loadNewSessionDefaults()
            projects = bootstrap.projects
            selectedDirectory = directorySelection(for: bootstrap.currentProject)
            reconcileCurrentProjectSelection(serverProject: bootstrap.currentProject)
            try await reloadSessions()
            await loadComposerOptions()
            streamDirectory = directoryState.sessions.first?.directory
            startEventStream()
            await runUITestBootstrapIfNeeded()
        } catch {
            stopEventStream()
            isConnected = false
            directoryState = OpenCodeDirectoryState()
            errorMessage = error.localizedDescription
        }
    }

    func disconnect() {
        stopEventStream()
        isConnected = false
        serverVersion = ""
        projects = []
        currentProject = nil
        selectedDirectory = nil
        projectSearchQuery = ""
        projectSearchResults = []
        directoryState = OpenCodeDirectoryState()
        availableAgents = []
        availableProviders = []
        selectedAgentNamesBySessionID = [:]
        selectedModelsBySessionID = [:]
        selectedVariantsBySessionID = [:]
        newSessionDefaults = NewSessionDefaults()
        errorMessage = nil
        showSavedServerPrompt = hasSavedServer
    }

    func reconnectToSavedServer() async {
        guard hasSavedServer else { return }
        await connect()
    }

    func dismissSavedServerPrompt() {
        showSavedServerPrompt = false
    }

    func persistConfig() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.lastServerConfig)
    }

    func loadSavedConfig() -> OpenCodeServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.lastServerConfig) else {
            return nil
        }

        return try? JSONDecoder().decode(OpenCodeServerConfig.self, from: data)
    }

    func configureUITestEnvironmentIfNeeded() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCODE_UI_TEST_MODE"] == "1" else {
            return false
        }

        UserDefaults.standard.removeObject(forKey: StorageKey.lastServerConfig)
        config.baseURL = environment["OPENCODE_UI_TEST_BASE_URL"] ?? "http://127.0.0.1:4096"
        config.username = environment["OPENCODE_UI_TEST_USERNAME"] ?? "opencode"
        config.password = environment["OPENCODE_UI_TEST_PASSWORD"] ?? ""
        uiTestBootstrapTitle = environment["OPENCODE_UI_TEST_SESSION_TITLE"]
        uiTestBootstrapPrompt = environment["OPENCODE_UI_TEST_PROMPT"]
        uiTestDirectory = environment["OPENCODE_UI_TEST_DIRECTORY"]
        hasSavedServer = false
        showSavedServerPrompt = false
        return true
    }

    func runUITestBootstrapIfNeeded() async {
        guard let title = uiTestBootstrapTitle,
              let prompt = uiTestBootstrapPrompt else {
            return
        }

        uiTestBootstrapTitle = nil
        uiTestBootstrapPrompt = nil

        do {
            if let uiTestDirectory, !uiTestDirectory.isEmpty {
                await selectDirectory(uiTestDirectory)
            }
            let session = try await client.createSession(title: title, directory: effectiveSelectedDirectory)
            upsertVisibleSession(session)
            directoryState.selectedSession = session
            try await loadMessages(for: session)
            try await client.sendMessageAsync(sessionID: session.id, text: prompt, directory: sendDirectory(for: session))
            try await loadMessages(for: session)
            try await reloadSessions()
            upsertVisibleSession(session)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
