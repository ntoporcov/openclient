import Combine
import Foundation

struct OpenClientShareDeepLink: Equatable, Sendable {
    let payloadID: String
    let serverID: String?

    init?(url: URL) {
        guard url.scheme == "openclient", url.host() == "share",
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let payloadID = components.queryItems?.first(where: { $0.name == "id" })?.value,
              !payloadID.isEmpty else {
            return nil
        }
        self.payloadID = payloadID
        self.serverID = components.queryItems?.first(where: { $0.name == "server" })?.value
    }
}

@MainActor
final class OpenClientDeepLinkRoutingStore {
    struct PendingWidgetSession {
        let id = UUID()
        let request: OpenCodeWidgetDeepLink.Request
    }

    private(set) var pendingWidgetSession: PendingWidgetSession?
    var allowsAutomaticConnection: Bool { pendingWidgetSession == nil }

    @discardableResult
    func replacePendingWidgetSession(_ request: OpenCodeWidgetDeepLink.Request) -> UUID {
        let pending = PendingWidgetSession(request: request)
        pendingWidgetSession = pending
        return pending.id
    }

    func consumePendingWidgetSession(id: UUID) {
        guard pendingWidgetSession?.id == id else { return }
        pendingWidgetSession = nil
    }

    func connectionWillStart(config: OpenCodeServerConfig) {
        guard let pending = pendingWidgetSession else { return }
        let targetID = pending.request.serverID ?? config.recentServerID
        guard targetID == config.recentServerID,
              config.apiPreference == .automatic
                || config.apiPreference.rawValue == pending.request.profile.rawValue else {
            pendingWidgetSession = nil
            return
        }
    }

    func discardPendingRoutes() {
        pendingWidgetSession = nil
    }
}

extension AppViewModel {
    func prepareOpenURLPresentation(_ url: URL) {
        if let shareRequest = OpenClientShareDeepLink(url: url) {
            deepLinkRoutingStore.discardPendingRoutes()
            newProjectChatFacade.prepareShare(shareRequest)
            return
        }

        if let request = OpenCodeWidgetDeepLink.request(from: url),
           case .session = request.kind,
           savedWidgetDeepLinkServer(serverID: request.serverID, profile: request.profile) != nil {
            deepLinkRoutingStore.replacePendingWidgetSession(request)
            return
        }

        // Widget destinations must be verified before exposing an editable composer.
    }

    func handleOpenURL(_ url: URL) async {
        if let shareRequest = OpenClientShareDeepLink(url: url) {
            deepLinkRoutingStore.discardPendingRoutes()
            await handleShareDeepLink(shareRequest)
            return
        }

        if let widgetRequest = OpenCodeWidgetDeepLink.request(from: url) {
            switch widgetRequest.kind {
            case .session:
                // The synchronous presentation pass may already have reserved this route before
                // RootView's launch task had an opportunity to start automatic connection.
                break
            default:
                deepLinkRoutingStore.discardPendingRoutes()
            }
            await handleWidgetDeepLink(widgetRequest)
            return
        }

        deepLinkRoutingStore.discardPendingRoutes()

        if url.scheme == OpenCodeWidgetDeepLink.scheme, url.host() == OpenCodeWidgetDeepLink.host {
            appendDebugLog("widget handoff rejected stage=parse")
        }

        await handleLiveActivityURL(url)
    }

    private func handleShareDeepLink(_ request: OpenClientShareDeepLink) async {
        await newProjectChatFacade.acceptShare(request)
    }

    func handleWidgetDeepLink(_ request: OpenCodeWidgetDeepLink.Request) async {
        if case let .session(sessionID) = request.kind {
            let pendingID: UUID
            if let pending = deepLinkRoutingStore.pendingWidgetSession, pending.request == request {
                pendingID = pending.id
            } else {
                pendingID = deepLinkRoutingStore.replacePendingWidgetSession(request)
            }
            await resumePendingWidgetSessionDeepLink(expectedID: pendingID, sessionID: sessionID)
            return
        }
        guard request.serverID?.isEmpty == false, request.projectID?.isEmpty == false else { return }
        guard await ensureWidgetDeepLinkServerConnection(serverID: request.serverID, profile: request.profile),
              let connection = backendConnection else { return }
        do {
            let catalog = try await connection.projects.projectsSnapshot()
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request) else { return }
            guard let project = catalog.projects.first(where: { $0.id == request.projectID }) else { throw BackendError.invalidScope }
            let directory: String?
            if project.id == "global" {
                directory = request.profile == .v2 ? catalog.defaultDirectory : nil
                guard request.directory == nil || request.directory == directory else { throw BackendError.invalidScope }
                if request.profile == .v2, directory?.isEmpty != false { throw BackendError.invalidScope }
            } else {
                directory = request.directory ?? project.worktree
                guard directory == project.worktree || (project.sandboxes ?? []).contains(directory ?? "") else {
                    throw BackendError.invalidScope
                }
            }
            guard request.workspaceID == nil else { throw BackendError.invalidScope }
            if request.profile == .v2, connection.sessionSelection == nil { throw BackendError.unsupported(.commands) }
            if case .action = request.kind, connection.commands == nil { throw BackendError.unsupported(.commands) }
            let scope = BackendScope(projectID: project.id, directory: directory)
            let selection = widgetComposerSelection(from: request)
            guard (request.providerID == nil) == (request.modelID == nil),
                  request.reasoningVariant == nil || selection?.modelReference != nil else { throw BackendError.invalidScope }
            if let reference = selection?.modelReference {
                let models = try await connection.models.modelCatalog(scope: scope)
                guard isCurrentBackendConnection(connection), widgetConnectionMatches(request) else { return }
                guard let model = models.providers.first(where: { $0.id == reference.providerID })?.models[reference.modelID],
                      request.reasoningVariant.map({ model.variants?[$0] != nil }) ?? true else { throw BackendError.invalidScope }
            }
            projects = catalog.projects
            projectStore.defaultServerDirectory = catalog.defaultDirectory
            await newProjectChatFacade.acceptWidget(request, project: project, scope: scope, selection: selection)
        } catch {
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request) else { return }
            newProjectChatFacade.setWidgetRoutingError(String(localized: "Project is no longer available. Open the app to sync widget settings."))
        }
    }

    func resumePendingWidgetSessionDeepLink() async {
        guard let pending = deepLinkRoutingStore.pendingWidgetSession,
              case let .session(sessionID) = pending.request.kind else { return }
        await resumePendingWidgetSessionDeepLink(expectedID: pending.id, sessionID: sessionID)
    }

    private func resumePendingWidgetSessionDeepLink(expectedID: UUID, sessionID: String) async {
        guard let pending = deepLinkRoutingStore.pendingWidgetSession,
              pending.id == expectedID else { return }
        let request = pending.request
        guard await ensureWidgetDeepLinkServerConnection(serverID: request.serverID, profile: request.profile) else {
            if !connectionStore.isLoading
                || config.recentServerID != (request.serverID ?? config.recentServerID) {
                deepLinkRoutingStore.consumePendingWidgetSession(id: expectedID)
            }
            return
        }
        guard deepLinkRoutingStore.pendingWidgetSession?.id == expectedID else { return }
        guard let connection = backendConnection, isCurrentBackendConnection(connection),
              widgetConnectionMatches(request) else { return }

        // Consume before navigation so a connection-completion drain and the original URL task
        // cannot both route the same notification after an actor reentrancy point.
        deepLinkRoutingStore.consumePendingWidgetSession(id: expectedID)
        await openWidgetSession(sessionID, request: request, connection: connection)
    }

    private func ensureWidgetDeepLinkServerConnection(serverID: String?, profile: OpenCodeProfileIdentity) async -> Bool {
        let targetID = serverID ?? config.recentServerID
        guard let saved = savedWidgetDeepLinkServer(serverID: serverID, profile: profile) else {
            appendDebugLog("widget handoff rejected stage=connection reason=saved-destination")
            newProjectChatFacade.setWidgetRoutingError(String(localized: "Open the app to reconnect the server used by this widget."))
            return false
        }

        if connectionAttemptID != nil, connectionStore.isLoading {
            let matchesAttempt = config.recentServerID == targetID
                && config.apiPreference == saved.apiPreference && config.password == saved.password
            if !matchesAttempt {
                // Notification intent may replace launch auto-connect, but never a user-initiated attempt.
                guard automaticConnectionRetryEnabled else { return false }
                await connect(to: saved)
            } else {
                let attempt = connectionAttemptID
                for await loading in connectionStore.$isLoading.values {
                    guard !Task.isCancelled, config.recentServerID == targetID,
                          connectionAttemptID == attempt || connectionAttemptID == nil else { return false }
                    if !loading { break }
                }
            }
        } else if !isConnected || config.recentServerID != targetID || config.apiPreference != saved.apiPreference
                    || config.password != saved.password {
            await connect(to: saved)
        }
        let matches = !Task.isCancelled && isConnected && config.recentServerID == targetID
            && config.apiPreference == saved.apiPreference
            && connectionStore.apiProfile?.rawValue == profile.rawValue
            && backendConnection?.isClosed == false
            && widgetBackendMatches(profile: profile, serverID: targetID)
        if !matches {
            appendDebugLog("widget handoff rejected stage=connection reason=resolved-destination")
            newProjectChatFacade.setWidgetRoutingError(String(localized: "Open the app to reconnect the server used by this widget."))
        }
        return matches
    }

    private func savedWidgetDeepLinkServer(
        serverID: String?,
        profile: OpenCodeProfileIdentity
    ) -> OpenCodeServerConfig? {
        let targetID = serverID ?? config.recentServerID
        return recentServerConfigs.first {
            $0.recentServerID == targetID
                && ($0.apiPreference == .automatic || $0.apiPreference.rawValue == profile.rawValue)
        }
    }

    func widgetConnectionMatches(_ request: OpenCodeWidgetDeepLink.Request) -> Bool {
        !Task.isCancelled && isConnected
            && (request.serverID == nil || request.serverID == config.recentServerID)
            && recentServerConfigs.contains(where: { $0.recentServerID == config.recentServerID
                && $0.apiPreference == config.apiPreference && $0.password == config.password })
            && connectionStore.apiProfile?.rawValue == request.profile.rawValue
            && widgetBackendMatches(profile: request.profile, serverID: request.serverID ?? config.recentServerID)
    }

    private func widgetBackendMatches(profile: OpenCodeProfileIdentity, serverID: String) -> Bool {
        guard let adapter = backendConnection?.openCodeCompatibility else { return true }
        let actual = adapter.client.config
        return adapter.profile.rawValue == profile.rawValue && actual.recentServerID == serverID
            && actual.trimmedBaseURL == config.trimmedBaseURL && actual.trimmedUsername == config.trimmedUsername
            && actual.password == config.password && actual.apiPreference == config.apiPreference
    }

    private func openWidgetSession(
        _ sessionID: String,
        request: OpenCodeWidgetDeepLink.Request,
        connection: BackendConnection
    ) async {
        appendDebugLog(
            "widget session handoff start profile=\(request.profile.rawValue) directory=\(request.directory == nil ? "absent" : "present") workspace=\(request.workspaceID == nil ? "absent" : "present")"
        )
        guard isCurrentBackendConnection(connection), widgetConnectionMatches(request) else {
            appendDebugLog("widget session handoff stopped stage=connection")
            return
        }
        let navigationGeneration = sessionNavigationGeneration
        var stage = "canonical-session"
        do {
            let scope = BackendScope(projectID: request.projectID, directory: request.directory, workspaceID: request.workspaceID)
            let session = try await connection.sessions.session(id: sessionID, scope: scope)
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request),
                  sessionNavigationGeneration == navigationGeneration else {
                appendDebugLog("widget session handoff stopped stage=canonical-session reason=stale-context")
                return
            }
            guard session.id == sessionID, session.projectID == request.projectID,
                   widgetDirectory(session.directory) == widgetDirectory(request.directory),
                   session.workspaceID == request.workspaceID else { throw BackendError.invalidScope }
            appendDebugLog("widget session handoff verified stage=canonical-session")

            stage = "project-catalog"
            let catalog = try await connection.projects.projectsSnapshot()
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request),
                  sessionNavigationGeneration == navigationGeneration else {
                appendDebugLog("widget session handoff stopped stage=project-catalog reason=stale-context")
                return
            }
            var canonicalProjects = catalog.projects
            let project: OpenCodeProject
            let projectSource: String
            if let catalogProject = canonicalProjects.first(where: { $0.id == session.projectID }) {
                project = catalogProject
                projectSource = "catalog"
            } else {
                guard let projectID = session.projectID,
                      projectID == "global" || session.directory?.isEmpty == false else {
                    throw BackendError.invalidScope
                }
                // Legacy project discovery can lag a canonical scoped session read.
                project = OpenCodeProject(
                    id: projectID,
                    worktree: session.directory ?? "/",
                    vcs: nil,
                    name: nil,
                    sandboxes: nil,
                    icon: nil,
                    time: nil
                )
                canonicalProjects.append(project)
                projectSource = "canonical-session"
            }
            appendDebugLog("widget session handoff verified stage=project-catalog source=\(projectSource)")
            // Only canonical session/project values may alter navigation; the URL is not a cache seed.
            newProjectChatFacade.setWidgetRoutingError(nil)
            projects = canonicalProjects
            currentProject = project
            prepareDirectorySelection(session.directory)
            upsertVisibleSession(session)
            isLoadingSessions = false
            stage = "selection"
            let presentationRequestBeforeSelection = chatDetailPresentationRequest
            await selectSession(session)
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request),
                  selectedSession?.id == sessionID else { return }
            // Present only after selection/hydration has committed. Otherwise RootView can consume
            // the request while the detail route is still a loading or empty destination.
            appShellFacade.selectProjectContent()
            if chatDetailPresentationRequest == presentationRequestBeforeSelection {
                chatDetailPresentationRequest &+= 1
            }
            appendDebugLog(
                "widget session handoff committed selected=\(selectedSession?.id == sessionID) prepared=\(chatStore.preparedSessionID == sessionID) tab=\(selectedProjectContentTab.rawValue)"
            )
        } catch {
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request),
                  sessionNavigationGeneration == navigationGeneration else { return }
            appendDebugLog("widget session handoff rejected stage=\(stage)")
            newProjectChatFacade.setWidgetRoutingError(String(localized: "Project is no longer available. Open the app to sync widget settings."))
        }
    }

    private func widgetDirectory(_ directory: String?) -> String? {
        guard let directory, !directory.isEmpty, directory != "/" else { return nil }
        return directory
    }

    private func widgetComposerSelection(from request: OpenCodeWidgetDeepLink.Request) -> NewProjectChatComposerSelection? {
        let modelReference: OpenCodeModelReference?
        if let providerID = request.providerID, let modelID = request.modelID {
            modelReference = OpenCodeModelReference(providerID: providerID, modelID: modelID)
        } else {
            modelReference = nil
        }

        guard modelReference != nil || request.reasoningVariant != nil else { return nil }
        return NewProjectChatComposerSelection(
            agentName: nil,
            modelReference: modelReference,
            reasoningVariant: request.reasoningVariant
        )
    }

}
