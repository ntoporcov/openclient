import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

extension AppViewModel {
    private static let maxRecentServerCount = 4

    var canTryAppleIntelligence: Bool {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            SystemLanguageModel.default.isAvailable
        } else {
            false
        }
#else
        false
#endif
    }

    var appleIntelligenceAvailabilitySummary: String? {
#if canImport(FoundationModels)
        if #available(iOS 26.0, macOS 26.0, *) {
            switch SystemLanguageModel.default.availability {
            case .available:
                return nil
            case let .unavailable(reason):
                switch reason {
                case .deviceNotEligible:
                    return "Requires an Apple Intelligence-capable device."
                case .appleIntelligenceNotEnabled:
                    return "Turn on Apple Intelligence to try the on-device demo."
                case .modelNotReady:
                    return "Apple Intelligence is still preparing on this device."
                @unknown default:
                    return "Apple Intelligence is unavailable on this device right now."
                }
            }
        }
#endif
        return "Requires a device that supports Apple Intelligence."
    }

    func connect() async {
        isLoading = true
        defer { isLoading = false }

        do {
            let bootstrap = try await OpenCodeBootstrap.bootstrapGlobal(client: client)
            backendMode = .server
            isConnected = bootstrap.health.healthy
            serverVersion = bootstrap.health.version
            errorMessage = nil
            persistConfigAfterSuccessfulConnection()
            loadNewSessionDefaults()
            projects = bootstrap.projects
            selectedDirectory = directorySelection(for: bootstrap.currentProject)
            selectedProjectContentTab = .sessions
            reconcileCurrentProjectSelection(serverProject: bootstrap.currentProject)
            try await reloadSessions()
            await loadComposerOptions()
            streamDirectory = directoryState.sessions.first?.directory
            startEventStream()
            await runUITestBootstrapIfNeeded()
        } catch {
            stopEventStream()
            backendMode = .none
            isConnected = false
            directoryState = OpenCodeDirectoryState()
            errorMessage = error.localizedDescription
        }
    }

    func connect(to serverConfig: OpenCodeServerConfig) async {
        config = hydratedServerConfig(from: serverConfig)
        await connect()
    }

    func presentAddServerSheet() {
        config = OpenCodeServerConfig()
        errorMessage = nil
        savedServerEditorMode = .add
        isShowingAddServerSheet = true
    }

    func prepareToEditRecentServer(_ serverConfig: OpenCodeServerConfig) {
        config = hydratedServerConfig(from: serverConfig)
        errorMessage = nil
        savedServerEditorMode = .edit(originalServerID: serverConfig.recentServerID)
        isShowingAddServerSheet = true
    }

    func dismissAddServerSheet() {
        isShowingAddServerSheet = false
        savedServerEditorMode = .add
        errorMessage = nil
    }

    var isEditingSavedServer: Bool {
        if case .edit = savedServerEditorMode {
            return true
        }

        return false
    }

    var canSaveEditedServer: Bool {
        !isLoading && config.hasCredentials
    }

    func saveEditedServer() {
        guard case let .edit(originalServerID) = savedServerEditorMode else { return }
        errorMessage = nil
        upsertSavedServer(config: config, replacingServerID: originalServerID)
        dismissAddServerSheet()
    }

    func disconnect() {
        appleIntelligenceResponseTask?.cancel()
        stopAccessingActiveAppleIntelligenceWorkspace()
        currentAppleIntelligenceWorkspace = nil
        stopEventStream()
        backendMode = .none
        isConnected = false
        serverVersion = ""
        activeAppleIntelligenceWorkspaceID = nil
        projects = []
        currentProject = nil
        selectedDirectory = nil
        selectedProjectContentTab = .sessions
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

    func leaveAppleIntelligenceSession() {
        appleIntelligenceResponseTask?.cancel()
        stopAccessingActiveAppleIntelligenceWorkspace()
        currentAppleIntelligenceWorkspace = nil
        backendMode = .none
        activeAppleIntelligenceWorkspaceID = nil
        currentProject = nil
        selectedDirectory = nil
        selectedProjectContentTab = .sessions
        directoryState = OpenCodeDirectoryState()
        draftMessage = ""
        clearDraftAttachments()
        errorMessage = nil
    }

    func presentAppleIntelligenceFolderPicker() {
        errorMessage = nil
        isShowingAppleIntelligenceFolderPicker = true
    }

    func openAppleIntelligenceWorkspace(_ workspace: AppleIntelligenceWorkspaceRecord) async {
        do {
            let resolvedURL = try resolveAppleIntelligenceWorkspaceURL(workspace)
            guard (try resolvedURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw NSError(domain: "AppleIntelligence", code: 5, userInfo: [NSLocalizedDescriptionKey: "The saved Apple Intelligence folder is no longer available. Please pick it again."])
            }

            await openAppleIntelligenceWorkspace(workspace, resolvedURL: resolvedURL)
            return
        } catch {
            stopAccessingActiveAppleIntelligenceWorkspace()
            removeAppleIntelligenceWorkspace(workspace)
            errorMessage = error.localizedDescription
            isShowingAppleIntelligenceFolderPicker = true
            return
        }
    }

    func createAppleIntelligenceWorkspace(from directoryURL: URL) async {
        do {
            appleIntelligenceDebugPickedPath = directoryURL.path(percentEncoded: false)
            let importedURL = try materializeAppleIntelligenceWorkspace(from: directoryURL)
            try setActiveAppleIntelligenceWorkspaceURL(importedURL)

            let bookmarkData = try importedURL.bookmarkData(options: appleIntelligenceBookmarkCreationOptions, includingResourceValuesForKeys: nil, relativeTo: nil)
            let resolvedPath = importedURL.path(percentEncoded: false)
            let title = importedURL.lastPathComponent.isEmpty ? resolvedPath : importedURL.lastPathComponent
            let workspace = AppleIntelligenceWorkspaceRecord(
                id: "apple-workspace:\(UUID().uuidString)",
                title: title,
                bookmarkData: bookmarkData,
                lastKnownPath: resolvedPath,
                sessionID: "apple-session:\(UUID().uuidString)",
                messages: [],
                updatedAt: Date()
            )
            await openAppleIntelligenceWorkspace(workspace, resolvedURL: importedURL)
        } catch {
            stopAccessingActiveAppleIntelligenceWorkspace()
            errorMessage = error.localizedDescription
        }
    }

    func openAppleIntelligenceWorkspace(_ workspace: AppleIntelligenceWorkspaceRecord, resolvedURL: URL) async {
        do {
            try setActiveAppleIntelligenceWorkspaceURL(resolvedURL)
        } catch {
            stopAccessingActiveAppleIntelligenceWorkspace()
            errorMessage = error.localizedDescription
            return
        }

        appleIntelligenceResponseTask?.cancel()
        stopEventStream()
        backendMode = .appleIntelligence
        isConnected = false
        serverVersion = ""
        activeAppleIntelligenceWorkspaceID = workspace.id
        currentAppleIntelligenceWorkspace = AppleIntelligenceWorkspaceRecord(
            id: workspace.id,
            title: workspace.title,
            bookmarkData: workspace.bookmarkData,
            lastKnownPath: resolvedURL.path(percentEncoded: false),
            sessionID: workspace.sessionID,
            messages: workspace.messages,
            updatedAt: workspace.updatedAt
        )
        projects = []
        currentProject = workspace.project
        selectedDirectory = resolvedURL.path(percentEncoded: false)
        selectedProjectContentTab = .sessions
        streamDirectory = resolvedURL.path(percentEncoded: false)
        directoryState = OpenCodeDirectoryState(
            sessions: [workspace.session],
            selectedSession: workspace.session,
            messages: workspace.messages,
            commands: [],
            sessionStatuses: [workspace.session.id: "idle"]
        )
        draftTitle = ""
        draftMessage = ""
        clearDraftAttachments()
        errorMessage = nil
    }

    func setActiveAppleIntelligenceWorkspaceURL(_ url: URL) throws {
        stopAccessingActiveAppleIntelligenceWorkspace()
        let didAccess = url.startAccessingSecurityScopedResource()
        let fileExists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        if !didAccess && !fileExists {
            throw NSError(domain: "AppleIntelligence", code: 6, userInfo: [NSLocalizedDescriptionKey: "Unable to access the selected folder."])
        }

        activeAppleIntelligenceWorkspaceURL = url
        isAccessingActiveAppleIntelligenceWorkspace = didAccess
        appleIntelligenceDebugActivePath = url.path(percentEncoded: false)
    }

    func stopAccessingActiveAppleIntelligenceWorkspace() {
        if isAccessingActiveAppleIntelligenceWorkspace {
            activeAppleIntelligenceWorkspaceURL?.stopAccessingSecurityScopedResource()
        }
        activeAppleIntelligenceWorkspaceURL = nil
        isAccessingActiveAppleIntelligenceWorkspace = false
        appleIntelligenceDebugActivePath = ""
        appleIntelligenceDebugResolvedPath = ""
        appleIntelligenceDebugToolRootPath = ""
    }

    var appleIntelligenceBookmarkCreationOptions: URL.BookmarkCreationOptions {
#if os(macOS)
        return [.withSecurityScope]
#else
        return []
#endif
    }

    var appleIntelligenceBookmarkResolutionOptions: URL.BookmarkResolutionOptions {
#if os(macOS)
        return [.withSecurityScope]
#else
        return []
#endif
    }

    func materializeAppleIntelligenceWorkspace(from sourceURL: URL) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                sourceURL.stopAccessingSecurityScopedResource()
            }
        }

        let fileManager = FileManager.default
        let appSupport = try fileManager.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        let root = appSupport.appendingPathComponent("AppleIntelligenceWorkspaces", isDirectory: true)
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)

        let folderName = sourceURL.lastPathComponent.isEmpty ? "Workspace" : sourceURL.lastPathComponent
        let destination = root.appendingPathComponent("\(folderName)-\(UUID().uuidString)", isDirectory: true)
        try fileManager.copyItem(at: sourceURL, to: destination)
        appleIntelligenceDebugResolvedPath = destination.path(percentEncoded: false)
        return destination
    }

    func removeAppleIntelligenceWorkspace(_ workspace: AppleIntelligenceWorkspaceRecord) {
        appleIntelligenceRecentWorkspaces.removeAll { $0.id == workspace.id }
        persistAppleIntelligenceWorkspaces()

        if activeAppleIntelligenceWorkspaceID == workspace.id {
            leaveAppleIntelligenceSession()
        }
    }

    func persistAppleIntelligenceMessages() {
        guard var currentAppleIntelligenceWorkspace else { return }
        currentAppleIntelligenceWorkspace.messages = directoryState.messages
        currentAppleIntelligenceWorkspace.updatedAt = Date()
        if let selectedDirectory, !selectedDirectory.isEmpty {
            currentAppleIntelligenceWorkspace.lastKnownPath = selectedDirectory
        }
        self.currentAppleIntelligenceWorkspace = currentAppleIntelligenceWorkspace
    }

    func reconnectToSavedServer() async {
        guard hasSavedServer else { return }
        config = hydratedServerConfig(from: config)
        await connect()
    }

    func hydratedServerConfig(from serverConfig: OpenCodeServerConfig) -> OpenCodeServerConfig {
        guard serverConfig.password.isEmpty,
              let password = passwordStore.loadPassword(for: serverConfig.recentServerID) else {
            return serverConfig
        }

        return OpenCodeServerConfig(
            name: serverConfig.name,
            iconName: serverConfig.iconName,
            baseURL: serverConfig.baseURL,
            username: serverConfig.username,
            password: password
        )
    }

    func dismissSavedServerPrompt() {
        showSavedServerPrompt = false
    }

    func persistConfigAfterSuccessfulConnection() {
        switch savedServerEditorMode {
        case .add:
            upsertSavedServer(config: config)
        case let .edit(originalServerID):
            upsertSavedServer(config: config, replacingServerID: originalServerID)
        }
        savedServerEditorMode = .add
        showSavedServerPrompt = false
    }

    func loadRecentServerConfigs() -> [OpenCodeServerConfig] {
        if let data = UserDefaults.standard.data(forKey: StorageKey.recentServerConfigs),
           let savedServers = loadSavedServers(from: data) {
            return Array(savedServers.prefix(Self.maxRecentServerCount)).map { savedServer in
                let password = passwordStore.loadPassword(for: savedServer.recentServerID) ?? ""
                return savedServer.serverConfig(password: password)
            }
        }

        return []
    }

    private func loadSavedServers(from data: Data) -> [OpenCodeSavedServer]? {
        if let savedServers = try? JSONDecoder().decode([OpenCodeSavedServer].self, from: data) {
            return savedServers
        }

        guard let rawEntries = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else {
            return nil
        }

        let recoveredServers = rawEntries.compactMap { entry -> OpenCodeSavedServer? in
            guard JSONSerialization.isValidJSONObject(entry),
                  let entryData = try? JSONSerialization.data(withJSONObject: entry) else {
                return nil
            }

            return try? JSONDecoder().decode(OpenCodeSavedServer.self, from: entryData)
        }

        guard recoveredServers.isEmpty == false else { return nil }

        // Rewrite the cleaned payload so a single bad entry does not keep wiping recents on launch.
        if let cleanedData = try? JSONEncoder().encode(recoveredServers) {
            UserDefaults.standard.set(cleanedData, forKey: StorageKey.recentServerConfigs)
        }

        return recoveredServers
    }

    func loadAppleIntelligenceWorkspaces() -> [AppleIntelligenceWorkspaceRecord] {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.appleIntelligenceWorkspaces),
              let workspaces = try? JSONDecoder().decode([AppleIntelligenceWorkspaceRecord].self, from: data) else {
            return []
        }

        return workspaces.sorted { $0.updatedAt > $1.updatedAt }
    }

    func persistAppleIntelligenceWorkspaces() {
        guard let data = try? JSONEncoder().encode(appleIntelligenceRecentWorkspaces) else { return }
        UserDefaults.standard.set(data, forKey: StorageKey.appleIntelligenceWorkspaces)
    }

    func removeRecentServer(_ serverConfig: OpenCodeServerConfig) {
        recentServerConfigs.removeAll { $0.recentServerID == serverConfig.recentServerID }
        hasSavedServer = recentServerConfigs.isEmpty == false
        showSavedServerPrompt = hasSavedServer && showSavedServerPrompt

        if config.recentServerID == serverConfig.recentServerID,
           let replacement = recentServerConfigs.first {
            config = replacement
        }

        if recentServerConfigs.isEmpty {
            UserDefaults.standard.removeObject(forKey: StorageKey.recentServerConfigs)
            passwordStore.deletePassword(for: serverConfig.recentServerID)
            return
        }

        passwordStore.deletePassword(for: serverConfig.recentServerID)

        let savedServers = recentServerConfigs.map(OpenCodeSavedServer.init)
        guard let recentData = try? JSONEncoder().encode(savedServers) else {
            return
        }

        UserDefaults.standard.set(recentData, forKey: StorageKey.recentServerConfigs)
    }

    private func upsertSavedServer(config: OpenCodeServerConfig, replacingServerID originalServerID: String? = nil) {
        guard config.hasCredentials else { return }

        let updatedConfig = config
        let updatedID = updatedConfig.recentServerID
        let replacedConfig = originalServerID.flatMap { originalID in
            recentServerConfigs.first { $0.recentServerID == originalID }
        }
        let migratedPassword: String?
        if let replacedConfig, replacedConfig.recentServerID != updatedID, updatedConfig.password.isEmpty {
            migratedPassword = passwordStore.loadPassword(for: replacedConfig.recentServerID) ?? replacedConfig.password
        } else {
            migratedPassword = nil
        }

        var orderedConfigs = [updatedConfig]
        orderedConfigs.append(contentsOf: recentServerConfigs.filter { existing in
            if existing.recentServerID == updatedID {
                return false
            }

            if let originalServerID, existing.recentServerID == originalServerID {
                return false
            }

            return true
        })

        recentServerConfigs = Array(orderedConfigs.prefix(Self.maxRecentServerCount))
        hasSavedServer = recentServerConfigs.isEmpty == false

        if let originalServerID, originalServerID != updatedID {
            passwordStore.deletePassword(for: originalServerID)
        }

        if let migratedPassword, migratedPassword.isEmpty == false {
            passwordStore.savePassword(migratedPassword, for: updatedID)
                if recentServerConfigs.first?.recentServerID == updatedID {
                    recentServerConfigs[0].password = migratedPassword
                }
        }

        for serverConfig in recentServerConfigs {
            passwordStore.savePassword(serverConfig.password, for: serverConfig.recentServerID)
        }

        persistRecentServers()
    }

    private func persistRecentServers() {
        let savedServers = recentServerConfigs.map(OpenCodeSavedServer.init)
        guard let recentData = try? JSONEncoder().encode(savedServers) else {
            return
        }

        UserDefaults.standard.set(recentData, forKey: StorageKey.recentServerConfigs)
    }

    func configureUITestEnvironmentIfNeeded() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCODE_UI_TEST_MODE"] == "1" else {
            return false
        }

        UserDefaults.standard.removeObject(forKey: StorageKey.recentServerConfigs)
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
