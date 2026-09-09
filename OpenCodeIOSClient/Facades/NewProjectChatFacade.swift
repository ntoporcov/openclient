import Combine
import Foundation

/// Handoff retries retain creation independently of prompt admission, which remains ledger-owned.
@MainActor
final class NewProjectChatCheckpoint {
    let connectionID: UUID
    var session: OpenCodeSession?
    var creationStarted = false
    var scope: BackendScope?
    var messageID: String
    var partID: String
    var admission: ChatStore.PromptAdmission.Phase?
    var appliedSelection: NewProjectChatComposerSelection?
    var agentSelectionUncertain = false
    var modelSelectionUncertain = false

    init(connectionID: UUID, messageID: String, partID: String) {
        self.connectionID = connectionID
        self.messageID = messageID
        self.partID = partID
    }

    func retainAdmissionEvidence(in ledger: ChatStore, sessionID: String) -> AnyCancellable {
        let messageID = messageID
        let connectionID = connectionID
        // The active ledger may prune this connection while its POST is still pending.
        // Keep only this operation's admission evidence, not historical ledger records.
        return ledger.$promptAdmissions.sink { [weak self] admissions in
            guard let admission = admissions[messageID], admission.connectionID == connectionID,
                  admission.sessionID == sessionID, admission.phase == .admitted else { return }
            self?.admission = .admitted
        }
    }
}

@MainActor
final class NewProjectChatFacade: ObservableObject {
    @MainActor
    private final class PromptReservation {
        private let commerce: CommerceFacade
        private let day: String?
        private var settled = false

        init(commerce: CommerceFacade, day: String?) {
            self.commerce = commerce
            self.day = day
        }

        func settle(refund: Bool) {
            guard !settled else { return }
            settled = true
            guard refund, let day, commerce.usageMeter.promptDay == day,
                  day == OpenClientUsageMeter.dayString(for: Date()) else { return }
            commerce.refundReservedUserPromptIfNeeded()
        }
    }
    private unowned let viewModel: AppViewModel
    private var observations: Set<AnyCancellable> = []
    private class ChatHandoff {
        let sheetID: UUID
        let serverID: String
        var routing = false
        var consumed = false
        var connectionID: UUID?
        var config: OpenCodeServerConfig?
        var projects: [OpenCodeProject] = []
        var checkpoint: NewProjectChatCheckpoint?
        var submittedContent: NewProjectChatInitialContent?
        var submittedMentions: [OpenCodeAgentMention] = []
        var submittedSelection: NewProjectChatComposerSelection?
        var workspaceDirectory: String?
        var workspaceSelection: NewSessionWorkspaceSelection?
        var newWorkspaceName = ""
        var destinationParent: String?
        var submitting = false
        var error: String?

        init(sheetID: UUID, serverID: String) {
            self.sheetID = sheetID
            self.serverID = serverID
        }
    }
    private final class ShareHandoff: ChatHandoff {
        let request: OpenClientShareDeepLink
        let payload: OpenClientSharePayload
        init(request: OpenClientShareDeepLink, payload: OpenClientSharePayload, sheetID: UUID, serverID: String) {
            self.request = request
            self.payload = payload
            super.init(sheetID: sheetID, serverID: serverID)
        }
    }
    private final class WidgetHandoff: ChatHandoff {
        let request: OpenCodeWidgetDeepLink.Request
        let scope: BackendScope
        init(request: OpenCodeWidgetDeepLink.Request, scope: BackendScope, sheetID: UUID, serverID: String) {
            self.request = request
            self.scope = scope
            super.init(sheetID: sheetID, serverID: serverID)
        }
    }
    private var shares: [String: ShareHandoff] = [:]
    private var widget: WidgetHandoff?
    private var widgetCommands: [WidgetHandoff] = []
    private var widgetRoutingError: String?
    private var presentedShareIDs: Set<String> = []

    init(viewModel: AppViewModel) {
        self.viewModel = viewModel

        Publishers.MergeMany([
            viewModel.projectStore.$projects.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.projectStore.$currentProject.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.projectStore.$worktreeInventories.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.projectStore.$worktreeDestinationParents.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.connectionStore.objectWillChange.eraseToAnyPublisher(),
            viewModel.commerceFacade.objectWillChange.eraseToAnyPublisher(),
            viewModel.$newProjectChatSheetRequest.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.projectPreferencesStore.$projectWorkspacesEnabledByScope.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$availableAgents.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$allProviders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$availableProviders.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$modelVisibilityPreferences.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$defaultModelsByProviderID.dropFirst().map { _ in () }.eraseToAnyPublisher(),
            viewModel.modelConfigurationStore.$newSessionDefaults.dropFirst().map { _ in () }.eraseToAnyPublisher(),
        ])
        .sink { [weak self] _ in self?.objectWillChange.send() }
        .store(in: &observations)

        viewModel.$newProjectChatSheetRequest.dropFirst()
            .sink { [weak self] request in
                guard let self else { return }
                if let widget, widget.sheetID != request?.id { clearWidgetRoutingError() }
                // Keep small delivery tombstones, not every previously shared image in memory.
                shares = shares.filter { $0.value.sheetID == request?.id }
            }
            .store(in: &observations)
        viewModel.connectionStore.$errorMessage.dropFirst()
            .sink { [weak self] _ in self?.widgetRoutingError = nil }
            .store(in: &observations)
    }

    var projects: [OpenCodeProject] { viewModel.projects }
    var globalForms: GlobalFormsFacade { viewModel.globalFormsFacade }
    func globalFormLocation(project: OpenCodeProject?, directory: String?) -> BackendFormLocation? {
        guard let project else { return nil }
        let scope = viewModel.projectExecutionScope(for: project, directory: directory)
        return scope.directory.map { .init(directory: $0, workspaceID: scope.workspaceID) }
    }
    var currentProject: OpenCodeProject? { viewModel.currentProject }
    var paywallReason: OpenClientPaywallReason? { viewModel.commerceFacade.paywallReason }
    var commerce: CommerceFacade { viewModel.commerceFacade }
    func ownsSubmission(_ request: NewProjectChatSheetRequest) -> Bool {
        request.sharePayloadID != nil || widget?.sheetID == request.id
    }
    var ownsPaywallPresentation: Bool {
        guard let request = viewModel.newProjectChatSheetRequest else { return false }
        return ownsSubmission(request)
    }
    func shouldDismissForPaywall(_ request: NewProjectChatSheetRequest) -> Bool {
        paywallReason != nil && request.sharePayloadID == nil && widget?.sheetID != request.id
    }
    var selectableAgents: [OpenCodeAgent] { viewModel.selectableAgents }
    var sortedProviders: [OpenCodeProvider] { viewModel.sortedProviders }
    var newSessionDefaults: NewSessionDefaults { viewModel.newSessionDefaults }
    var isReadOnly: Bool {
        viewModel.isBrowsingLocalCache || !viewModel.isConnected || viewModel.backendConnection?.isClosed != false
    }
    var connectionContextID: String { viewModel.backendConnection?.id.uuidString ?? "disconnected" }
    var requiresWorktreeDestinationParent: Bool { viewModel.projectFacade.requiresWorktreeDestinationParent }
    func worktreeDestinationParent(for project: OpenCodeProject) -> String {
        viewModel.projectFacade.worktreeDestinationParent(for: project)
    }
    func setWorktreeDestinationParent(_ directory: String, for project: OpenCodeProject) {
        guard !isReadOnly else { return }
        viewModel.projectFacade.setWorktreeDestinationParent(directory, for: project)
    }

    func dismissNewChat(requestID: UUID? = nil) {
        guard requestID == nil || viewModel.newProjectChatSheetRequest?.id == requestID else { return }
        clearWidgetRoutingError()
        viewModel.dismissNewProjectChatSheet()
    }

    private func clearWidgetRoutingError() {
        guard let error = widgetRoutingError else { return }
        widgetRoutingError = nil
        if viewModel.errorMessage == error { viewModel.errorMessage = nil }
    }

    private func setWidgetRoutingError(_ error: String?, handoff: WidgetHandoff) {
        handoff.error = error
        setWidgetRoutingError(error)
    }

    func setWidgetRoutingError(_ error: String?) {
        guard let error else { clearWidgetRoutingError(); return }
        viewModel.errorMessage = error
        widgetRoutingError = error
    }

    func isPresented(_ request: NewProjectChatSheetRequest) -> Bool {
        viewModel.newProjectChatSheetRequest?.id == request.id
    }

    func acceptWidget(_ request: OpenCodeWidgetDeepLink.Request, project: OpenCodeProject,
                      scope: BackendScope, selection: NewProjectChatComposerSelection?) async {
        guard let connection = viewModel.backendConnection, viewModel.widgetConnectionMatches(request) else { return }
        if request.kind == .newSession {
            if let widget, widget.request == request, viewModel.newProjectChatSheetRequest?.id == widget.sheetID {
                guard !widget.submitting, widget.checkpoint?.creationStarted != true, widget.scope == scope,
                      widget.projects.contains(where: { $0.id == project.id && $0.worktree == project.worktree }) else { return }
                widget.connectionID = connection.id
                widget.config = viewModel.config
                widget.checkpoint = NewProjectChatCheckpoint(connectionID: connection.id,
                    messageID: OpenCodeIdentifier.message(), partID: OpenCodeIdentifier.part())
                widget.checkpoint?.scope = scope
                setWidgetRoutingError(nil, handoff: widget)
                objectWillChange.send()
                return
            }
            // A deep link never replaces an edited composer, including a share handoff.
            guard viewModel.newProjectChatSheetRequest == nil else { return }
            clearWidgetRoutingError()
            viewModel.presentNewProjectChatSheet(projectID: project.id, workspaceDirectory: scope.directory,
                locksProject: true, composerSelection: selection, presentsAboveConnection: true,
                requiresLegacyWidgetActions: true)
            guard let id = viewModel.newProjectChatSheetRequest?.id else { return }
            let handoff = WidgetHandoff(request: request, scope: scope, sheetID: id, serverID: viewModel.config.recentServerID)
            handoff.connectionID = connection.id
            handoff.config = viewModel.config
            handoff.projects = [project]
            handoff.checkpoint = NewProjectChatCheckpoint(connectionID: connection.id,
                messageID: OpenCodeIdentifier.message(), partID: OpenCodeIdentifier.part())
            handoff.checkpoint?.scope = scope
            widget = handoff
            objectWillChange.send()
            return
        }
        guard case let .action(name) = request.kind, let commands = connection.commands else { return }
        guard globalForms.pending(for: scope.directory.map { .init(directory: $0, workspaceID: scope.workspaceID) }).isEmpty else { return }
        let handoff: WidgetHandoff
        if let existing = widgetCommands.first(where: { $0.request == request }) {
            guard !existing.submitting, widgetOwnerMatches(existing), existing.scope == scope else { return }
            if existing.connectionID != connection.id {
                guard let checkpoint = existing.checkpoint, checkpoint.admission != nil, checkpoint.admission != .rejected,
                      let session = checkpoint.session, let originalScope = checkpoint.scope else { return }
                existing.submitting = true
                defer { existing.submitting = false }
                do {
                    let canonical = try await connection.sessions.session(id: session.id, scope: originalScope)
                    guard viewModel.isCurrentBackendConnection(connection), widgetOwnerMatches(existing),
                          canonical.id == session.id, canonical.projectID == originalScope.projectID,
                          canonical.directory == originalScope.directory, canonical.workspaceID == originalScope.workspaceID else { return }
                    let turn = try await commands.completedTurn(sessionID: session.id,
                        userMessageID: checkpoint.messageID, scope: originalScope)
                    guard viewModel.isCurrentBackendConnection(connection), widgetOwnerMatches(existing),
                          let turn, turn.sessionID == session.id, turn.userMessageID == checkpoint.messageID else { return }
                    // Retire only verified completion. Never migrate an uncertain operation to a new lifetime.
                    existing.connectionID = connection.id
                    existing.checkpoint = NewProjectChatCheckpoint(connectionID: connection.id,
                        messageID: OpenCodeIdentifier.message(), partID: OpenCodeIdentifier.part())
                    existing.checkpoint?.scope = scope
                } catch { return }
            }
            guard isCurrentShare(existing) else { return }
            handoff = existing
        } else {
            handoff = WidgetHandoff(request: request, scope: scope, sheetID: UUID(), serverID: viewModel.config.recentServerID)
            handoff.connectionID = connection.id
            handoff.config = viewModel.config
            handoff.checkpoint = NewProjectChatCheckpoint(connectionID: connection.id,
                messageID: OpenCodeIdentifier.message(), partID: OpenCodeIdentifier.part())
            handoff.checkpoint?.scope = scope
            widgetCommands.append(handoff)
        }
        guard var checkpoint = handoff.checkpoint else { return }
        handoff.submitting = true
        defer { handoff.submitting = false }
        var reservation: PromptReservation?
        var posted = false
        do {
            if let session = checkpoint.session, checkpoint.admission == .admitted {
                // A later tap can start a new run only after canonical completion of this input.
                // The command receipt itself is not completion evidence.
                let turn = try await commands.completedTurn(sessionID: session.id,
                    userMessageID: checkpoint.messageID, scope: checkpoint.scope ?? scope)
                guard isCurrentShare(handoff), !Task.isCancelled else { return }
                guard let turn, turn.sessionID == session.id, turn.userMessageID == checkpoint.messageID else { return }
                checkpoint = NewProjectChatCheckpoint(connectionID: connection.id,
                    messageID: OpenCodeIdentifier.message(), partID: OpenCodeIdentifier.part())
                checkpoint.scope = scope
                handoff.checkpoint = checkpoint
            }
            if let session = checkpoint.session, let phase = checkpoint.admission,
               phase == .submitting || phase == .uncertain {
                // Reconcile the owned input, never repost after an ambiguous receipt.
                let accepted = await viewModel.chatFacade.resolvePromptAdmission(
                    messageID: checkpoint.messageID, sessionID: session.id)
                if accepted { checkpoint.admission = .admitted }
                if isCurrentShare(handoff) {
                    setWidgetRoutingError(accepted ? nil
                        : String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying."), handoff: handoff)
                }
                return
            }
            guard !checkpoint.creationStarted || checkpoint.session != nil else {
                throw ShareRouteError.message(String(localized: "Session creation is uncertain. Check your sessions before trying again."))
            }
            let catalog = try await commands.listCommands(scope: scope)
            guard isCurrentShare(handoff), !Task.isCancelled else { return }
            guard catalog.contains(where: { $0.name == name && $0.source != "client" }) else {
                throw ShareRouteError.message(String(localized: "Command is no longer available. Open the app to sync widget settings."))
            }
            setWidgetRoutingError(nil, handoff: handoff)
            guard checkpoint.session != nil || viewModel.canCreateSessionOrPresentPaywall() else { return }
            guard viewModel.reserveUserPromptIfAllowed() else { return }
            reservation = PromptReservation(commerce: viewModel.commerceFacade,
                day: viewModel.hasProUnlock ? nil : viewModel.usageMeter.promptDay)
            if checkpoint.session == nil {
                checkpoint.creationStarted = true
                checkpoint.session = try await connection.sessions.createSession(.init(title: "/" + name, scope: scope,
                    agent: selection?.agentName, model: selection?.modelReference, variant: selection?.reasoningVariant))
                viewModel.recordCreatedSessionForMetering()
            }
            guard isCurrentShare(handoff), !Task.isCancelled, let session = checkpoint.session else { throw CancellationError() }
            guard session.projectID == project.id, session.directory == scope.directory,
                  scope.workspaceID == nil || session.workspaceID == scope.workspaceID else { throw BackendError.invalidScope }
            var sessionScope = scope
            sessionScope.workspaceID = session.workspaceID
            checkpoint.scope = sessionScope
            viewModel.currentProject = project
            viewModel.prepareDirectorySelection(project.id == "global" ? nil : project.worktree)
            viewModel.upsertVisibleSession(session)
            await viewModel.selectSession(session)
            guard isCurrentShare(handoff), !Task.isCancelled else { throw CancellationError() }
            if checkpoint.admission == .rejected { checkpoint.messageID = OpenCodeIdentifier.message() }
            let id = checkpoint.messageID
            let ledger = viewModel.chatStore
            guard ledger.beginPromptAdmission(.init(sessionID: session.id, messageID: id, text: "/" + name,
                scope: sessionScope), connectionID: connection.id) else { throw CancellationError() }
            checkpoint.admission = .submitting
            let admissionEvidence = checkpoint.retainAdmissionEvidence(in: ledger, sessionID: session.id)
            defer { admissionEvidence.cancel() }
            posted = true
            let receipt: BackendAdmission
            do {
                receipt = try await commands.submitCommand(.init(sessionID: session.id, messageID: id, command: name,
                    scope: sessionScope, agent: selection?.agentName, model: selection?.modelReference,
                    variant: selection?.reasoningVariant))
            } catch { receipt = .uncertain(sessionID: session.id, messageID: id) }
            let phase: ChatStore.PromptAdmission.Phase
            switch receipt {
            case let .accepted(s, m) where s == session.id && m == id: phase = .admitted
            case let .rejected(s, m) where s == session.id && m == id: phase = .rejected
            default: phase = .uncertain
            }
            checkpoint.admission = checkpoint.admission == .admitted ? .admitted
                : (ledger.applyPromptAdmission(phase, messageID: id, connectionID: connection.id) ?? phase)
            reservation?.settle(refund: checkpoint.admission == .rejected)
            guard viewModel.isCurrentBackendConnection(connection) else { return }
            guard isCurrentShare(handoff) else { return }
            switch checkpoint.admission {
            case .admitted?: setWidgetRoutingError(nil, handoff: handoff)
            case .rejected?: setWidgetRoutingError(String(localized: "OpenCode rejected the prompt."), handoff: handoff)
            default: setWidgetRoutingError(String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying."), handoff: handoff)
            }
        } catch {
            if !posted { reservation?.settle(refund: true) }
            if isCurrentShare(handoff), !Task.isCancelled { setWidgetRoutingError(error.localizedDescription, handoff: handoff) }
        }
    }

    func prepareShare(_ request: OpenClientShareDeepLink) {
        if let existing = shares[request.payloadID] {
            if let serverID = request.serverID, serverID != existing.serverID {
                existing.connectionID = nil
                existing.error = String(localized: "The shared content and link specify different connections.")
                viewModel.errorMessage = existing.error
                objectWillChange.send()
            }
            return
        }
        guard !presentedShareIDs.contains(request.payloadID),
              let payload = try? OpenClientSharePayloadStore.load(id: request.payloadID, deletesAfterLoad: false),
              payload.id == request.payloadID else { return }
        guard viewModel.newProjectChatSheetRequest == nil else { return }
        let content = NewProjectChatInitialContent(text: payload.text, attachments: payload.attachments.map {
            OpenCodeComposerAttachment(id: OpenCodeIdentifier.part(),
                kind: $0.mime.lowercased().hasPrefix("image/") ? .image : .file,
                filename: $0.filename, mime: $0.mime, dataURL: $0.dataURL)
        })
        viewModel.presentNewProjectChatSheet(initialContent: content, presentsAboveConnection: true, sharePayloadID: payload.id)
        guard let sheetID = viewModel.newProjectChatSheetRequest?.id else { return }
        let handoff = ShareHandoff(request: request, payload: payload, sheetID: sheetID,
            serverID: payload.serverID ?? request.serverID ?? viewModel.config.recentServerID)
        shares[payload.id] = handoff
        presentedShareIDs.insert(payload.id)
        objectWillChange.send()
    }

    private func authoritativeShareConfig(_ handoff: ShareHandoff) throws -> OpenCodeServerConfig {
        if let stored = handoff.payload.serverID, let selected = handoff.request.serverID, stored != selected {
            throw ShareRouteError.message(String(localized: "The shared content and link specify different connections."))
        }
        guard var saved = viewModel.recentServerConfigs.first(where: { $0.recentServerID == handoff.serverID }) else {
            throw ShareRouteError.message(String(localized: "Open the app once before sharing to this connection."))
        }
        // An empty Keychain value means intentional no-auth; nil means credentials were not recovered.
        if let password = viewModel.passwordStore.loadPassword(for: handoff.serverID) {
            saved.password = password
        } else if saved.password.isEmpty {
            throw ShareRouteError.message(String(localized: "Reconnect this saved connection before sharing. Its credentials are unavailable."))
        }
        return saved
    }

    private func matchesShareConnection(_ config: OpenCodeServerConfig, _ expected: OpenCodeServerConfig) -> Bool {
        config.trimmedBaseURL == expected.trimmedBaseURL && config.trimmedUsername == expected.trimmedUsername
            && config.password == expected.password && config.apiPreference == expected.apiPreference
    }

    private func isCurrentShare(_ handoff: ChatHandoff) -> Bool {
        if let widget = handoff as? WidgetHandoff {
            guard viewModel.backendConnection?.id == widget.connectionID, widgetOwnerMatches(widget) else { return false }
            return widget.request.kind != .newSession || viewModel.newProjectChatSheetRequest?.id == widget.sheetID
        }
        guard let handoff = handoff as? ShareHandoff else { return false }
        guard !isReadOnly, viewModel.newProjectChatSheetRequest?.id == handoff.sheetID,
              viewModel.backendConnection?.id == handoff.connectionID,
              let expected = handoff.config,
              let saved = try? authoritativeShareConfig(handoff),
              matchesShareConnection(saved, expected), matchesShareConnection(viewModel.config, expected) else { return false }
        if let actual = viewModel.backendConnection?.openCodeCompatibility?.client.config {
            return matchesShareConnection(actual, expected)
        }
        return true
    }

    private func widgetOwnerMatches(_ widget: WidgetHandoff) -> Bool {
        guard !isReadOnly, let expected = widget.config else { return false }
        return viewModel.widgetConnectionMatches(widget.request)
            && matchesShareConnection(viewModel.config, expected)
            && viewModel.recentServerConfigs.contains(where: { matchesShareConnection($0, expected) })
    }

    func isReady(for request: NewProjectChatSheetRequest) -> Bool {
        if let widget, widget.sheetID == request.id { return isCurrentShare(widget) && !widget.submitting && !widget.routing }
        if request.requiresLegacyWidgetActions {
            return false
        }
        guard let payloadID = request.sharePayloadID else { return !isReadOnly }
        guard let handoff = shares[payloadID], handoff.sheetID == request.id,
              handoff.consumed, !handoff.routing else { return false }
        return isCurrentShare(handoff)
    }

    func shareError(for request: NewProjectChatSheetRequest) -> String? {
        if let widget, widget.sheetID == request.id { return widget.error }
        return request.sharePayloadID.flatMap { shares[$0]?.error }
    }

    func isPreparingShare(_ request: NewProjectChatSheetRequest) -> Bool {
        if let widget, widget.sheetID == request.id { return widget.routing }
        return request.sharePayloadID.flatMap { shares[$0]?.routing } == true
    }

    func retryShare(_ request: NewProjectChatSheetRequest) async {
        if let widget, widget.sheetID == request.id {
            guard !widget.submitting, !widget.routing, widget.checkpoint?.creationStarted != true else { return }
            widget.routing = true
            objectWillChange.send()
            defer { widget.routing = false; objectWillChange.send() }
            await viewModel.handleWidgetDeepLink(widget.request)
            if !isCurrentShare(widget) { widget.error = viewModel.errorMessage }
            return
        }
        guard let id = request.sharePayloadID, let handoff = shares[id], handoff.sheetID == request.id else { return }
        await acceptShare(handoff.request)
    }

    func acceptShare(_ request: OpenClientShareDeepLink) async {
        prepareShare(request)
        guard let handoff = shares[request.payloadID], handoff.request == request,
              viewModel.newProjectChatSheetRequest?.id == handoff.sheetID,
              !handoff.routing, !handoff.submitting, !Task.isCancelled else { return }
        if isCurrentShare(handoff), handoff.consumed { return }
        // Never move a created session or an uncertain prompt to a new connection lifetime.
        guard handoff.checkpoint?.creationStarted != true else { return }
        handoff.checkpoint = nil
        handoff.routing = true
        handoff.connectionID = nil
        let previousError = handoff.error
        handoff.error = nil
        objectWillChange.send()
        defer { handoff.routing = false; objectWillChange.send() }
        do {
            let expected = try authoritativeShareConfig(handoff)
            let actual = viewModel.backendConnection?.openCodeCompatibility?.client.config ?? viewModel.config
            if isReadOnly || !matchesShareConnection(viewModel.config, expected) || !matchesShareConnection(actual, expected) {
                await viewModel.connect(to: expected)
            }
            guard !Task.isCancelled, viewModel.newProjectChatSheetRequest?.id == handoff.sheetID,
                  !isReadOnly, matchesShareConnection(viewModel.config, expected),
                  let connection = viewModel.backendConnection else {
                throw ShareRouteError.message(viewModel.errorMessage ?? String(localized: "Connect to an OpenCode server before starting a chat."))
            }
            handoff.config = expected
            handoff.connectionID = connection.id
            if viewModel.projects.isEmpty { try await viewModel.refreshProjects() }
            guard !Task.isCancelled, isCurrentShare(handoff), !viewModel.projects.isEmpty else {
                throw ShareRouteError.message(String(localized: "Project is no longer available."))
            }
            handoff.projects = viewModel.projects
            if !handoff.consumed {
                // No suspension between transferring ownership and marking this delivery accepted.
                _ = try OpenClientSharePayloadStore.load(id: request.payloadID, deletesAfterLoad: true)
                handoff.consumed = true
            }
            if let previousError, viewModel.errorMessage == previousError {
                viewModel.errorMessage = nil
            }
        } catch {
            handoff.connectionID = nil
            guard !Task.isCancelled, viewModel.newProjectChatSheetRequest?.id == handoff.sheetID else { return }
            handoff.error = error.localizedDescription
            viewModel.errorMessage = error.localizedDescription
        }
    }

    private enum ShareRouteError: LocalizedError {
        case message(String)
        var errorDescription: String? { if case let .message(message) = self { message } else { nil } }
    }
    func visibleModels(for provider: OpenCodeProvider) -> [OpenCodeModel] {
        viewModel.modelConfigurationStore.visibleModels(for: provider)
    }
    func formattedVariantTitle(_ variant: String) -> String { viewModel.formattedVariantTitle(variant) }
    func defaultModelReference() -> OpenCodeModelReference? { viewModel.defaultModelReference() }
    func newSessionDefaultModelReference() -> OpenCodeModelReference? { viewModel.newSessionDefaultModelReference() }
    func model(for reference: OpenCodeModelReference?) -> OpenCodeModel? { viewModel.model(for: reference) }
    func reasoningVariants(for reference: OpenCodeModelReference?) -> [String] { viewModel.reasoningVariants(for: reference) }
    func workspaceDirectories(for project: OpenCodeProject) -> [String] { viewModel.workspaceDirectories(for: project) }
    func prepareWorkspaceInventory(for project: OpenCodeProject) async {
        guard isWorkspacesEnabled(for: project) else { return }
        await viewModel.refreshProjectWorktreeInventory(projectID: project.id)
    }
    func isWorkspacesEnabled(for project: OpenCodeProject) -> Bool { !isReadOnly && viewModel.isProjectWorkspacesEnabled(for: project) }
    func workspaceKey(_ directory: String) -> String { viewModel.workspaceKey(directory) }
    func workspaceDisplayName(for directory: String?, in project: OpenCodeProject?) -> String? {
        viewModel.workspaceDisplayName(for: directory, in: project)
    }

    @discardableResult
    func startNewChat(
        title: String,
        prompt: String,
        agentMentions: [OpenCodeAgentMention],
        attachments: [OpenCodeComposerAttachment],
        messageID: String,
        partID: String,
        composerSelection: NewProjectChatComposerSelection,
        projectID: String,
        workspaceDirectory: String?,
        workspaceSelection: NewSessionWorkspaceSelection?,
        newWorkspaceName: String,
        newWorkspaceDestinationParent: String? = nil,
        request: NewProjectChatSheetRequest? = nil
    ) async -> Bool {
        guard !isReadOnly else { return false }
        // The global project UI intentionally supplies nil for its listing scope.
        // A widget handoff has already resolved its separate execution directory.
        let workspaceDirectory = projectID == "global" && workspaceDirectory == nil
            && widget?.sheetID == (request ?? viewModel.newProjectChatSheetRequest)?.id
            ? widget?.scope.directory : workspaceDirectory
        guard globalForms.pending(for: globalFormLocation(project: projects.first { $0.id == projectID },
                                                         directory: workspaceDirectory)).isEmpty else { return false }
        let activeRequest = request ?? viewModel.newProjectChatSheetRequest
        if let request, !isPresented(request) { return false }
        if let activeRequest, !isReady(for: activeRequest) { return false }
        let handoff: ChatHandoff? = activeRequest?.sharePayloadID.flatMap { shares[$0] }
            ?? (widget?.sheetID == activeRequest?.id ? widget : nil)
        guard handoff?.submitting != true else { return false }
        defer { handoff?.submitting = false; objectWillChange.send() }
        if let widget = handoff as? WidgetHandoff {
            guard projectID == widget.scope.projectID, workspaceDirectory == widget.scope.directory,
                  workspaceSelection == nil || workspaceSelection == .main || workspaceSelection == .directory(widget.scope.directory ?? ""),
                  newWorkspaceName.isEmpty, newWorkspaceDestinationParent == nil else { return false }
            widget.submitting = true
            do {
                guard let connection = viewModel.backendConnection else { return false }
                let catalog = try await connection.projects.projectsSnapshot()
                guard isCurrentShare(widget), !Task.isCancelled,
                      let project = catalog.projects.first(where: { $0.id == projectID }),
                      widget.projects.contains(where: { $0.id == project.id && $0.worktree == project.worktree }) else { return false }
                if project.id == "global" {
                    if widget.request.profile == .v2, widget.scope.directory != catalog.defaultDirectory { return false }
                } else if widget.scope.directory != project.worktree,
                          !(project.sandboxes ?? []).contains(widget.scope.directory ?? "") { return false }
            } catch {
                widget.error = String(localized: "Project is no longer available. Open the app to sync widget settings.")
                return false
            }
        }
        if let activeRequest, activeRequest.sharePayloadID != nil {
            guard let handoff, isReady(for: activeRequest), !handoff.submitting,
                  let project = viewModel.projects.first(where: { $0.id == projectID }),
                  handoff.projects.contains(where: { $0.id == project.id && $0.worktree == project.worktree }),
                  workspaceDirectory.map({ $0 == project.worktree || viewModel.workspaceDirectories(for: project).contains($0) }) ?? true else { return false }
            if case let .directory(directory) = workspaceSelection,
               directory != project.worktree, !viewModel.workspaceDirectories(for: project).contains(directory) { return false }
            if viewModel.connectionStore.apiProfile == .v2,
               viewModel.projectExecutionScope(for: project, directory: workspaceDirectory).directory == nil { return false }
            handoff.submitting = true
        }
        if let checkpoint = handoff?.checkpoint, checkpoint.creationStarted, checkpoint.session == nil {
            handoff?.error = String(localized: "Session creation is uncertain. Check your sessions before trying again.")
            return false
        }
        let content = NewProjectChatInitialContent(text: prompt.trimmingCharacters(in: .whitespacesAndNewlines), attachments: attachments)
        if let handoff, let checkpoint = handoff.checkpoint, let session = checkpoint.session {
            guard checkpoint.scope?.projectID == projectID,
                  handoff.workspaceDirectory == workspaceDirectory, handoff.workspaceSelection == workspaceSelection,
                  handoff.newWorkspaceName == newWorkspaceName, handoff.destinationParent == newWorkspaceDestinationParent else {
                handoff.error = String(localized: "The shared chat has already been created in another destination.")
                return false
            }
            let phase = viewModel.chatFacade.promptAdmissionPhase(messageID: checkpoint.messageID, sessionID: session.id) ?? checkpoint.admission
            if phase == .uncertain || phase == .submitting || phase == .admitted {
                let accepted = phase == .admitted ? true
                    : await viewModel.chatFacade.resolvePromptAdmission(messageID: checkpoint.messageID, sessionID: session.id)
                guard isCurrentShare(handoff) else { return false }
                guard accepted else {
                    handoff.error = String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.")
                    return false
                }
                if handoff.submittedContent == content, handoff.submittedMentions == agentMentions,
                   handoff.submittedSelection == composerSelection { return true }
                checkpoint.messageID = messageID
                checkpoint.partID = partID
                checkpoint.admission = nil
            }
            if phase == .rejected {
                checkpoint.messageID = messageID
                checkpoint.partID = partID
                checkpoint.admission = nil
            }
        }
        if let handoff {
            if handoff.checkpoint == nil, let connectionID = viewModel.backendConnection?.id {
                handoff.checkpoint = NewProjectChatCheckpoint(connectionID: connectionID, messageID: messageID, partID: partID)
            }
            handoff.submittedContent = content
            handoff.submittedMentions = agentMentions
            handoff.submittedSelection = composerSelection
            handoff.workspaceDirectory = workspaceDirectory
            handoff.workspaceSelection = workspaceSelection
            handoff.newWorkspaceName = newWorkspaceName
            handoff.destinationParent = newWorkspaceDestinationParent
        }
        if let widget = handoff as? WidgetHandoff {
            return await startWidgetChat(widget, title: title, selection: composerSelection)
        }
        var acceptedScope: BackendScope?
        let submitShare: ((OpenCodeSession, BackendScope, String?) async -> Bool)?
        if let handoff {
            submitShare = { [self] session, scope, reservedDay in
                await submitSharePrompt(handoff, session: session, scope: scope, reservedDay: reservedDay)
            }
        } else {
            submitShare = nil
        }
        let accepted = await viewModel.startNewProjectChat(
            title: title,
            prompt: prompt,
            agentMentions: agentMentions,
            attachments: attachments,
            messageID: handoff?.checkpoint?.messageID ?? messageID,
            partID: handoff?.checkpoint?.partID ?? partID,
            composerSelection: composerSelection,
            projectID: projectID,
            workspaceDirectory: workspaceDirectory,
            workspaceSelection: workspaceSelection,
            newWorkspaceName: newWorkspaceName,
            newWorkspaceDestinationParent: newWorkspaceDestinationParent,
            checkpoint: handoff?.checkpoint,
            isSubmissionCurrent: { [weak self] in
                guard let handoff else { return true }
                return self?.isCurrentShare(handoff) == true
            },
            submitInitialPrompt: submitShare,
            onPromptAccepted: { session, acceptedID, scope in
                guard let handoff, handoff.checkpoint?.session?.id == session.id,
                      handoff.checkpoint?.messageID == acceptedID else { return }
                acceptedScope = scope
            }
        )
        if let handoff {
            guard isCurrentShare(handoff) else { return false }
            handoff.error = accepted ? nil : viewModel.errorMessage
            return accepted && acceptedScope == handoff.checkpoint?.scope
        }
        return accepted
    }

    private func startWidgetChat(_ handoff: WidgetHandoff, title: String,
                                 selection: NewProjectChatComposerSelection) async -> Bool {
        guard isCurrentShare(handoff), let connection = viewModel.backendConnection,
              let checkpoint = handoff.checkpoint, checkpoint.connectionID == connection.id,
              let project = handoff.projects.first(where: { $0.id == handoff.scope.projectID }),
              let content = handoff.submittedContent, !content.text.isEmpty || !content.attachments.isEmpty else { return false }
        guard checkpoint.session != nil || viewModel.canCreateSessionOrPresentPaywall() else { return false }
        guard viewModel.reserveUserPromptIfAllowed() else { return false }
        let reservedDay = viewModel.hasProUnlock ? nil : viewModel.usageMeter.promptDay
        let reservation = PromptReservation(commerce: viewModel.commerceFacade, day: reservedDay)
        var transferredReservation = false
        defer {
            if !transferredReservation { reservation.settle(refund: true) }
        }
        do {
            if checkpoint.session == nil {
                guard !checkpoint.creationStarted else { return false }
                checkpoint.creationStarted = true
                checkpoint.session = try await connection.sessions.createSession(.init(
                    title: title.trimmingCharacters(in: .whitespacesAndNewlines), scope: handoff.scope,
                    agent: selection.agentName, model: selection.modelReference, variant: selection.reasoningVariant))
                checkpoint.appliedSelection = selection
                // A known create counts even when its response outlives navigation or the connection.
                viewModel.recordCreatedSessionForMetering()
            }
            guard !Task.isCancelled, isCurrentShare(handoff), let session = checkpoint.session else { return false }
            guard session.projectID == handoff.scope.projectID, session.directory == handoff.scope.directory,
                  handoff.scope.workspaceID == nil || session.workspaceID == handoff.scope.workspaceID else { throw BackendError.invalidScope }
            var scope = handoff.scope
            scope.workspaceID = session.workspaceID
            checkpoint.scope = scope
            viewModel.currentProject = project
            viewModel.prepareDirectorySelection(project.id == "global" ? nil : project.worktree)
            viewModel.upsertVisibleSession(session)
            if checkpoint.appliedSelection == selection {
                viewModel.applyNewProjectChatComposerSelection(selection, to: session)
            }
            await viewModel.selectSession(session)
            guard !Task.isCancelled, isCurrentShare(handoff) else { return false }
            transferredReservation = true
            let admitted = await submitSharePrompt(handoff, session: session, scope: scope, reservedDay: reservedDay, reservation: reservation)
            checkpoint.admission = viewModel.isCurrentBackendConnection(connection)
                ? (viewModel.chatFacade.promptAdmissionPhase(messageID: checkpoint.messageID, sessionID: session.id) ?? checkpoint.admission)
                : checkpoint.admission
            guard isCurrentShare(handoff) else { return false }
            return admitted
        } catch {
            if isCurrentShare(handoff), !Task.isCancelled {
                setWidgetRoutingError(error.localizedDescription, handoff: handoff)
            }
            return false
        }
    }

    private func submitSharePrompt(_ handoff: ChatHandoff, session: OpenCodeSession,
                                   scope: BackendScope, reservedDay: String?, reservation: PromptReservation? = nil) async -> Bool {
        let reservation = reservation ?? PromptReservation(commerce: viewModel.commerceFacade, day: reservedDay)
        guard !Task.isCancelled, isCurrentShare(handoff), let connection = viewModel.backendConnection,
              let checkpoint = handoff.checkpoint, let content = handoff.submittedContent else {
            reservation.settle(refund: true)
            return false
        }
        let ledger = viewModel.chatStore
        let id = checkpoint.messageID
        if let widget = handoff as? WidgetHandoff {
            guard session.projectID == widget.scope.projectID, session.directory == widget.scope.directory,
                  scope.projectID == widget.scope.projectID, scope.directory == widget.scope.directory else {
                reservation.settle(refund: true)
                widget.error = String(localized: "Project is no longer available. Open the app to sync widget settings.")
                return false
            }
        }
        if let phase = ledger.promptAdmissionPhase(messageID: id, sessionID: session.id, connectionID: connection.id) {
            reservation.settle(refund: true)
            return phase == .admitted
        }
        if let service = connection.sessionSelection, let selection = handoff.submittedSelection,
           let previous = checkpoint.appliedSelection {
            let changesAgent = selection.agentName != previous.agentName || checkpoint.agentSelectionUncertain
            let changesModel = selection.modelReference != previous.modelReference
                || selection.reasoningVariant != previous.reasoningVariant || checkpoint.modelSelectionUncertain
            do {
                // The catalog's fallback model and first agent are not verified scope defaults.
                // Validate all resets before applying either half of a selection change.
                if changesAgent, selection.agentName == nil {
                    throw ShareRouteError.message(String(localized: "Choose an explicit agent before retrying this shared chat."))
                }
                if changesModel, selection.modelReference == nil {
                    throw ShareRouteError.message(String(localized: "Choose an explicit model before retrying this shared chat."))
                }
                if changesAgent, let agent = selection.agentName {
                    checkpoint.agentSelectionUncertain = true
                    try await service.setAgent(sessionID: session.id, agent: agent, scope: scope)
                    guard !Task.isCancelled, isCurrentShare(handoff) else { throw CancellationError() }
                    checkpoint.agentSelectionUncertain = false
                    checkpoint.appliedSelection = .init(agentName: agent,
                        modelReference: previous.modelReference, reasoningVariant: previous.reasoningVariant)
                    checkpoint.session?.agent = agent
                    viewModel.modelConfigurationStore.selectAgent(named: agent, forSessionID: session.id)
                }
                if changesModel, let model = selection.modelReference {
                    checkpoint.modelSelectionUncertain = true
                    try await service.setModel(sessionID: session.id, model: model, variant: selection.reasoningVariant, scope: scope)
                    guard !Task.isCancelled, isCurrentShare(handoff) else { throw CancellationError() }
                    checkpoint.modelSelectionUncertain = false
                    checkpoint.appliedSelection = selection
                    checkpoint.session?.model = .init(providerID: model.providerID, modelID: model.modelID,
                        variant: selection.reasoningVariant)
                    viewModel.modelConfigurationStore.selectModel(model, forSessionID: session.id)
                    viewModel.modelConfigurationStore.selectVariant(selection.reasoningVariant, forSessionID: session.id)
                }
                if changesAgent || changesModel, let updated = checkpoint.session {
                    viewModel.upsertVisibleSession(updated)
                    if viewModel.selectedSession?.id == updated.id { viewModel.selectedSession = updated }
                }
            } catch {
                // No prompt was posted. Retry an uncertain selection write, not prompt admission.
                reservation.settle(refund: true)
                if isCurrentShare(handoff), !Task.isCancelled {
                    handoff.error = error.localizedDescription
                    if let widget = handoff as? WidgetHandoff {
                        setWidgetRoutingError(handoff.error, handoff: widget)
                    } else {
                        viewModel.errorMessage = handoff.error
                    }
                }
                return false
            }
        }
        let request = BackendSubmission(sessionID: session.id, messageID: id, text: content.text, scope: scope,
            partID: checkpoint.partID, attachments: content.attachments, agentMentions: handoff.submittedMentions,
            agent: handoff.submittedSelection?.agentName, model: handoff.submittedSelection?.modelReference,
            variant: handoff.submittedSelection?.reasoningVariant)
        guard ledger.beginPromptAdmission(request, connectionID: connection.id) else {
            reservation.settle(refund: true)
            return false
        }
        checkpoint.admission = .submitting
        let admissionEvidence = checkpoint.retainAdmissionEvidence(in: ledger, sessionID: session.id)
        defer { admissionEvidence.cancel() }
        let owner = viewModel.directoryStoreRegistry.ownerStore(forSessionID: session.id) ?? viewModel.directoryStore
        let generation = viewModel.directoryStoreRegistry.generation
        let optimistic = OpenCodeMessageEnvelope.local(role: "user", text: request.text,
            agentMentions: request.agentMentions, attachments: request.attachments,
            messageID: id, sessionID: session.id, partID: checkpoint.partID)
        if connection.openCodeCompatibility == nil {
            owner.appendMessage(optimistic, forSessionID: session.id)
            if viewModel.selectedSession?.id == session.id { ledger.insertOptimisticUserMessage(optimistic) }
        }

        let admission: BackendAdmission
        do { admission = try await connection.chat.submit(request) }
        catch { admission = .uncertain(sessionID: session.id, messageID: id) }
        let phase: ChatStore.PromptAdmission.Phase
        switch admission {
        case let .accepted(sessionID, messageID) where sessionID == session.id && messageID == id: phase = .admitted
        case let .rejected(sessionID, messageID) where sessionID == session.id && messageID == id: phase = .rejected
        default: phase = .uncertain
        }
        // Canonical input received during POST wins over a late rejected/uncertain receipt.
        let effective: ChatStore.PromptAdmission.Phase = checkpoint.admission == .admitted ? .admitted
            : (ledger.applyPromptAdmission(phase, messageID: id, connectionID: connection.id) ?? phase)
        checkpoint.admission = effective
        reservation.settle(refund: effective == .rejected)
        guard viewModel.isCurrentBackendConnection(connection),
              viewModel.directoryStoreRegistry.generation == generation else { return false }
        if effective == .rejected {
            ledger.rollbackOptimisticUserMessage(messageID: id)
            owner.removeMessage(sessionID: session.id, messageID: id)
            if let cached = ledger.cachedMessagesBySessionID[session.id] {
                ledger.cacheMessages(cached.filter { $0.id != id }, forSessionID: session.id)
            }
        }
        if isCurrentShare(handoff) {
            switch effective {
            case .admitted: handoff.error = nil
            case .rejected: handoff.error = String(localized: "OpenCode rejected the prompt.")
            default: handoff.error = String(localized: "Prompt admission is uncertain. Refresh the timeline before retrying.")
            }
            if let widget = handoff as? WidgetHandoff {
                setWidgetRoutingError(handoff.error, handoff: widget)
            } else {
                viewModel.errorMessage = handoff.error
            }
        }
        return effective == .admitted
    }

}
