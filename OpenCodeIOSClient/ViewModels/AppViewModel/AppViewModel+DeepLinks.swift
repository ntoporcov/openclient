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

extension AppViewModel {
    func prepareOpenURLPresentation(_ url: URL) {
        if let shareRequest = OpenClientShareDeepLink(url: url) {
            newProjectChatFacade.prepareShare(shareRequest)
            return
        }

        // Widget destinations must be verified before exposing an editable composer.
    }

    func handleOpenURL(_ url: URL) async {
        if let shareRequest = OpenClientShareDeepLink(url: url) {
            await handleShareDeepLink(shareRequest)
            return
        }

        if let widgetRequest = OpenCodeWidgetDeepLink.request(from: url) {
            await handleWidgetDeepLink(widgetRequest)
            return
        }

        await handleLiveActivityURL(url)
    }

    private func handleShareDeepLink(_ request: OpenClientShareDeepLink) async {
        await newProjectChatFacade.acceptShare(request)
    }

    func handleWidgetDeepLink(_ request: OpenCodeWidgetDeepLink.Request) async {
        if case let .session(sessionID) = request.kind {
            await openWidgetSession(sessionID, request: request)
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

    private func ensureWidgetDeepLinkServerConnection(serverID: String?, profile: OpenCodeProfileIdentity) async -> Bool {
        let targetID = serverID ?? config.recentServerID
        guard let saved = recentServerConfigs.first(where: { $0.recentServerID == targetID }),
              saved.apiPreference == .automatic || saved.apiPreference.rawValue == profile.rawValue else {
            newProjectChatFacade.setWidgetRoutingError(String(localized: "Open the app to reconnect the server used by this widget."))
            return false
        }

        if connectionAttemptID != nil, connectionStore.isLoading {
            // Join only this destination's attempt. Never replace an in-flight unrelated connection.
            guard config.recentServerID == targetID, config.apiPreference == saved.apiPreference else { return false }
            let attempt = connectionAttemptID
            for await loading in connectionStore.$isLoading.values {
                guard !Task.isCancelled, config.recentServerID == targetID,
                      connectionAttemptID == attempt || connectionAttemptID == nil else { return false }
                if !loading { break }
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
            newProjectChatFacade.setWidgetRoutingError(String(localized: "Open the app to reconnect the server used by this widget."))
        }
        return matches
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

    private func openWidgetSession(_ sessionID: String, request: OpenCodeWidgetDeepLink.Request) async {
        guard await ensureWidgetDeepLinkServerConnection(serverID: request.serverID, profile: request.profile),
              let connection = backendConnection else { return }
        let navigationGeneration = sessionNavigationGeneration
        do {
            let scope = BackendScope(projectID: request.projectID, directory: request.directory, workspaceID: request.workspaceID)
            let session = try await connection.sessions.session(id: sessionID, scope: scope)
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request),
                  sessionNavigationGeneration == navigationGeneration else { return }
            guard session.id == sessionID, session.projectID == request.projectID,
                  widgetDirectory(session.directory) == widgetDirectory(request.directory),
                  session.workspaceID == request.workspaceID else { throw BackendError.invalidScope }

            let catalog = try await connection.projects.projectsSnapshot()
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request),
                  sessionNavigationGeneration == navigationGeneration else { return }
            guard let project = catalog.projects.first(where: { $0.id == session.projectID }) else {
                throw BackendError.invalidScope
            }
            // Only canonical session/project values may alter navigation; the URL is not a cache seed.
            newProjectChatFacade.setWidgetRoutingError(nil)
            currentProject = project
            prepareDirectorySelection(session.directory)
            upsertVisibleSession(session)
            isLoadingSessions = false
            await selectSession(session)
        } catch {
            guard isCurrentBackendConnection(connection), widgetConnectionMatches(request),
                  sessionNavigationGeneration == navigationGeneration else { return }
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
