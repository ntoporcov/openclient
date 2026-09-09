import Foundation

#if canImport(FoundationModels)
import FoundationModels
#endif

extension AppViewModel {
    private static let maxRecentAppleIntelligenceWorkspaceCount = 4
    private static let minimumConnectionOverlayDuration: TimeInterval = 2.0
    private static let automaticConnectionRetryDelays = [2, 5, 10, 30]

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
                    return String(localized: "Requires an Apple Intelligence-capable device.")
                case .appleIntelligenceNotEnabled:
                    return String(localized: "Turn on Apple Intelligence to try the on-device demo.")
                case .modelNotReady:
                    return String(localized: "Apple Intelligence is still preparing on this device.")
                @unknown default:
                    return String(localized: "Apple Intelligence is unavailable on this device right now.")
                }
            }
        }
#endif
        return String(localized: "Requires a device that supports Apple Intelligence.")
    }

    func connect() async {
        connectionAttemptTask?.cancel()
        connectionAttemptTask = nil
        let attemptID = UUID()
        connectionAttemptID = attemptID
        await connect(attemptID: attemptID)
        guard connectionAttemptID == attemptID else { return }
        if isShowingConnectionOverlay {
            await finishConnectionOverlayAfterAttempt(attemptID: attemptID)
        } else {
            connectionAttemptID = nil
        }
    }

    private func connect(attemptID: UUID) async {
        guard isCurrentConnectionAttempt(attemptID), Task.isCancelled == false else { return }
        liveActivityFacade.connectionWillStart(config: config)
        let wasBrowsingLocalCache = backendMode == .cachedServer
        stopEventStream()
        backendConnection?.close()
        backendConnection = nil
        terminalFacade.resetForConnectionChange()
        projectStore.defaultServerDirectory = nil
        projectStore.resetWorktreeInventory()
        sessionListStore.resetWorkspacePages()
        connectionStore.beginConnecting()
        resetRecentProjectSessionsForConnectionChange()
        resetLocalCacheRuntimeState()
        let cacheServerID = config.recentServerID
        let cachedProjects: OpenCodeCachedProjectsSnapshot? = if backendFactory == nil && config.apiPreference == .legacy {
            await loadCachedProjectsIfEnabled()
        } else {
            nil
        }
        guard isCurrentConnectionAttempt(attemptID) else { return }
        guard Task.isCancelled == false, config.recentServerID == cacheServerID else {
            liveActivityFacade.discardPendingDeepLink()
            connectionStore.applyConnectionCancellation()
            return
        }
        if let cachedProjects {
            projects = projectCoordinator.bootstrapProjects(cachedProjects.projects, currentProject: nil)
        }
        var didLoadBootstrapCatalog = false
        var didPersistConfig = true
        await connectionCoordinator.connect(
            factory: backendFactory ?? OpenCodeBackendFactory(client: OpenCodeAPIClient(config: config), eventManager: eventManager),
            isCurrentAttempt: { [weak self] in
                self?.isCurrentConnectionAttempt(attemptID) == true
            },
            applyConnection: { connection in
                guard self.isCurrentConnectionAttempt(attemptID), Task.isCancelled == false else { return }
                backendConnection = connection
                if connection.openCodeCompatibility == nil {
                    directoryStoreRegistry.reset()
                    modelConfigurationStore.reset()
                    projects = []
                    currentProject = nil
                    selectedDirectory = nil
                    selectedProjectContentTab = .sessions
                    streamDirectory = nil
                    let snapshot = try await connection.projects.projectsSnapshot()
                    try Task.checkCancellation()
                    guard self.isCurrentConnectionAttempt(attemptID), self.isCurrentBackendConnection(connection) else { return }
                    projects = snapshot.projects
                    projectStore.defaultServerDirectory = snapshot.defaultDirectory
                    let catalog = try await connection.models.modelCatalog(scope: .init())
                    try Task.checkCancellation()
                    guard self.isCurrentConnectionAttempt(attemptID), self.isCurrentBackendConnection(connection) else { return }
                    modelConfigurationStore.applyComposerOptions(agents: catalog.agents, providers: catalog.providers, defaults: catalog.defaults)
                    return
                }
                if connection.openCodeCompatibility?.profile == .legacy {
                    let bootstrap = try await connection.projects.projectsSnapshot()
                    try Task.checkCancellation()
                    guard self.isCurrentConnectionAttempt(attemptID), self.isCurrentBackendConnection(connection) else { return }
                    didPersistConfig = persistConfigAfterSuccessfulConnection()
                    loadNewSessionDefaults()
                    loadFunAndGamesPreferences()
                    projects = projectCoordinator.bootstrapProjects(bootstrap.projects, currentProject: bootstrap.currentProject)
                    persistProjectsToLocalCache()
                    currentProject = nil
                    selectedDirectory = nil
                    selectedProjectContentTab = .sessions
                    directoryStoreRegistry.reset()
                    streamDirectory = nil
                    loadProjectListPreferences()
                    connectionCoordinator.updateConnectionPhase(.preparingInterface)
                    didLoadBootstrapCatalog = await loadComposerOptions()
                    guard self.isCurrentConnectionAttempt(attemptID), Task.isCancelled == false else { return }
                    connectionCoordinator.updateConnectionPhase(.startingLiveUpdates)
                    startEventStream()
                    await runUITestBootstrapIfNeeded()
                } else {
                    guard self.isCurrentConnectionAttempt(attemptID), Task.isCancelled == false else { return }
                    stopEventStream()
                    projects = []
                    currentProject = nil
                    selectedDirectory = nil
                    selectedProjectContentTab = .sessions
                    projectSearchQuery = ""
                    projectSearchResults = []
                    projectSessionSearchQuery = ""
                    resetRecentProjectSessionsForConnectionChange()
                    directoryStoreRegistry.reset()
                    modelConfigurationStore.reset()
                    streamDirectory = nil
                    try Task.checkCancellation()
                    guard self.isCurrentConnectionAttempt(attemptID), self.isCurrentBackendConnection(connection) else { return }
                    if let cached = await loadCachedProjectsIfEnabled() {
                        projects = cached.projects
                    }
                    guard self.isCurrentConnectionAttempt(attemptID), self.isCurrentBackendConnection(connection) else { return }
                    let bootstrap = try await connection.projects.projectsSnapshot()
                    try Task.checkCancellation()
                    guard self.isCurrentConnectionAttempt(attemptID), self.isCurrentBackendConnection(connection) else { return }
                    projects = bootstrap.projects
                    projectStore.defaultServerDirectory = bootstrap.defaultDirectory
                    persistProjectsToLocalCache()
                    didLoadBootstrapCatalog = await loadComposerOptions()
                    try Task.checkCancellation()
                    guard self.isCurrentConnectionAttempt(attemptID) else { return }
                    loadFunAndGamesPreferences()
                    loadProjectListPreferences()
                    didPersistConfig = persistConfigAfterSuccessfulConnection()
                }
            },
            handleFailure: {
                guard self.isCurrentConnectionAttempt(attemptID) else { return }
                liveActivityFacade.discardPendingDeepLink()
                stopEventStream()
                backendConnection?.close()
                backendConnection = nil
                if wasBrowsingLocalCache == false {
                    directoryStoreRegistry.reset()
                }
            }
        )
        guard isCurrentConnectionAttempt(attemptID), Task.isCancelled == false else { return }
        if !isConnected, backendFactory == nil, config.apiPreference == .legacy, wasBrowsingLocalCache, usesLocalCache {
            connectionStore.applyCachedServerConnection(preservingError: wasBrowsingLocalCache)
        } else if !isConnected,
                  backendFactory == nil,
                  config.apiPreference == .legacy,
                  cachedProjects?.projects.isEmpty == false,
                  usesLocalCache {
            connectionStore.offerCachedServerConnection()
        }
        guard isCurrentConnectionAttempt(attemptID), Task.isCancelled == false else { return }
        if isConnected {
            // Both profiles restore the OS inventory under the newly established connection lifetime.
            if backendConnection?.isClosed == false { reconcileLiveActivities() }
            scheduleWidgetSnapshotPublication(includeModelOptions: true)
            globalFormsFacade.request(nil)
            if backendConnection?.openCodeCompatibility == nil {
                startEventStream()
            } else if connectionStore.apiProfile == .v2 {
                startV2EventStream()
            } else {
                beginRecentProjectSessionsLoadingIfPossible()
            }
            automaticConnectionRetryAttempt = 0
            cancelAutomaticConnectionRetryTask()
            await widgetSnapshotPublisher.publishNow(includeModelOptions: true,
                commandsAreAuthoritative: didLoadBootstrapCatalog && backendConnection?.capabilities.contains(.commands) == true,
                modelsAreAuthoritative: didLoadBootstrapCatalog)
        } else {
            liveActivityFacade.discardPendingDeepLink()
            scheduleAutomaticConnectionRetryIfNeeded()
        }
        guard isCurrentConnectionAttempt(attemptID), !Task.isCancelled else { return }
        await liveActivityFacade.resumePendingDeepLink()
        if isCurrentConnectionAttempt(attemptID), isConnected, !didPersistConfig {
            connectionStore.applyErrorMessage(OpenCodeSavedServer.PersistenceError.credentialsUnavailable.localizedDescription)
        }
    }

    func startConnection() {
        cancelAutomaticConnectionRetryTask()
        connectionAttemptTask?.cancel()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        isShowingAddServerSheet = false
        connectionOverlayStartedAt = Date()
        isShowingConnectionOverlay = true
        connectionAttemptTask = Task { [weak self] in
            guard let self else { return }
            await self.connect(attemptID: attemptID)
            guard self.connectionAttemptID == attemptID else { return }
            self.connectionAttemptTask = nil
            await self.finishConnectionOverlayAfterAttempt(attemptID: attemptID)
        }
    }

    func retryCachedServerConnection() {
        guard backendMode == .cachedServer else { return }
        if let savedServer = recentServerConfigs.first(where: { $0.recentServerID == config.recentServerID }) {
            config = hydratedServerConfig(from: savedServer)
        }
        appendDebugLog("cached server retry requested server=\(config.recentServerID)")
        startConnection()
    }

    func retryOfferedServerConnection() {
        guard connectionStore.isOfferingCachedServerConnection else { return }
        startConnection()
    }

    func browseDownloadedServerData() {
        guard connectionStore.isOfferingCachedServerConnection else { return }
        stopAutomaticConnectionRetries()
        connectionStore.applyCachedServerConnection()
    }

    func dismissCachedServerConnectionOffer() {
        guard connectionStore.isOfferingCachedServerConnection else { return }
        stopAutomaticConnectionRetries()
        connectionStore.dismissCachedServerConnectionOffer()
    }

    private func finishConnectionOverlayAfterAttempt(attemptID: UUID) async {
        guard connectionAttemptID == attemptID else { return }
        if isConnected {
            let elapsed = connectionOverlayStartedAt.map { Date().timeIntervalSince($0) } ?? Self.minimumConnectionOverlayDuration
            let remaining = max(0, Self.minimumConnectionOverlayDuration - elapsed)
            if remaining > 0 {
                try? await Task.sleep(for: .milliseconds(Int(remaining * 1_000)))
            }
        }

        await MainActor.run { [weak self] in
            guard let self else { return }
            guard self.connectionAttemptID == attemptID, self.connectionAttemptTask == nil else { return }
            self.connectionAttemptID = nil
            self.connectionOverlayStartedAt = nil
            self.isShowingConnectionOverlay = false
        }
    }

    private func isCurrentConnectionAttempt(_ attemptID: UUID) -> Bool {
        connectionAttemptID == attemptID
    }

    func connect(to serverConfig: OpenCodeServerConfig) async {
        stopAutomaticConnectionRetries()
        config = hydratedServerConfig(from: serverConfig)
        await connect()
    }

    func startConnection(to serverConfig: OpenCodeServerConfig) {
        stopAutomaticConnectionRetries()
        config = hydratedServerConfig(from: serverConfig)
        startConnection()
    }

    @discardableResult
    func startAutomaticConnectionIfConfigured() -> Bool {
        guard backendFactory == nil, !hasAttemptedAutomaticConnection else { return false }

        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCODE_UI_TEST_MODE"] != "1",
              environment["OPENCLIENT_SCREENSHOT_SCENE"] == nil,
              !isConnected,
              backendMode == .none || backendMode == .cachedServer,
              let server = appCustomizationStore.autoConnectServer(in: recentServerConfigs) else { return false }
        hasAttemptedAutomaticConnection = true
        automaticConnectionRetryEnabled = true
        automaticConnectionRetryAttempt = 0
        config = hydratedServerConfig(from: server)
        startConnection()
        return true
    }

    func applicationActivityChanged(isActive: Bool) {
        isApplicationActive = isActive
        guard isActive else {
            chatFacade.foregroundChatRefreshCoordinator.invalidate()
            foregroundChatCatchUpTask = nil
            cancelAutomaticConnectionRetryTask()
            return
        }
        guard hasAttemptedAutomaticConnection else { return }
        scheduleAutomaticConnectionRetryIfNeeded(immediate: true)
    }

    private func scheduleAutomaticConnectionRetryIfNeeded(immediate: Bool = false) {
        guard automaticConnectionRetryTask == nil, canAutomaticallyRetryConnection else { return }
        automaticConnectionRetryGeneration &+= 1
        let generation = automaticConnectionRetryGeneration
        automaticConnectionRetryTask = Task { [weak self] in
            guard let self else { return }
            var retriesImmediately = immediate

            while self.automaticConnectionRetryGeneration == generation,
                  self.canAutomaticallyRetryConnection {
                if retriesImmediately {
                    await Task.yield()
                    retriesImmediately = false
                } else {
                    let index = min(self.automaticConnectionRetryAttempt, Self.automaticConnectionRetryDelays.count - 1)
                    do {
                        try await Task.sleep(for: .seconds(Self.automaticConnectionRetryDelays[index]))
                    } catch {
                        break
                    }
                }

                guard self.automaticConnectionRetryGeneration == generation,
                      self.canAutomaticallyRetryConnection,
                      self.connectionAttemptID == nil,
                      let server = self.appCustomizationStore.autoConnectServer(in: self.recentServerConfigs) else { break }

                self.config = self.hydratedServerConfig(from: server)
                await self.connect()
                guard self.isConnected == false else { break }
                self.automaticConnectionRetryAttempt += 1
            }

            if self.automaticConnectionRetryGeneration == generation {
                self.automaticConnectionRetryTask = nil
            }
        }
    }

    private var canAutomaticallyRetryConnection: Bool {
        let environment = ProcessInfo.processInfo.environment
        return automaticConnectionRetryEnabled
            && isApplicationActive
            && isConnected == false
            && isLoading == false
            && connectionStore.isOfferingCachedServerConnection == false
            && backendMode != .appleIntelligence
            && environment["OPENCODE_UI_TEST_MODE"] != "1"
            && environment["OPENCLIENT_SCREENSHOT_SCENE"] == nil
            && appCustomizationStore.autoConnectServer(in: recentServerConfigs) != nil
    }

    private func cancelAutomaticConnectionRetryTask() {
        automaticConnectionRetryGeneration &+= 1
        automaticConnectionRetryTask?.cancel()
        automaticConnectionRetryTask = nil
    }

    private func stopAutomaticConnectionRetries() {
        automaticConnectionRetryEnabled = false
        automaticConnectionRetryAttempt = 0
        cancelAutomaticConnectionRetryTask()
    }

    func cancelConnectionAttempt() {
        liveActivityFacade.discardPendingDeepLink()
        stopAutomaticConnectionRetries()
        connectionAttemptID = nil
        connectionAttemptTask?.cancel()
        connectionAttemptTask = nil
        connectionOverlayStartedAt = nil
        isShowingConnectionOverlay = false
        stopEventStream()
        backendConnection?.close()
        backendConnection = nil
        directoryStoreRegistry.reset()
        resetRecentProjectSessionsForConnectionChange()
        connectionStore.applyConnectionCancellation()
    }

    func presentAddServerSheet() {
        stopAutomaticConnectionRetries()
        config = OpenCodeServerConfig()
        connectionStore.prepareAddServerSheet()
        isShowingAddServerSheet = true
    }

    func prepareToEditRecentServer(_ serverConfig: OpenCodeServerConfig) {
        stopAutomaticConnectionRetries()
        config = hydratedServerConfig(from: serverConfig)
        connectionStore.prepareEditServerSheet(originalServerID: serverConfig.recentServerID)
        isShowingAddServerSheet = true
    }

    func dismissAddServerSheet() {
        isShowingAddServerSheet = false
        connectionStore.dismissServerSheet()
    }

    var isEditingSavedServer: Bool {
        if case .edit = savedServerEditorMode {
            return true
        }

        return false
    }

    var canSaveEditedServer: Bool {
        !isLoading && config.hasRequiredConnectionFields
    }

    func saveEditedServer() {
        guard case let .edit(originalServerID) = savedServerEditorMode else { return }
        if let validationMessage = config.connectionValidationMessage {
            connectionStore.applyErrorMessage(validationMessage)
            return
        }
        connectionStore.clearError()
        guard upsertSavedServer(config: config, replacingServerID: originalServerID) else { return }
        dismissAddServerSheet()
    }

    func startConnectionFromEditor() {
        config = config.publicConnectionConfig
        if backendFactory != nil {
            startConnection()
            return
        }
        if let validationMessage = config.connectionValidationMessage {
            connectionStore.applyErrorMessage(validationMessage)
            return
        }
        stopAutomaticConnectionRetries()
        startConnection()
    }

    func disconnect() {
        liveActivityFacade.discardPendingDeepLink()
        terminalFacade.resetForConnectionChange()
        projectStore.defaultServerDirectory = nil
        projectStore.resetWorktreeInventory()
        sessionListStore.resetWorkspacePages()
        stopAutomaticConnectionRetries()
        connectionAttemptID = nil
        connectionAttemptTask?.cancel()
        connectionAttemptTask = nil
        appleIntelligenceResponseTask?.cancel()
        resetRecentProjectSessionsForConnectionChange()
        resetLocalCacheRuntimeState()
        connectionCoordinator.disconnect(
            hasSavedServer: hasSavedServer,
            stopActiveWorkspace: {
                stopAccessingActiveAppleIntelligenceWorkspace()
                currentAppleIntelligenceWorkspace = nil
            },
            stopEventStream: {
                stopEventStream()
                backendConnection?.close()
                backendConnection = nil
            },
            resetAppState: {
                activeAppleIntelligenceWorkspaceID = nil
                projects = []
                currentProject = nil
                selectedDirectory = nil
                selectedProjectContentTab = .sessions
                projectSearchQuery = ""
                projectSearchResults = []
                directoryStoreRegistry.reset()
                modelConfigurationStore.reset()
                funAndGamesPreferences = FunAndGamesPreferences()
                findPlaceSessionsByID = [:]
                findBugSessionsByID = [:]
                pendingFindBugLanguage = nil
            }
        )
    }

    func leaveAppleIntelligenceSession() {
        appleIntelligenceResponseTask?.cancel()
        connectionCoordinator.leaveAppleIntelligenceSession(
            preserveDraft: {
                preserveCurrentMessageDraftForNavigation()
            },
            stopActiveWorkspace: {
                stopAccessingActiveAppleIntelligenceWorkspace()
                currentAppleIntelligenceWorkspace = nil
            },
            resetAppState: {
                activeAppleIntelligenceWorkspaceID = nil
                currentProject = nil
                selectedDirectory = nil
                selectedProjectContentTab = .sessions
                directoryStoreRegistry.reset()
            },
            clearComposer: {
                objectWillChange.send()
                composerStore.resetActiveDraft()
            }
        )
    }

    func presentAppleIntelligenceFolderPicker() {
        connectionStore.clearError()
        isShowingAppleIntelligenceFolderPicker = true
    }

    func openAppleIntelligenceWorkspace(_ workspace: AppleIntelligenceWorkspaceRecord) async {
        do {
            let resolvedURL = try resolveAppleIntelligenceWorkspaceURL(workspace)
            guard (try resolvedURL.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else {
                throw NSError(domain: "AppleIntelligence", code: 5, userInfo: [NSLocalizedDescriptionKey: String(localized: "The saved Apple Intelligence folder is no longer available. Please pick it again.")])
            }

            await openAppleIntelligenceWorkspace(workspace, resolvedURL: resolvedURL)
            return
        } catch {
            stopAccessingActiveAppleIntelligenceWorkspace()
            removeAppleIntelligenceWorkspace(workspace)
            connectionStore.applyErrorMessage(error.localizedDescription)
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
            connectionStore.applyErrorMessage(error.localizedDescription)
        }
    }

    func openAppleIntelligenceWorkspace(_ workspace: AppleIntelligenceWorkspaceRecord, resolvedURL: URL) async {
        do {
            try setActiveAppleIntelligenceWorkspaceURL(resolvedURL)
        } catch {
            stopAccessingActiveAppleIntelligenceWorkspace()
            connectionStore.applyErrorMessage(error.localizedDescription)
            return
        }

        appleIntelligenceResponseTask?.cancel()
        stopAutomaticConnectionRetries()
        stopEventStream()
        backendConnection?.close()
        backendConnection = nil
        connectionStore.applyAppleIntelligenceMode()
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
        allSessions = [workspace.session]
        selectedSession = workspace.session
        directoryCommands = []
        sessionStatuses = [workspace.session.id: "idle"]
        messages = workspace.messages
        upsertAppleIntelligenceWorkspace(currentAppleIntelligenceWorkspace ?? workspace)
        draftTitle = ""
        restoreMessageDraft(for: workspace.session)
    }

    func setActiveAppleIntelligenceWorkspaceURL(_ url: URL) throws {
        stopAccessingActiveAppleIntelligenceWorkspace()
        let didAccess = url.startAccessingSecurityScopedResource()
        let fileExists = FileManager.default.fileExists(atPath: url.path(percentEncoded: false))
        if !didAccess && !fileExists {
            throw NSError(domain: "AppleIntelligence", code: 6, userInfo: [NSLocalizedDescriptionKey: String(localized: "Unable to access the selected folder.")])
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
        currentAppleIntelligenceWorkspace.messages = messages
        currentAppleIntelligenceWorkspace.updatedAt = Date()
        if let selectedDirectory, !selectedDirectory.isEmpty {
            currentAppleIntelligenceWorkspace.lastKnownPath = selectedDirectory
        }
        self.currentAppleIntelligenceWorkspace = currentAppleIntelligenceWorkspace
        upsertAppleIntelligenceWorkspace(currentAppleIntelligenceWorkspace)
    }

    func upsertAppleIntelligenceWorkspace(_ workspace: AppleIntelligenceWorkspaceRecord) {
        appleIntelligenceRecentWorkspaces.removeAll { $0.id == workspace.id }
        appleIntelligenceRecentWorkspaces.insert(workspace, at: 0)
        if appleIntelligenceRecentWorkspaces.count > Self.maxRecentAppleIntelligenceWorkspaceCount {
            appleIntelligenceRecentWorkspaces = Array(appleIntelligenceRecentWorkspaces.prefix(Self.maxRecentAppleIntelligenceWorkspaceCount))
        }
        persistAppleIntelligenceWorkspaces()
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
            password: password,
            apiPreference: serverConfig.apiPreference
        )
    }

    func dismissSavedServerPrompt() {
        connectionStore.markSavedServerPromptDismissed()
    }

    @discardableResult
    func persistConfigAfterSuccessfulConnection() -> Bool {
        switch savedServerEditorMode {
        case .add:
            guard upsertSavedServer(config: config) else { return false }
        case let .edit(originalServerID):
            guard upsertSavedServer(config: config, replacingServerID: originalServerID) else { return false }
        }
        connectionStore.markSavedServerPersistenceComplete()
        return true
    }

    func loadRecentServerConfigs() -> [OpenCodeServerConfig] {
        OpenCodeSavedServer.loadPublicSavedServers().map { savedServer in
            let password = passwordStore.loadPassword(for: savedServer.recentServerID) ?? ""
            return savedServer.serverConfig(password: password)
        }
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
        let removedServerID = serverConfig.recentServerID
        guard persistSavedServerChange(.remove(removedServerID)) else { return }
        connectionStore.removeRecentServer(serverConfig)
        Task {
            await clearLocalCache(serverID: removedServerID)
        }
        appCustomizationStore.reconcileAutoConnectServer(in: recentServerConfigs)

        if config.recentServerID == serverConfig.recentServerID,
           let replacement = recentServerConfigs.first {
            config = replacement
        }
    }

    private func upsertSavedServer(config: OpenCodeServerConfig, replacingServerID originalServerID: String? = nil) -> Bool {
        guard config.hasRequiredConnectionFields,
              persistSavedServerChange(.save(config, replacingServerID: originalServerID)) else { return false }
        let updatedID = config.recentServerID
        if let originalServerID, originalServerID != updatedID {
            appCustomizationStore.migrateAutoConnectServerID(from: originalServerID, to: updatedID)
        }
        appCustomizationStore.reconcileAutoConnectServer(in: recentServerConfigs)
        if let originalServerID, originalServerID != updatedID {
            Task {
                await clearLocalCache(serverID: originalServerID)
            }
        }

        return true
    }

    private func persistSavedServerChange(_ change: OpenCodeSavedServer.Change) -> Bool {
        do {
            let configs = try OpenCodeSavedServer.persistPublicSavedServers(recentServerConfigs, change: change)
            connectionStore.setRecentServerConfigs(configs)
            connectionStore.clearError()
            return true
        } catch {
            connectionStore.applyErrorMessage(OpenCodeSavedServer.PersistenceError.credentialsUnavailable.localizedDescription)
            return false
        }
    }

    func configureUITestEnvironmentIfNeeded() -> Bool {
        let environment = ProcessInfo.processInfo.environment
        guard environment["OPENCODE_UI_TEST_MODE"] == "1" else {
            return false
        }

        UserDefaults.standard.removeObject(forKey: StorageKey.recentServerConfigs)
        OpenClientSharePayloadStore.mirrorRecentServersData(nil)
        config.name = environment["OPENCODE_UI_TEST_SERVER_NAME"] ?? "UI Test Server"
        config.baseURL = environment["OPENCODE_UI_TEST_BASE_URL"] ?? "http://127.0.0.1:4096"
        config.username = environment["OPENCODE_UI_TEST_USERNAME"] ?? "opencode"
        config.password = environment["OPENCODE_UI_TEST_PASSWORD"] ?? ""
        uiTestBootstrapTitle = environment["OPENCODE_UI_TEST_SESSION_TITLE"]
        uiTestBootstrapPrompt = environment["OPENCODE_UI_TEST_PROMPT"]
        uiTestDirectory = environment["OPENCODE_UI_TEST_DIRECTORY"]
        connectionStore.clearRecentServers()
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
            selectedSession = session
            restoreMessageDraft(for: session)
            try await loadMessages(for: session)
            try await client.sendMessageAsync(sessionID: session.id, text: prompt, directory: sendDirectory(for: session))
            try await loadMessages(for: session)
            try await reloadSessions()
            upsertVisibleSession(session)
        } catch {
            connectionStore.applyErrorMessage(error.localizedDescription)
        }
    }
}
