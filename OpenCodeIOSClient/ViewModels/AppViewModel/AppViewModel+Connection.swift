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
            persistConfig()
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
        config = serverConfig
        await connect()
    }

    func prepareToEditRecentServer(_ serverConfig: OpenCodeServerConfig) {
        config = serverConfig
        errorMessage = nil
        showSavedServerPrompt = false
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
        await connect()
    }

    func dismissSavedServerPrompt() {
        showSavedServerPrompt = false
    }

    func persistConfig() {
        let recentConfigs = ([config] + recentServerConfigs)
            .reduce(into: [OpenCodeServerConfig]()) { deduped, serverConfig in
                guard serverConfig.hasCredentials else { return }
                guard deduped.contains(where: { $0.recentServerID == serverConfig.recentServerID }) == false else { return }
                deduped.append(serverConfig)
            }

        recentServerConfigs = Array(recentConfigs.prefix(Self.maxRecentServerCount))
        hasSavedServer = recentServerConfigs.isEmpty == false
        showSavedServerPrompt = false

        guard let latestConfig = recentServerConfigs.first,
              let latestData = try? JSONEncoder().encode(latestConfig),
              let recentData = try? JSONEncoder().encode(recentServerConfigs) else {
            return
        }

        UserDefaults.standard.set(latestData, forKey: StorageKey.lastServerConfig)
        UserDefaults.standard.set(recentData, forKey: StorageKey.recentServerConfigs)
    }

    func loadSavedConfig() -> OpenCodeServerConfig? {
        guard let data = UserDefaults.standard.data(forKey: StorageKey.lastServerConfig) else {
            return nil
        }

        return try? JSONDecoder().decode(OpenCodeServerConfig.self, from: data)
    }

    func loadRecentServerConfigs() -> [OpenCodeServerConfig] {
        if let data = UserDefaults.standard.data(forKey: StorageKey.recentServerConfigs),
           let configs = try? JSONDecoder().decode([OpenCodeServerConfig].self, from: data) {
            return Array(configs.prefix(Self.maxRecentServerCount))
        }

        if let savedConfig = loadSavedConfig() {
            return [savedConfig]
        }

        return []
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
            UserDefaults.standard.removeObject(forKey: StorageKey.lastServerConfig)
            UserDefaults.standard.removeObject(forKey: StorageKey.recentServerConfigs)
            return
        }

        guard let latestData = try? JSONEncoder().encode(recentServerConfigs[0]),
              let recentData = try? JSONEncoder().encode(recentServerConfigs) else {
            return
        }

        UserDefaults.standard.set(latestData, forKey: StorageKey.lastServerConfig)
        UserDefaults.standard.set(recentData, forKey: StorageKey.recentServerConfigs)
    }

    func configureUITestEnvironmentIfNeeded() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCODE_UI_TEST_MODE"] == "1" else {
            return false
        }

        UserDefaults.standard.removeObject(forKey: StorageKey.lastServerConfig)
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
