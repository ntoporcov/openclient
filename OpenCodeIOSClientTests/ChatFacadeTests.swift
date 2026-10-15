import Combine
import XCTest
@testable import OpenClient

@MainActor
final class ChatFacadeTests: XCTestCase {
    func testToolbarWidthBudgetLeavesSpaceForBackContextAndNativeMargins() {
        for width: CGFloat in [320, 375, 390, 440, 650, 900] {
            let budget = ChatToolbarWidthBudget(containerWidth: width)
            XCTAssertGreaterThanOrEqual(budget.header - 44 - budget.spacing, 44)
            XCTAssertGreaterThanOrEqual(budget.model, 52)
            XCTAssertLessThanOrEqual(budget.header, 220)
            XCTAssertLessThanOrEqual(budget.model, 192)
            XCTAssertGreaterThan(budget.header, budget.model)
            XCTAssertLessThanOrEqual(budget.header + budget.model + 124, width)
        }
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 440).header, 174)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 440).model, 142)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 320).header, 112)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 320).model, 84)
        XCTAssertLessThan(ChatToolbarWidthBudget(containerWidth: 320).header, ChatToolbarWidthBudget(containerWidth: 440).header)
        XCTAssertLessThan(ChatToolbarWidthBudget(containerWidth: 320).model, ChatToolbarWidthBudget(containerWidth: 440).model)
    }

    func testAssistantToolbarUsesSinglePillNativeBarAllowance() {
        for width: CGFloat in [320, 375, 390, 440, 844] {
            let budget = ChatToolbarWidthBudget(containerWidth: width)
            XCTAssertEqual(budget.assistantHeader, max(92, width - 104))
            XCTAssertEqual(budget.assistantHeaderWithTrailingItem, max(92, width - 160))
            XCTAssertGreaterThanOrEqual(budget.assistantHeader - 44 - budget.spacing, 44)
        }

        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 320).assistantHeader, 216)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 390).assistantHeader, 286)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 440).assistantHeader, 336)
        XCTAssertEqual(ChatToolbarWidthBudget(containerWidth: 844).assistantHeader, 740)
    }

    func testProviderLogoUsesExactBundledProviderIDWithSyntheticFallback() {
        for id in ["openai", "openrouter", "amazon-bedrock", "azure", "github-copilot"] {
            XCTAssertEqual(ProviderIcon.assetName(for: id), "ProviderIcon_\(id)")
        }
        XCTAssertEqual(ProviderIcon.assetName(for: "custom-local-provider"), "ProviderIcon_synthetic")
        XCTAssertEqual(ProviderIcon.assetName(for: "OpenRouter"), "ProviderIcon_synthetic")
    }

    func testSameModelNameOnDifferentProvidersChangesDisplayedProvider() {
        let model = makeViewModel()
        let session = makeSession(id: "provider-switch")
        let routed = OpenCodeProvider(id: "openrouter", name: "OpenRouter", models: [
            "reasoner": makeModel(id: "reasoner", providerID: "openrouter", name: "Reasoner"),
        ])
        model.modelConfigurationStore.allProviders.append(routed)
        model.modelConfigurationStore.availableProviders.append(routed)
        model.chatFacade.selectModel(.init(providerID: "openai", modelID: "reasoner"), for: session)
        let first = model.chatFacade.toolbarSnapshot(for: session)
        model.chatFacade.selectModel(.init(providerID: "openrouter", modelID: "reasoner"), for: session)
        let second = model.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(first.modelTitle, second.modelTitle)
        XCTAssertEqual(first.displayedModelReference?.providerID, "openai")
        XCTAssertEqual(second.displayedModelReference?.providerID, "openrouter")
        XCTAssertEqual(second.modelProviderName, "OpenRouter")
        XCTAssertNotEqual(first, second, "Equal model names must not suppress provider-logo updates")
    }

    func testDisplayedProviderFollowsMessageFallbackWithoutCatalogEntry() {
        let model = makeViewModel()
        let session = makeSession(id: "message-provider")
        model.selectedSession = session
        model.isLoadingSelectedSession = true
        let message = OpenCodeMessageEnvelope(info: OpenCodeMessage(id: "routed-message", role: "user",
            sessionID: session.id, time: nil, agent: nil,
            model: OpenCodeMessageModelReference(providerID: "custom-router", modelID: "claude-custom", variant: nil)), parts: [])
        model.messages = [message]

        let snapshot = model.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.modelTitle, "claude-custom")
        XCTAssertEqual(snapshot.displayedModelReference?.providerID, "custom-router")
        XCTAssertEqual(snapshot.modelProviderName, "custom-router")
        XCTAssertNil(snapshot.selectedModelReference)
    }

    func testDisplayedProviderFollowsEffectiveDefault() {
        let model = makeViewModel()
        let snapshot = model.chatFacade.toolbarSnapshot(for: makeSession(id: "default-provider"))
        XCTAssertEqual(snapshot.modelTitle, "Basic")
        XCTAssertEqual(snapshot.displayedModelReference, .init(providerID: "openai", modelID: "basic"))
        XCTAssertEqual(snapshot.modelProviderName, "OpenAI")
    }

    func testSelectingUnpreparedSessionDoesNotExposePreviousTranscript() {
        let model = AppViewModel()
        let first = makeSession(id: "first")
        let second = makeSession(id: "second")
        model.selectedDirectory = first.directory
        model.allSessions = [first, second]
        model.selectedSession = first
        model.chatStore.beginSelectingSession(sessionID: first.id,
            cachedMessages: [makeMessage(id: "first-message", sessionID: first.id, role: "user")])

        _ = model.beginSessionNavigation(second)

        XCTAssertTrue(model.chatFacade.messageSource(for: second).isEmpty)
        XCTAssertTrue(model.chatFacade.presentationMessages.isEmpty)
    }

    func testInactiveDirectorySelectionCannotReadActiveTranscript() {
        let model = AppViewModel()
        let first = makeSession(id: "first")
        let second = makeSession(id: "second", directory: "/tmp/other")
        model.selectedDirectory = first.directory
        model.allSessions = [first]
        model.selectedSession = first
        model.chatStore.messages = [makeMessage(id: "first-message", sessionID: first.id, role: "user")]
        let other = model.directoryStoreRegistry.store(for: second.directory)
        other.sessions = [second]
        other.selectedSession = second

        XCTAssertTrue(model.chatFacade.messageSource(for: second).isEmpty)
    }

    func testActiveTranscriptFallbackFiltersEveryEnvelopeBySession() {
        let model = AppViewModel()
        let second = makeSession(id: "second")
        model.selectedDirectory = second.directory
        model.selectedSession = second
        let expected = makeMessage(id: "second-message", sessionID: second.id, role: "user")
        model.chatStore.beginSelectingSession(sessionID: second.id, cachedMessages: [
            makeMessage(id: "first-message", sessionID: "first", role: "assistant"), expected,
        ])

        XCTAssertEqual(model.chatFacade.messageSource(for: second), [expected])
        XCTAssertEqual(model.chatFacade.presentationMessages, [expected])
        model.selectedSession = nil
        XCTAssertTrue(model.chatFacade.presentationMessages.isEmpty)
    }

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: "opencode.modelVisibility.v1")
        UserDefaults.standard.removeObject(forKey: "chatBreadcrumbs")
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: "opencode.modelVisibility.v1")
        UserDefaults.standard.removeObject(forKey: "chatBreadcrumbs")
        super.tearDown()
    }

    func testSnapshotContainsSelectedValuesAndTitles() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-selected")
        let modelReference = OpenCodeModelReference(providerID: "openai", modelID: "reasoner")

        viewModel.chatFacade.selectAgent(named: "review", for: session)
        viewModel.chatFacade.selectModel(modelReference, for: session)
        viewModel.chatFacade.selectReasoningVariant("deep_think", for: session)

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(snapshot.selectedAgentName, "review")
        XCTAssertEqual(snapshot.selectedModelReference, modelReference)
        XCTAssertEqual(snapshot.selectedReasoningVariant, "deep_think")
        XCTAssertEqual(snapshot.agentTitle, "review")
        XCTAssertEqual(snapshot.modelTitle, "Reasoner")
        XCTAssertEqual(snapshot.reasoningTitle, "Deep Think")
    }

    func testCreationOnlyAgentUsesCanonicalSessionAndHiddenDisplayMetadata() {
        let viewModel = makeViewModel()
        installAgentPolicy(.creationOnly, in: viewModel)
        var session = makeSession(id: "creation-only-canonical")
        session.agent = "custom-review"
        var preset = OpenCodeAgent(name: "custom-review", description: "Reviews changes carefully.",
            mode: "primary", hidden: true, model: nil, variant: nil)
        preset.displayName = "My Review Agent"
        viewModel.modelConfigurationStore.availableAgents.append(preset)
        viewModel.modelConfigurationStore.selectAgent(named: "build", forSessionID: session.id)
        viewModel.selectedSession = session
        viewModel.messages = [makeMessage(id: "prior-user", sessionID: session.id, role: "user", agent: "review")]

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(snapshot.selectedAgentName, "custom-review")
        XCTAssertEqual(snapshot.agentTitle, "My Review Agent")
        XCTAssertEqual(snapshot.agentDescription, "Reviews changes carefully.")
        XCTAssertTrue(snapshot.isAgentReadOnly)
        XCTAssertFalse(snapshot.isAgentLoading)
        XCTAssertFalse(snapshot.selectableAgents.contains { $0.name == "custom-review" })
    }

    func testCreationOnlyAgentFallsBackToRawIDOrDefaultNotRememberedChoice() {
        let viewModel = makeViewModel()
        installAgentPolicy(.creationOnly, in: viewModel)
        var session = makeSession(id: "creation-only-fallback")
        session.agent = "unlisted-MixedCase-preset"
        viewModel.modelConfigurationStore.selectAgent(named: "review", forSessionID: session.id)
        viewModel.selectedSession = session
        viewModel.isLoadingSelectedSession = true
        viewModel.messages = [makeMessage(id: "prior-user", sessionID: session.id, role: "user", agent: "build")]

        var snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.agentTitle, "unlisted-MixedCase-preset")
        XCTAssertNil(snapshot.agentDescription)

        session.agent = nil
        snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.agentTitle, String(localized: "Default"))
        XCTAssertNil(snapshot.selectedAgentName)
        XCTAssertNil(snapshot.agentDescription)
        XCTAssertFalse(snapshot.isAgentLoading)
    }

    func testCreationOnlyAgentCannotBeChangedEvenInBlankSession() {
        let viewModel = makeViewModel()
        installAgentPolicy(.mutable, in: viewModel)
        var session = makeSession(id: "creation-only-blank")
        session.agent = "build"
        viewModel.selectedDirectory = session.directory
        viewModel.allSessions = [session]
        viewModel.selectedSession = session
        viewModel.isConnected = true
        let facade = viewModel.chatFacade
        XCTAssertTrue(facade.allowsHeaderAgentSelection(facade.headerScope(for: session)))

        installAgentPolicy(.creationOnly, in: viewModel)
        let scope = facade.headerScope(for: session)
        XCTAssertTrue(facade.isCurrentHeaderScope(scope))
        XCTAssertFalse(facade.allowsHeaderAgentSelection(scope))
        facade.selectHeaderAgent(named: "review", scope: scope)
        facade.selectAgent(named: "review", for: session)
        XCTAssertNil(viewModel.modelConfigurationStore.selectedAgentName(for: session.id))
        XCTAssertEqual(facade.toolbarSnapshot(for: session).agentTitle, "build")
    }

    func testHeaderPermissionsReadCanonicalOwnerAndRouteWhileSessionRunning() async throws {
        let (model, session, service) = permissionFixture()
        let facade = model.chatFacade
        let scope = facade.headerScope(for: session)
        var current = session
        current.permissions = .init(currentPreset: "auto")
        facade.directoryStore(forSessionID: session.id).upsertSessions([current])
        facade.directoryStore(forSessionID: session.id).applySessionStatus("busy", forSessionID: session.id)
        XCTAssertEqual(scope.session.permissions?.currentPreset, "workspace-write")
        XCTAssertEqual(facade.headerPermissions(scope)?.currentPreset, "auto")
        XCTAssertTrue(facade.supportsHeaderPermissions(scope))
        service.beforeSet = {
            XCTAssertEqual(facade.headerPermissions(scope)?.currentPreset, "auto", "No optimistic full-access change")
        }
        let result = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertTrue(result)
        XCTAssertEqual(facade.headerPermissions(scope)?.currentPreset, "danger-full-access")
        XCTAssertEqual(service.writes.first?.0, session.id)
        XCTAssertEqual(service.writes.first?.1, .fullAccess)
        XCTAssertEqual(service.writes.first?.2, .init(projectID: session.projectID, directory: session.directory, workspaceID: session.workspaceID))
    }

    func testHeaderPermissionsUnknownRequiresRefreshBeforeAnyWrite() async {
        let (model, session, service) = permissionFixture(current: nil)
        let facade = model.chatFacade
        let scope = facade.headerScope(for: session)
        XCTAssertTrue(facade.supportsHeaderPermissions(scope))
        XCTAssertNil(facade.headerPermissions(scope)?.currentPreset)
        let blocked = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertFalse(blocked)
        XCTAssertTrue(service.writes.isEmpty)
        service.session.permissions = .init(currentPreset: "custom")
        let loaded = await facade.refreshHeaderPermissions(scope)
        XCTAssertTrue(loaded)
        XCTAssertEqual(facade.headerPermissions(scope)?.currentPreset, "custom")
        XCTAssertEqual(service.reads.first?.0, session.id)
    }

    func testHeaderPermissionsFailedWriteRereadsAppliedServerValue() async {
        let (model, session, service) = permissionFixture()
        let facade = model.chatFacade
        let scope = facade.headerScope(for: session)
        service.writeError = URLError(.networkConnectionLost)
        let result = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertFalse(result)
        XCTAssertEqual(service.reads.count, 1)
        XCTAssertEqual(facade.headerPermissions(scope)?.currentPreset, "danger-full-access")
        XCTAssertNotNil(facade.presentationErrorMessage)
    }

    func testHeaderPermissionsFailedWriteAndReadBecomeUnknownNotRolledBack() async {
        let (model, session, service) = permissionFixture()
        let facade = model.chatFacade
        let scope = facade.headerScope(for: session)
        service.writeError = URLError(.networkConnectionLost)
        service.readError = URLError(.networkConnectionLost)
        let result = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertFalse(result)
        XCTAssertNotNil(facade.headerPermissions(scope))
        XCTAssertNil(facade.headerPermissions(scope)?.currentPreset)
        XCTAssertNotNil(facade.presentationErrorMessage)
    }

    func testHeaderPermissionsRejectStaleReadOnlyDisconnectedAndUnsupportedScopes() async {
        let (model, session, service) = permissionFixture()
        let facade = model.chatFacade
        let scope = facade.headerScope(for: session)
        model.backendMode = .cachedServer
        XCTAssertFalse(facade.supportsHeaderPermissions(scope))
        let cached = await facade.refreshHeaderPermissions(scope)
        XCTAssertFalse(cached)
        model.backendMode = .server
        model.isConnected = false
        let disconnected = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertFalse(disconnected)
        model.isConnected = true
        model.selectedSession = makeSession(id: "other")
        let stale = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertFalse(stale)
        model.selectedSession = session
        installAgentPolicy(.creationOnly, in: model)
        XCTAssertFalse(facade.supportsHeaderPermissions(facade.headerScope(for: session)))
        XCTAssertTrue(service.writes.isEmpty)
        XCTAssertTrue(service.reads.isEmpty)
    }

    func testHeaderPermissionsLateNavigationResponseCannotMutateOrReportInNewScope() async {
        let (model, session, service) = permissionFixture()
        let facade = model.chatFacade
        let scope = facade.headerScope(for: session)
        let other = makeSession(id: "other-permission-chat")
        service.beforeSet = {
            model.allSessions = [session, other]
            model.selectedSession = other
        }
        service.writeError = URLError(.networkConnectionLost)
        let result = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertFalse(result)
        XCTAssertTrue(service.reads.isEmpty)
        XCTAssertNil(facade.presentationErrorMessage)
        XCTAssertEqual(facade.directoryStore(forSessionID: session.id).sessions.first { $0.id == session.id }?.permissions?.currentPreset, "workspace-write")
        XCTAssertNil(facade.directoryStore(forSessionID: other.id).sessions.first { $0.id == other.id }?.permissions)
    }

    func testHeaderPermissionsLateConnectionResponseIsDiscarded() async {
        let (model, session, service) = permissionFixture()
        let facade = model.chatFacade
        let scope = facade.headerScope(for: session)
        service.beforeSet = { self.installAgentPolicy(.creationOnly, in: model) }
        service.writeError = URLError(.networkConnectionLost)
        let result = await facade.setHeaderPermissions(.fullAccess, scope: scope)
        XCTAssertFalse(result)
        XCTAssertTrue(service.reads.isEmpty)
        XCTAssertNil(facade.presentationErrorMessage)
        XCTAssertEqual(facade.directoryStore(forSessionID: session.id).sessions.first { $0.id == session.id }?.permissions?.currentPreset, "workspace-write")
    }

    private func permissionFixture(current: String? = "workspace-write") -> (AppViewModel, OpenCodeSession, HeaderPermissionTestService) {
        let model = makeViewModel()
        var session = makeSession(id: "permission-session")
        session.permissions = .init(currentPreset: current)
        let service = HeaderPermissionTestService(session: session)
        let backend = HomeTestBackend()
        model.backendConnection = BackendConnection(descriptor: .init(id: "permission-test", name: "Test", version: "1"),
            capabilities: [.sessionPermissions], projects: backend, sessions: backend, chat: backend, models: backend, events: backend,
            sessionPermissions: service)
        model.selectedDirectory = session.directory
        model.allSessions = [session]
        model.selectedSession = session
        model.isConnected = true
        return (model, session, service)
    }

    private func installAgentPolicy(_ policy: BackendAgentSelectionPolicy, in viewModel: AppViewModel) {
        let backend = HomeTestBackend()
        viewModel.backendConnection = BackendConnection(descriptor: .init(id: "agent-policy-test", name: "Test", version: "1"),
            projects: backend, sessions: backend, chat: backend, models: backend, events: backend,
            agentSelectionPolicy: policy)
    }

    func testServerContextMetricsPreservesLegacyOpenCodePath() {
        let model = makeViewModel()
        let session = makeSession(id: "legacy-metrics")
        model.selectedDirectory = session.directory
        model.allSessions = [session]
        model.selectedSession = session
        XCTAssertNil(model.chatFacade.serverContextMetrics(for: session.id))
    }

    func testServerContextMetricsUnknownDSHNeverFallsBackToTranscriptCounts() throws {
        let model = makeViewModel()
        installMetadataBackend(in: model)
        let session = makeSession(id: "unknown-dsh-metrics")
        model.selectedDirectory = session.directory
        model.allSessions = [session]
        model.selectedSession = session
        model.messages = [makeMessage(id: "message", sessionID: session.id, role: "assistant")]
        let metrics = try XCTUnwrap(model.chatFacade.serverContextMetrics(for: session.id))
        XCTAssertNil(metrics.context)
        XCTAssertNil(metrics.totalCost)
        XCTAssertNil(metrics.messageCount)
        XCTAssertNotNil(metrics.metadataSections)
        XCTAssertTrue(metrics.breakdown.isEmpty)
    }

    func testServerContextMetricsReadsCanonicalUpdatesWhileBusyAndDistinguishesZero() throws {
        let model = makeViewModel()
        installMetadataBackend(in: model)
        let initial = metadataSession(id: "live-metrics", tokens: 0)
        model.selectedDirectory = initial.directory
        model.allSessions = [initial]
        model.selectedSession = initial
        let facade = model.chatFacade
        let owner = facade.directoryStore(forSessionID: initial.id)
        owner.applySessionStatus("busy", forSessionID: initial.id)
        let zero = try XCTUnwrap(facade.serverContextMetrics(for: initial.id))
        XCTAssertEqual(zero.context?.total, 0)
        XCTAssertEqual(zero.context?.usage, 0)
        owner.upsertSessions([metadataSession(id: initial.id, tokens: 500)])
        let updated = try XCTUnwrap(facade.serverContextMetrics(for: initial.id))
        XCTAssertEqual(updated.context?.total, 500)
        XCTAssertEqual(updated.context?.usage, 50)
        XCTAssertEqual(owner.sessionStatuses[initial.id], "busy")
        XCTAssertNil(updated.totalCost)
        XCTAssertTrue(updated.breakdown.isEmpty)
        owner.upsertSessions([metadataSession(id: initial.id, tokens: 500, isCurrent: false)])
        let stale = try XCTUnwrap(facade.serverContextMetrics(for: initial.id))
        XCTAssertNil(stale.context)
        XCTAssertNotNil(stale.metadataSections)
    }

    func testServerContextMetricsDoesNotLeakAcrossSelectionOrMissingSession() throws {
        let model = makeViewModel()
        installMetadataBackend(in: model)
        let first = metadataSession(id: "first-metrics", tokens: 500)
        let second = metadataSession(id: "second-metrics", tokens: 100)
        model.selectedDirectory = first.directory
        model.allSessions = [first, second]
        model.selectedSession = first
        let facade = model.chatFacade
        XCTAssertEqual(facade.serverContextMetrics(for: first.id)?.context?.total, 500)
        model.selectedSession = second
        XCTAssertNil(try XCTUnwrap(facade.serverContextMetrics(for: first.id)).context)
        XCTAssertEqual(facade.serverContextMetrics(for: second.id)?.context?.total, 100)
        XCTAssertNil(try XCTUnwrap(facade.serverContextMetrics(for: "missing")).context)
    }

    func testServerContextMetricsDoesNotClaimCachedValuesAreLiveAfterDisconnect() throws {
        let model = makeViewModel()
        installMetadataBackend(in: model)
        let session = metadataSession(id: "disconnected-metrics", tokens: 500)
        model.selectedDirectory = session.directory
        model.allSessions = [session]
        model.selectedSession = session
        XCTAssertEqual(model.chatFacade.serverContextMetrics(for: session.id)?.context?.total, 500)
        model.isConnected = false
        XCTAssertNil(try XCTUnwrap(model.chatFacade.serverContextMetrics(for: session.id)).context)
        model.backendConnection = nil
        XCTAssertNil(try XCTUnwrap(model.chatFacade.serverContextMetrics(for: session.id)).context)
    }

    func testServerContextMetricsUsesWindowOwnerAndInvalidatesReplacedConnection() throws {
        let model = makeViewModel()
        installMetadataBackend(in: model)
        model.isConnected = true
        let first = metadataSession(id: "window-first", tokens: 100)
        let second = metadataSession(id: "window-second", tokens: 500, directory: "/tmp/other-metadata")
        let firstOwner = model.directoryStoreRegistry.store(for: first.directory)
        let secondOwner = model.directoryStoreRegistry.store(for: second.directory)
        firstOwner.upsertSessions([first])
        secondOwner.upsertSessions([second])
        let connection = try XCTUnwrap(model.backendConnection)
        let firstWindow = ChatWindowContext(model: model, connection: connection, session: first, owner: firstOwner)
        let secondWindow = ChatWindowContext(model: model, connection: connection, session: second, owner: secondOwner)
        defer { firstWindow.close(); secondWindow.close() }
        let firstFacade = ChatFacade(viewModel: model, windowContext: firstWindow)
        let secondFacade = ChatFacade(viewModel: model, windowContext: secondWindow)
        XCTAssertEqual(firstFacade.serverContextMetrics(for: first.id)?.context?.total, 100)
        XCTAssertEqual(secondFacade.serverContextMetrics(for: second.id)?.context?.total, 500)
        XCTAssertNil(try XCTUnwrap(firstFacade.serverContextMetrics(for: second.id)).context)
        installMetadataBackend(in: model)
        XCTAssertFalse(firstWindow.isCurrent)
        XCTAssertNil(try XCTUnwrap(firstFacade.serverContextMetrics(for: first.id)).context)
    }

    private func metadataSession(id: String, tokens: Int, isCurrent: Bool = true, directory: String = "/tmp/project") -> OpenCodeSession {
        var session = makeSession(id: id, directory: directory)
        session.backendMetadata = .init(projections: [
            "contextPressure": .object(["projectedTokens": .number(Double(tokens)), "pressureTokens": .number(99), "contextWindow": .number(1000)])
        ], isCurrent: isCurrent, createdAt: nil, origin: nil, isSeeded: nil, delegationDepth: nil, version: nil)
        return session
    }

    private func installMetadataBackend(in model: AppViewModel) {
        let backend = HomeTestBackend()
        model.backendConnection = BackendConnection(descriptor: .init(id: "metadata-test", name: "Test", version: "1"),
            capabilities: [.sessionMetadata], projects: backend, sessions: backend, chat: backend, models: backend, events: backend)
        model.isConnected = true
    }

    func testToolbarSnapshotChangesAfterEachPickerSelection() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-picker-updates")
        var previous = viewModel.chatFacade.toolbarSnapshot(for: session)

        viewModel.chatFacade.selectAgent(named: "review", for: session)
        var current = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertNotEqual(current, previous)
        previous = current

        viewModel.chatFacade.selectModel(
            OpenCodeModelReference(providerID: "openai", modelID: "reasoner"),
            for: session
        )
        current = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertNotEqual(current, previous)
        previous = current

        viewModel.chatFacade.selectReasoningVariant("high", for: session)
        current = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertNotEqual(current, previous)
    }

    func testSnapshotUsesLatestUserMessageAsToolbarFallback() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-message")
        viewModel.selectedSession = session
        viewModel.isLoadingSelectedSession = true
        viewModel.messages = [
            makeMessage(id: "message-001", sessionID: session.id, role: "user", agent: "build", modelID: "basic"),
            makeMessage(id: "message-002", sessionID: session.id, role: "assistant"),
            makeMessage(id: "message-003", sessionID: session.id, role: "user", agent: "  review  ", modelID: "reasoner"),
        ]

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(snapshot.agentTitle, "review")
        XCTAssertEqual(snapshot.modelTitle, "Reasoner")
        XCTAssertEqual(snapshot.displayedModelReference, .init(providerID: "openai", modelID: "reasoner"))
        XCTAssertEqual(snapshot.modelProviderName, "OpenAI")
        XCTAssertFalse(snapshot.isLoading)
    }

    func testSnapshotUsesLoadingPlaceholdersBeforeSelectionHydrates() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-loading")
        viewModel.selectedSession = session
        viewModel.isLoadingSelectedSession = true

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertEqual(snapshot.agentTitle, "Agent")
        XCTAssertEqual(snapshot.modelTitle, "Model")
        XCTAssertNil(snapshot.displayedModelReference)
        XCTAssertNil(snapshot.modelProviderName)
        XCTAssertTrue(snapshot.isAgentLoading)
        XCTAssertTrue(snapshot.isModelLoading)
        XCTAssertTrue(snapshot.isLoading)
    }

    func testSnapshotContainsSortedProviderGroupsWithVisibleModelsOnly() throws {
        let viewModel = makeViewModel()
        let hiddenReference = OpenCodeModelReference(providerID: "openai", modelID: "basic")
        viewModel.modelConfigurationStore.setModelVisibility(hiddenReference, isVisible: false)

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: makeSession(id: "session-providers"))
        let openAI = try XCTUnwrap(snapshot.providerGroups.first { $0.id == "openai" })

        XCTAssertEqual(snapshot.providerGroups.map(\.id), ["anthropic", "openai"])
        XCTAssertEqual(openAI.models.map(\.id), ["reasoner"])
    }

    func testSnapshotPreparesReasoningVariantsAndDefaultTitle() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-reasoning")
        viewModel.chatFacade.selectModel(
            OpenCodeModelReference(providerID: "openai", modelID: "reasoner"),
            for: session
        )

        var snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.reasoningVariants.map(\.id), ["deep_think", "high"])
        XCTAssertEqual(snapshot.reasoningVariants.map(\.title), ["Deep Think", "High"])
        XCTAssertEqual(snapshot.reasoningTitle, "Default")

        viewModel.chatFacade.selectReasoningVariant("high", for: session)
        snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)
        XCTAssertEqual(snapshot.reasoningTitle, "High")
    }

    func testSelectionIntentsRemainIsolatedBySession() {
        let viewModel = makeViewModel()
        let first = makeSession(id: "session-first")
        let second = makeSession(id: "session-second")
        let reference = OpenCodeModelReference(providerID: "openai", modelID: "reasoner")

        viewModel.chatFacade.selectAgent(named: "review", for: first)
        viewModel.chatFacade.selectModel(reference, for: first)
        viewModel.chatFacade.selectReasoningVariant("high", for: first)

        let firstSnapshot = viewModel.chatFacade.toolbarSnapshot(for: first)
        let secondSnapshot = viewModel.chatFacade.toolbarSnapshot(for: second)

        XCTAssertEqual(firstSnapshot.selectedAgentName, "review")
        XCTAssertEqual(firstSnapshot.selectedModelReference, reference)
        XCTAssertEqual(firstSnapshot.selectedReasoningVariant, "high")
        XCTAssertNil(secondSnapshot.selectedAgentName)
        XCTAssertNil(secondSnapshot.selectedModelReference)
        XCTAssertNil(secondSnapshot.selectedReasoningVariant)
    }

    func testGameSessionHidesAgentMenuAndDoesNotWaitForAgentSelection() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-game")
        viewModel.selectedSession = session
        viewModel.isLoadingSelectedSession = true
        viewModel.funAndGamesStore.recordFindBugSession(
            FindBugGameSession(sessionID: session.id, language: FindBugGameLanguage(id: "swift", title: "Swift"))
        )
        viewModel.chatFacade.selectModel(
            OpenCodeModelReference(providerID: "openai", modelID: "reasoner"),
            for: session
        )

        let snapshot = viewModel.chatFacade.toolbarSnapshot(for: session)

        XCTAssertFalse(snapshot.showsAgentMenu)
        XCTAssertFalse(snapshot.isAgentLoading)
        XCTAssertFalse(snapshot.isLoading)
        XCTAssertEqual(snapshot.agentTitle, "plan")
    }

    func testForkSessionSnapshotContainsForkableMessagesAndPendingState() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-fork")
        viewModel.selectedSession = session
        viewModel.messages = [
            OpenCodeMessageEnvelope.local(
                role: "user",
                text: "First prompt",
                messageID: "message-first",
                sessionID: session.id
            ),
            OpenCodeMessageEnvelope.local(
                role: "assistant",
                text: "Response",
                messageID: "message-response",
                sessionID: session.id
            ),
            OpenCodeMessageEnvelope.local(
                role: "user",
                text: "Latest\nprompt",
                messageID: "message-latest",
                sessionID: session.id
            ),
        ]
        viewModel.chatPresentationStore.pendingForkMessageID = "message-latest"

        let snapshot = viewModel.chatFacade.forkSessionSnapshot

        XCTAssertEqual(snapshot.messages.map(\.id), ["message-latest", "message-first"])
        XCTAssertEqual(snapshot.messages.map(\.text), ["Latest prompt", "First prompt"])
        XCTAssertEqual(snapshot.pendingMessageID, "message-latest")
    }

    func testTodoInspectorSnapshotUsesSelectedSessionTodos() {
        let viewModel = makeViewModel()
        let session = makeSession(id: "session-todos")
        let todos = [makeTodo(content: "Canonical todo")]
        viewModel.selectedSession = session
        viewModel.directoryStore.applyTodos(todos, forSessionID: session.id)
        viewModel.sessionInteractionStore.todos = [makeTodo(content: "Compatibility fallback")]

        let snapshot = viewModel.chatFacade.todoInspectorSnapshot

        XCTAssertEqual(snapshot.selectedSessionID, session.id)
        XCTAssertEqual(snapshot.todos, todos)
    }

    func testTodoRefreshStateKeepsSuccessfulEmptyResultDistinctFromUnrefreshedState() {
        let fallback = [makeTodo(content: "Stale todo")]
        var state = TodoInspectorRefreshState()

        XCTAssertEqual(state.visibleTodos(fallback: fallback), fallback)

        state.apply([])

        XCTAssertEqual(state.refreshedTodos, [])
        XCTAssertEqual(state.visibleTodos(fallback: fallback), [])
    }

    func testObservationRebindsToNewActiveDirectoryStoreAndSyncStore() async {
        let viewModel = makeViewModel()
        let facade = viewModel.chatFacade
        let oldStore = viewModel.directoryStoreRegistry.activeStore
        let newStore = viewModel.directoryStoreRegistry.activate("/tmp/other")

        // Rebinding and activation invalidations are queued on main before this checkpoint.
        let activated = expectation(description: "Active directory observation rebound")
        DispatchQueue.main.async { activated.fulfill() }
        await fulfillment(of: [activated], timeout: 1)

        var changeCount = 0
        var pendingChange: XCTestExpectation?
        let observation = facade.objectWillChange.sink {
            changeCount += 1
            pendingChange?.fulfill()
            pendingChange = nil
        }

        oldStore.selectedSession = makeSession(id: "session-old")
        oldStore.applyTodos([makeTodo(content: "Old")], forSessionID: "session-old")

        // Drain queued forwarding before checking that old-store subscriptions were detached.
        let oldStoreDelivered = expectation(description: "Old directory notification queue drained")
        DispatchQueue.main.async { oldStoreDelivered.fulfill() }
        await fulfillment(of: [oldStoreDelivered], timeout: 1)
        XCTAssertEqual(changeCount, 0)

        let selectionChanged = expectation(description: "New active directory changes delivered")
        pendingChange = selectionChanged
        newStore.selectedSession = makeSession(id: "session-new")
        await fulfillment(of: [selectionChanged], timeout: 1)
        let selectionDrained = expectation(description: "Selection notifications drained")
        DispatchQueue.main.async { selectionDrained.fulfill() }
        await fulfillment(of: [selectionDrained], timeout: 1)
        // Derived snapshots can publish more than once; forwarding is not one-to-one.
        XCTAssertGreaterThan(changeCount, 0)
        XCTAssertEqual(facade.todoInspectorSnapshot.selectedSessionID, "session-new")

        let selectionChangeCount = changeCount
        let syncChanged = expectation(description: "New active sync store change delivered")
        pendingChange = syncChanged
        let todos = [makeTodo(content: "New")]
        newStore.applyTodos(todos, forSessionID: "session-new")

        await fulfillment(of: [syncChanged], timeout: 1)
        XCTAssertGreaterThan(changeCount, selectionChangeCount)
        XCTAssertEqual(facade.todoInspectorSnapshot.todos, todos)
        withExtendedLifetime(observation) {}
    }

    func testDismissForkPresentationDoesNotChangeSelectionOrPendingAction() {
        let viewModel = makeViewModel()
        let selectedSession = makeSession(id: "session-selected")
        viewModel.selectedSession = selectedSession
        viewModel.chatPresentationStore.isShowingForkSessionSheet = true
        viewModel.chatPresentationStore.pendingForkSessionID = selectedSession.id
        viewModel.chatPresentationStore.pendingForkMessageID = "message-pending"

        viewModel.chatFacade.dismissForkSessionSheet()

        XCTAssertFalse(viewModel.chatPresentationStore.isShowingForkSessionSheet)
        XCTAssertEqual(viewModel.selectedSession?.id, selectedSession.id)
        XCTAssertEqual(viewModel.chatPresentationStore.pendingForkSessionID, selectedSession.id)
        XCTAssertEqual(viewModel.chatPresentationStore.pendingForkMessageID, "message-pending")
    }

    func testDirectoryStoreResolvesSessionOwnerInsteadOfStaleActiveStore() {
        let viewModel = makeViewModel()
        let activeStore = viewModel.directoryStoreRegistry.activeStore
        let ownerStore = viewModel.directoryStoreRegistry.store(for: "/tmp/owner")
        let session = makeSession(id: "session-owned")
        ownerStore.sessions = [session]

        XCTAssertTrue(viewModel.chatFacade.directoryStore(forSessionID: session.id) === ownerStore)
        XCTAssertFalse(viewModel.chatFacade.directoryStore(forSessionID: session.id) === activeStore)
        XCTAssertTrue(viewModel.chatFacade.directoryStore(forSessionID: "session-unknown") === activeStore)
    }

    func testChatWindowRoutePreservesServerAndOwningDirectory() {
        let viewModel = makeViewModel()
        viewModel.config = OpenCodeServerConfig(
            name: "Test",
            baseURL: "https://example.com",
            username: "tester"
        )
        let ownerStore = viewModel.directoryStoreRegistry.store(for: "/tmp/owner")
        let session = makeSession(id: "session-window")
        ownerStore.sessions = [session]

        let route = viewModel.chatFacade.windowRoute(for: session)

        XCTAssertEqual(route.serverID, "https://example.com|tester")
        XCTAssertEqual(route.directoryKey, "/tmp/owner")
        XCTAssertEqual(route.sessionID, session.id)
        XCTAssertTrue(
            viewModel.chatFacade.directoryStore(
                forSessionID: "session-not-hydrated",
                preferredDirectoryKey: route.directoryKey
            ) === ownerStore
        )
    }

    func testActiveChatLifecycleClearsOnlyMatchingSessionAndUpdatesChatStore() {
        let viewModel = makeViewModel()
        let facade = viewModel.chatFacade

        facade.setActiveChatSessionID("session-first")
        XCTAssertEqual(facade.activeChatSessionID, "session-first")
        XCTAssertEqual(viewModel.chatStore.activeChatSessionID, "session-first")

        facade.setActiveChatSessionID("session-newer")
        facade.clearActiveChatSessionIfMatching("session-first")
        XCTAssertEqual(facade.activeChatSessionID, "session-newer")
        XCTAssertEqual(viewModel.chatStore.activeChatSessionID, "session-newer")

        facade.clearActiveChatSessionIfMatching("session-newer")
        XCTAssertNil(facade.activeChatSessionID)
        XCTAssertNil(viewModel.chatStore.activeChatSessionID)
    }

    func testComposerOverlaySnapshotPreservesStoreInputsAndSessionFiltering() {
        let viewModel = makeViewModel()
        let sessionID = "session-overlay"
        let todo = makeTodo(content: "Inspect overlay")
        let attachment = OpenCodeComposerAttachment(
            id: "attachment-1",
            kind: .file,
            filename: "notes.txt",
            mime: "text/plain",
            dataURL: "data:text/plain;base64,QQ=="
        )
        let permission = OpenCodePermission(
            id: "permission-1",
            sessionID: sessionID,
            permission: "edit",
            patterns: [],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let otherPermission = OpenCodePermission(
            id: "permission-other",
            sessionID: "session-other",
            permission: "edit",
            patterns: [],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let question = OpenCodeQuestionRequest(
            id: "question-1",
            sessionID: sessionID,
            questions: [],
            tool: nil
        )
        viewModel.sessionInteractionStore.todos = [todo]
        viewModel.sessionInteractionStore.permissions = [permission, otherPermission]
        viewModel.sessionInteractionStore.questions = [question]
        viewModel.composerStore.draftAttachments = [attachment]

        let snapshot: ChatFacade.ChatComposerOverlaySnapshot = viewModel.chatFacade.composerOverlaySnapshot(
            forSessionID: sessionID
        )

        XCTAssertEqual(snapshot.todos, [todo])
        XCTAssertEqual(snapshot.attachmentIDs, [attachment.id])
        XCTAssertEqual(snapshot.permissions, [permission])
        XCTAssertEqual(snapshot.questions, [question])
        XCTAssertEqual(snapshot.incompleteTodoIDs, [todo.id])
        XCTAssertTrue(snapshot.showsAccessoryArea)
    }

    func testComposerOverlaySnapshotBubblesChildSessionInteractionsToParent() {
        let viewModel = makeViewModel()
        let parent = makeSession(id: "session-parent")
        let child = OpenCodeSession(
            id: "session-child",
            title: "Child",
            workspaceID: nil,
            directory: parent.directory,
            projectID: parent.projectID,
            parentID: parent.id
        )
        let permission = OpenCodePermission(
            id: "permission-child",
            sessionID: child.id,
            permission: "bash",
            patterns: ["git status"],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let question = OpenCodeQuestionRequest(
            id: "question-child",
            sessionID: child.id,
            questions: [],
            tool: nil
        )
        viewModel.directoryStore.sessions = [parent, child]
        viewModel.sessionInteractionStore.permissions = [permission]
        viewModel.sessionInteractionStore.questions = [question]

        let snapshot = viewModel.chatFacade.composerOverlaySnapshot(forSessionID: parent.id)

        XCTAssertEqual(snapshot.permissions, [permission])
        XCTAssertEqual(snapshot.questions, [question])
    }

    func testComposerSnapshotContainsPreparedComposerState() {
        let viewModel = makeViewModel()
        viewModel.backendConnection = OpenCodeBackendFactory(client: OpenCodeAPIClient(config: .init()), eventManager: viewModel.eventManager)
            .makeConnection(profile: .legacy, version: "test", healthy: true)
        let session = makeSession(id: "session-composer")
        viewModel.selectedSession = session
        viewModel.directoryStore.commands = [makeCommand(name: "explain")]
        viewModel.messages = [
            OpenCodeMessageEnvelope.local(
                role: "user",
                text: "Fork this",
                messageID: "message-user",
                sessionID: session.id
            ),
        ]
        viewModel.composerStore.draftAttachments = [
            OpenCodeComposerAttachment(
                id: "attachment-1",
                kind: .file,
                filename: "notes.txt",
                mime: "text/plain",
                dataURL: "data:text/plain;base64,QQ=="
            ),
        ]
        viewModel.mcpStore.statuses = [
            "server": OpenCodeMCPStatus(status: "connected", error: nil),
        ]
        viewModel.mcpStore.isLoading = true
        let forkableMessages = viewModel.forkableMessages

        let snapshot = viewModel.chatFacade.composerSnapshot(
            for: session,
            isBusy: true,
            forkableMessages: forkableMessages
        )

        XCTAssertEqual(snapshot.commands.map(\.name), ["explain", "compact", "fork"])
        XCTAssertEqual(snapshot.attachmentCount, 1)
        XCTAssertTrue(snapshot.isBusy)
        XCTAssertTrue(snapshot.canFork)
        XCTAssertEqual(snapshot.forkableMessages.map(\.text), ["Fork this"])
        XCTAssertEqual(snapshot.mcp.connectedServerCount, 1)
        XCTAssertTrue(snapshot.mcp.isLoading)
        XCTAssertEqual(snapshot.actionSignature, "session-composer|/tmp/project||project|")
    }

    func testHeaderSnapshotContainsChildSessionTitles() {
        let viewModel = makeViewModel()
        let parent = OpenCodeSession(
            id: "session-parent",
            title: "Parent Chat",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        let child = OpenCodeSession(
            id: "session-child",
            title: "Fix issue (@build subagent)",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: parent.id
        )
        viewModel.directoryStore.sessions = [parent, child]

        let snapshot = viewModel.chatFacade.headerSnapshot(for: child)

        XCTAssertTrue(snapshot.isChildSession)
        XCTAssertEqual(snapshot.parentSession?.id, parent.id)
        XCTAssertEqual(snapshot.parentTitle, "Parent Chat")
        XCTAssertEqual(snapshot.childTitle, "Fix issue")
        XCTAssertEqual(snapshot.navigationTitle, "Fix issue")
    }

    func testSessionForPresentationKeepsParentSelected() async {
        let viewModel = makeViewModel()
        let parent = OpenCodeSession(
            id: "session-parent",
            title: "Parent Chat",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        let child = OpenCodeSession(
            id: "session-child",
            title: "Review changes (@explore subagent)",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: parent.id
        )
        viewModel.directoryStore.sessions = [parent, child]
        viewModel.directoryStore.selectedSession = parent

        let presentedSession = await viewModel.chatFacade.sessionForPresentation(sessionID: child.id)

        XCTAssertEqual(presentedSession?.id, child.id)
        XCTAssertEqual(viewModel.directoryStore.selectedSession?.id, parent.id)
    }

    func testChildSessionToolbarUsesChildMessageMetadataWhileParentIsSelected() {
        let viewModel = makeViewModel()
        let parent = makeSession(id: "session-parent")
        let child = OpenCodeSession(
            id: "session-child",
            title: "Review changes (@explore subagent)",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: parent.id
        )
        viewModel.directoryStore.sessions = [parent, child]
        viewModel.directoryStore.selectedSession = parent
        viewModel.chatStore.messages = [
            makeMessage(id: "parent-message", sessionID: parent.id, role: "assistant", agent: "build", modelID: "basic"),
        ]
        viewModel.directoryStore.applyCanonicalMessages(
            [makeMessage(id: "child-message", sessionID: child.id, role: "assistant", agent: "review", modelID: "reasoner")],
            forSessionID: child.id
        )

        let snapshot = viewModel.chatFacade.childSessionToolbarSnapshot(for: child)

        XCTAssertEqual(snapshot.agentTitle, "review")
        XCTAssertEqual(snapshot.modelTitle, "Reasoner")
    }

    func testPreferenceScopeKeyCoversServerDirectoryGlobalAndAppleIntelligence() {
        let viewModel = makeViewModel()
        viewModel.config = OpenCodeServerConfig(
            name: "Test",
            baseURL: "https://example.com",
            username: "alice",
            password: ""
        )

        XCTAssertEqual(
            viewModel.chatFacade.preferenceScopeKey(),
            "server|\(viewModel.config.recentServerID)|global"
        )

        viewModel.projectStore.selectedDirectory = "/tmp/project"
        XCTAssertEqual(
            viewModel.chatFacade.preferenceScopeKey(),
            "server|\(viewModel.config.recentServerID)|/tmp/project"
        )

        viewModel.connectionStore.backendMode = .appleIntelligence
        viewModel.activeAppleIntelligenceWorkspaceID = "workspace-local"
        XCTAssertEqual(
            viewModel.chatFacade.preferenceScopeKey(),
            "apple-intelligence|workspace-local"
        )
    }

    func testDiagnosticFacadeGettersReflectCompatibilityDiagnostics() {
        let viewModel = makeViewModel()
        let facade = viewModel.chatFacade
        viewModel.chatPresentationStore.isShowingDebugProbe = true

        facade.appendDebugLog("facade diagnostic")
        facade.markChatBreadcrumb("facade breadcrumb", sessionID: "session-debug")

        XCTAssertEqual(facade.debugProbeLogCount, 1)
        XCTAssertEqual(facade.chatBreadcrumbCount, 1)
        XCTAssertTrue(facade.copyDebugProbeLog().contains("facade diagnostic"))
        XCTAssertTrue(facade.copyChatBreadcrumbs().contains("facade breadcrumb"))
    }

    func testStopSessionTargetsTheChatSessionInsteadOfTheSelectedSession() async {
        let viewModel = makeViewModel()
        let selectedSession = makeSession(id: "session-selected")
        let focusedSession = makeSession(id: "session-focused")
        viewModel.selectedSession = selectedSession
        viewModel.connectionStore.backendMode = .appleIntelligence
        viewModel.sessionStatuses[selectedSession.id] = "busy"
        viewModel.sessionStatuses[focusedSession.id] = "busy"

        await viewModel.chatFacade.stopSession(focusedSession)

        XCTAssertEqual(viewModel.sessionStatuses[focusedSession.id], "idle")
        XCTAssertEqual(viewModel.sessionStatuses[selectedSession.id], "busy")
    }

    private func makeViewModel() -> AppViewModel {
        let viewModel = AppViewModel()
        viewModel.modelConfigurationStore.availableAgents = [
            OpenCodeAgent(name: "review", description: nil, mode: "primary", hidden: false, model: nil, variant: nil),
            OpenCodeAgent(name: "build", description: nil, mode: "primary", hidden: false, model: nil, variant: nil),
        ]
        viewModel.modelConfigurationStore.applyProviderState(
            OpenCodeProviderListResponse(
                all: [
                    OpenCodeProvider(
                        id: "openai",
                        name: "OpenAI",
                        models: [
                            "basic": makeModel(id: "basic", providerID: "openai", name: "Basic"),
                            "reasoner": makeModel(
                                id: "reasoner",
                                providerID: "openai",
                                name: "Reasoner",
                                reasoning: true,
                                variants: ["high": .bool(true), "deep_think": .bool(true)]
                            ),
                        ]
                    ),
                    OpenCodeProvider(
                        id: "anthropic",
                        name: "Anthropic",
                        models: ["sonnet": makeModel(id: "sonnet", providerID: "anthropic", name: "Sonnet")]
                    ),
                ],
                connected: ["openai", "anthropic"],
                default: ["openai": "basic"]
            )
        )
        return viewModel
    }

    private func makeSession(id: String, directory: String = "/tmp/project") -> OpenCodeSession {
        OpenCodeSession(
            id: id,
            title: id,
            workspaceID: nil,
            directory: directory,
            projectID: "project",
            parentID: nil
        )
    }

    private func makeModel(
        id: String,
        providerID: String,
        name: String,
        reasoning: Bool = false,
        variants: [String: OpenCodeJSONValue]? = nil
    ) -> OpenCodeModel {
        OpenCodeModel(
            id: id,
            providerID: providerID,
            name: name,
            capabilities: OpenCodeModelCapabilities(reasoning: reasoning),
            variants: variants
        )
    }

    private func makeCommand(name: String) -> OpenCodeCommand {
        OpenCodeCommand(
            name: name,
            description: name,
            agent: nil,
            model: nil,
            source: "test",
            template: "",
            subtask: false,
            hints: []
        )
    }

    private func makeTodo(content: String) -> OpenCodeTodo {
        OpenCodeTodo(content: content, status: "pending", priority: "medium")
    }

    private func makeMessage(
        id: String,
        sessionID: String,
        role: String,
        agent: String? = nil,
        modelID: String? = nil
    ) -> OpenCodeMessageEnvelope {
        OpenCodeMessageEnvelope(
            info: OpenCodeMessage(
                id: id,
                role: role,
                sessionID: sessionID,
                time: nil,
                agent: agent,
                model: modelID.map { OpenCodeMessageModelReference(providerID: "openai", modelID: $0, variant: nil) }
            ),
            parts: []
        )
    }
}

@MainActor
private final class HeaderPermissionTestService: BackendSessionPermissionsService {
    var session: OpenCodeSession
    var reads: [(String, BackendScope)] = []
    var writes: [(String, BackendSessionPermissionPreset, BackendScope)] = []
    var beforeSet: (() -> Void)?
    var readError: Error?
    var writeError: Error?

    init(session: OpenCodeSession) { self.session = session }

    func refreshPermissions(sessionID: String, scope: BackendScope) async throws -> OpenCodeSession {
        reads.append((sessionID, scope))
        if let readError { throw readError }
        return session
    }

    func setPermissions(sessionID: String, preset: BackendSessionPermissionPreset, scope: BackendScope) async throws -> OpenCodeSession {
        writes.append((sessionID, preset, scope))
        beforeSet?()
        session.permissions = .init(currentPreset: preset.rawValue)
        if let writeError { throw writeError }
        return session
    }
}
