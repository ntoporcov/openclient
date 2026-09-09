import Combine
import XCTest
@testable import OpenClient

@MainActor
final class BackendInjectionTests: XCTestCase {
    private var originalDraftData: Data?

    override func setUp() async throws {
        originalDraftData = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    override func tearDown() async throws {
        UserDefaults.standard.set(originalDraftData, forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    func testFullFacadeFlowUsesInjectedBackendWithoutAnOpenCodeClient() async throws {
        let factory = InjectionTestFactory()
        let viewModel = AppViewModel(backendFactory: factory)
        viewModel.commerceFacade.store.debugEntitlementOverride = .unlocked
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }

        let connection = try viewModel.requireBackendConnection()
        let harness = try XCTUnwrap(factory.harnesses.last)
        XCTAssertTrue(viewModel.connectionFacade.isConnected)
        XCTAssertNil(viewModel.connectionStore.apiProfile)
        XCTAssertEqual(viewModel.projects.map(\.id), ["harness-project"])
        XCTAssertEqual(viewModel.connectionFacade.backendConnectionID, connection.id)
        XCTAssertTrue(viewModel.recentServerConfigs.isEmpty)
        XCTAssertFalse(viewModel.config.hasCredentials)

        let scope = BackendScope(projectID: "harness-project", directory: "/harness")
        let project = try XCTUnwrap(viewModel.projects.first)
        let projectTicket = viewModel.projectFacade.beginSelection(project)
        await viewModel.projectFacade.completeSelection(projectTicket)
        await viewModel.sessionListFacade.refresh()
        XCTAssertEqual(viewModel.sessions.map(\.id), ["harness-existing"])
        XCTAssertTrue(harness.listScopes.contains(scope))
        XCTAssertTrue(harness.catalogScopes.contains(scope))
        XCTAssertEqual(viewModel.availableAgents.map(\.name), ["harness-agent"])

        let existing = try XCTUnwrap(viewModel.sessions.first)
        let ticket = viewModel.sessionListFacade.beginSelection(existing)
        let prepared = await viewModel.sessionListFacade.prepareSelectionForNavigation(ticket)
        XCTAssertTrue(prepared)
        await viewModel.sessionListFacade.completeSelection(ticket)
        XCTAssertEqual(viewModel.chatStore.preparedSessionID, existing.id)
        XCTAssertEqual(viewModel.messages.last?.parts.first?.text, "Earlier answer")
        XCTAssertEqual(viewModel.sessionPreviews[existing.id]?.text, "Earlier answer")

        viewModel.sessionListFacade.presentCreateSession()
        viewModel.sessionListFacade.createSessionTitle = "Boundary"
        await viewModel.sessionListFacade.createSession()
        let session = try XCTUnwrap(viewModel.selectedSession)
        XCTAssertEqual(session.id, "harness-session")
        XCTAssertEqual(harness.creations.last?.scope, scope)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.chatStore.preparedSessionID, session.id)
        viewModel.chatFacade.selectAgent(named: "harness-agent", for: session)
        viewModel.chatFacade.selectModel(.init(providerID: "harness", modelID: "reasoner"), for: session)
        viewModel.chatFacade.selectReasoningVariant("high", for: session)
        viewModel.chatFacade.saveMessageDraft("Hello", forSessionID: session.id)

        let updated = expectation(description: "Injected live answer reaches ChatStore")
        let observation = viewModel.chatStore.$messages.first { messages in
            messages.last?.parts.compactMap(\.text).joined() == "Harness answer"
        }.sink { messages in
            if messages.last?.parts.compactMap(\.text).joined() == "Harness answer" { updated.fulfill() }
        }
        let admitted = await viewModel.chatFacade.sendMessage("Hello", in: session, userVisible: true,
            messageID: "input-1", meterPrompt: false)
        XCTAssertTrue(admitted)
        XCTAssertEqual(harness.submissions.last?.messageID, "input-1")
        XCTAssertEqual(harness.submissions.last?.scope, scope)
        XCTAssertEqual(harness.submissions.last?.agent, "harness-agent")
        XCTAssertEqual(harness.submissions.last?.model, .init(providerID: "harness", modelID: "reasoner"))
        XCTAssertEqual(harness.submissions.last?.variant, "high")
        await fulfillment(of: [updated], timeout: 1)
        observation.cancel()
        XCTAssertEqual(viewModel.messages.last?.parts.compactMap(\.text).joined(), "Harness answer")
        XCTAssertEqual(harness.startCount, 1)

        let rowUpdated = expectation(description: "Normalized live transcript updates regular row snippet")
        let rowObservation = viewModel.sessionListFacade.$snapshot.first { snapshot in
            (snapshot.pinnedRows + snapshot.unpinnedRows).contains { $0.id == session.id && $0.preview?.text == "Harness answer" }
        }.sink { _ in rowUpdated.fulfill() }
        await fulfillment(of: [rowUpdated], timeout: 1)
        rowObservation.cancel()
        await viewModel.chatFacade.stopSession(session)
        XCTAssertEqual(harness.interruptions, [session.id])
        XCTAssertEqual(viewModel.sessionStatuses[session.id], "idle")
        await viewModel.sessionListFacade.rename(session, title: "Renamed")
        XCTAssertEqual(viewModel.selectedSession?.title, "Renamed")
        viewModel.projectFacade.projectSessionSearchQuery = "Renamed"
        await viewModel.projectFacade.searchSessions()
        XCTAssertEqual(viewModel.projectSessionSearchResults.map(\.session.id), [session.id])
        await viewModel.sessionListFacade.delete(session)
        XCTAssertFalse(viewModel.sessions.contains { $0.id == session.id })
        XCTAssertNil(viewModel.selectedSession)
        XCTAssertFalse(harness.storedSessions.contains { $0.id == session.id })
        XCTAssertNil(connection.openCodeCompatibility)
        XCTAssertTrue(viewModel.chatFacade.commands(forSessionID: existing.id, canFork: true).isEmpty)
    }

    func testUnsupportedOptionalFeaturesCannotResolveAnOpenCodeClient() async throws {
        let viewModel = AppViewModel(backendFactory: InjectionTestFactory())
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        let connection = try viewModel.requireBackendConnection()

        for feature: BackendCapability in [.commands, .fork, .compaction, .terminal, .files, .mcp, .bridge, .providerConfiguration] {
            XCTAssertThrowsError(try connection.require(feature)) { error in
                XCTAssertEqual(error as? BackendError, .unsupported(feature))
            }
            XCTAssertThrowsError(try connection.requireOpenCodeClient(for: feature))
            XCTAssertNil(viewModel.compatibilityClient(for: feature))
        }
        XCTAssertTrue(viewModel.commands(canFork: true).isEmpty)
        let action = OpenCodeAction(commandName: "review", iconName: "bolt")
        viewModel.projectActionsByScope[viewModel.currentProjectPreferenceScopeKey] = [action]
        XCTAssertFalse(viewModel.supportsProjectActionExecution)
        XCTAssertTrue(viewModel.sessionListFacade.snapshot.currentProjectActions.isEmpty)
        await viewModel.sessionListFacade.runAction(action)
        XCTAssertNotNil(viewModel.errorMessage)
        let session = OpenCodeSession(id: "unknown", title: nil, workspaceID: nil, directory: "/harness", projectID: nil, parentID: nil)
        await viewModel.chatFacade.hydrateSessionForPresentation(session)
        let overlay = viewModel.chatFacade.composerOverlaySnapshot(forSessionID: session.id)
        XCTAssertTrue(overlay.todos.isEmpty)
        XCTAssertTrue(overlay.permissions.isEmpty)
        XCTAssertTrue(overlay.questions.isEmpty)
        XCTAssertFalse(viewModel.chatFacade.shouldOpenForkSheet(forSlashInput: "/fork"))
    }

    func testFacadeTranscriptCannotApplyAfterSameBackendReconnect() async throws {
        let factory = InjectionTestFactory()
        let viewModel = AppViewModel(backendFactory: factory)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        let project = try XCTUnwrap(viewModel.projects.first)
        await viewModel.projectFacade.completeSelection(viewModel.projectFacade.beginSelection(project))
        let harness = try XCTUnwrap(factory.harnesses.last)
        let session = try XCTUnwrap(viewModel.sessions.first)
        let requested = expectation(description: "Transcript request suspended")
        var release: CheckedContinuation<Void, Never>?
        harness.beforeTranscript = {
            await withCheckedContinuation { continuation in release = continuation; requested.fulfill() }
        }
        let task = Task { await viewModel.chatFacade.selectSession(session) }
        await fulfillment(of: [requested], timeout: 1)
        let oldConnection = try viewModel.requireBackendConnection()
        await viewModel.connectionFacade.connect()
        viewModel.errorMessage = "replacement connection"
        release?.resume()
        await task.value

        XCTAssertTrue(oldConnection.isClosed)
        XCTAssertTrue(viewModel.messages.isEmpty)
        XCTAssertEqual(viewModel.errorMessage, "replacement connection")
        XCTAssertNil(viewModel.selectedSession)
    }

    func testCapabilityNamesWithoutFeatureMethodsDoNotEnableOpenCodeActions() async throws {
        let factory = InjectionTestFactory()
        factory.capabilities = [.commands, .fork, .compaction, .interactions, .liveActivities, .worktrees]
        let viewModel = AppViewModel(backendFactory: factory)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        let project = try XCTUnwrap(viewModel.projects.first)
        await viewModel.projectFacade.completeSelection(viewModel.projectFacade.beginSelection(project))
        let session = try XCTUnwrap(viewModel.sessions.first)
        await viewModel.chatFacade.selectSession(session)
        XCTAssertTrue(viewModel.chatFacade.commands(forSessionID: session.id, canFork: true).isEmpty)
        XCTAssertFalse(viewModel.supportsProjectActionExecution)
        let sent = await viewModel.chatFacade.sendMessage("Still core chat", in: session, userVisible: true, meterPrompt: false)
        XCTAssertTrue(sent)
        await viewModel.chatFacade.stopSession(session)
        XCTAssertEqual(factory.harnesses.last?.interruptions, [session.id])
    }

    func testFacadeSendCompletionCannotClearANewerDraftAfterNavigation() async throws {
        let factory = InjectionTestFactory()
        let viewModel = AppViewModel(backendFactory: factory)
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        let project = try XCTUnwrap(viewModel.projects.first)
        await viewModel.projectFacade.completeSelection(viewModel.projectFacade.beginSelection(project))
        let harness = try XCTUnwrap(factory.harnesses.last)
        let session = try XCTUnwrap(viewModel.sessions.first)
        await viewModel.chatFacade.selectSession(session)
        let other = OpenCodeSession(id: "other", title: "Other", workspaceID: nil,
            directory: "/harness", projectID: project.id, parentID: nil)
        harness.storedSessions.append(other)
        await viewModel.sessionListFacade.refresh()
        harness.beforeSubmission = {
            await viewModel.chatFacade.selectSession(other)
            viewModel.chatFacade.saveMessageDraft("New draft", forSessionID: other.id)
            viewModel.errorMessage = "new chat error"
        }
        let accepted = await viewModel.chatFacade.sendMessage("Hello", in: session, userVisible: true, meterPrompt: false)
        XCTAssertTrue(accepted)
        XCTAssertEqual(viewModel.selectedSession?.id, other.id)
        XCTAssertEqual(viewModel.draftMessage, "New draft")
        XCTAssertEqual(viewModel.errorMessage, "new chat error")
        XCTAssertFalse(viewModel.messages.contains { $0.info.sessionID == session.id })
    }

    func testNormalizedEventsRouteToTheirOwningDirectory() async throws {
        let viewModel = AppViewModel(backendFactory: InjectionTestFactory())
        await viewModel.connectionFacade.connect()
        defer { viewModel.disconnect() }
        viewModel.selectedDirectory = "/harness"
        let other = viewModel.directoryStoreRegistry.store(for: "/other")
        let session = OpenCodeSession(id: "other-session", title: "Other", workspaceID: nil,
            directory: "/other", projectID: "other-project", parentID: nil)
        other.sessions = [session]

        viewModel.handleBackendEvent(.mutation(directory: "/other", event: .sessionStatus(sessionID: session.id, status: "busy")))
        XCTAssertEqual(other.sessionStatuses[session.id], "busy")
        XCTAssertNil(viewModel.directoryStore.sessionStatuses[session.id])
        XCTAssertTrue(viewModel.messages.isEmpty)
    }

    func testUncertainAdmissionRetainsIdentityDraftAndBlocksUIRollbackAndDirectRetries() async throws {
        let (model, harness, session) = try await connectedHarness()
        defer { model.disconnect() }
        harness.admissionResult = { .uncertain(sessionID: $0.sessionID, messageID: $0.messageID) }
        let connectionID = try model.requireBackendConnection().id
        model.chatFacade.saveMessageDraft("Keep this draft", forSessionID: session.id)
        let accepted = await model.chatFacade.sendMessage("Keep this draft", in: session, userVisible: true,
            messageID: "uncertain-input", meterPrompt: false)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: "uncertain-input", sessionID: session.id), .uncertain)
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        XCTAssertEqual(model.draftMessage, "Keep this draft")
        model.chatFacade.removeOptimisticUserMessage(messageID: "uncertain-input", sessionID: session.id)
        XCTAssertTrue(model.messages.contains { $0.id == "uncertain-input" })
        await model.chatFacade.stopSession(session)
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        let sameID = await model.chatFacade.sendMessage("Keep this draft", in: session, userVisible: true,
            messageID: "uncertain-input", meterPrompt: false)
        let freshID = await model.chatFacade.sendMessage("Keep this draft", in: session, userVisible: true,
            messageID: "duplicate-input", meterPrompt: false)
        let generatedID = await model.sendMessage("Keep this draft", in: session, userVisible: true, meterPrompt: false)
        XCTAssertFalse(sameID)
        XCTAssertFalse(freshID)
        XCTAssertFalse(generatedID)
        XCTAssertEqual(harness.submissions.map(\.messageID), ["uncertain-input"])

        let wrongRole = OpenCodeMessageEnvelope.local(role: "assistant", text: "No", messageID: "uncertain-input", sessionID: session.id)
        let wrongSession = OpenCodeMessageEnvelope.local(role: "user", text: "No", messageID: "uncertain-input", sessionID: "other")
        XCTAssertFalse(model.confirmCanonicalPromptAdmission(wrongRole.info, connectionID: connectionID))
        XCTAssertFalse(model.confirmCanonicalPromptAdmission(wrongSession.info, connectionID: connectionID))
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))

        // Contract for the event owner: only canonical message.updated user input calls this hook.
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Keep this draft", messageID: "uncertain-input", sessionID: session.id)
        XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: connectionID))
        XCTAssertFalse(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        let confirmedRetry = await model.chatFacade.sendMessage("Keep this draft", in: session, userVisible: true,
            messageID: "uncertain-input", meterPrompt: false)
        XCTAssertTrue(confirmedRetry)
        XCTAssertEqual(harness.submissions.count, 1)
    }

    func testCanonicalTranscriptPresenceConfirmsButAbsenceAndOptimisticCacheDoNot() async throws {
        let (model, harness, session) = try await connectedHarness()
        defer { model.disconnect() }
        harness.admissionResult = { .uncertain(sessionID: $0.sessionID, messageID: $0.messageID) }
        _ = await model.chatFacade.sendMessage("Hello", in: session, userVisible: true, messageID: "input", meterPrompt: false)
        await model.chatFacade.refreshChatData(for: session.id)
        XCTAssertTrue(model.messages.contains { $0.id == "input" })
        XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: "input", sessionID: session.id), .uncertain)
        XCTAssertTrue(model.chatFacade.hasUncertainPromptAdmission(sessionID: session.id))
        harness.storedMessages.append(.local(role: "user", text: "Hello", messageID: "input", sessionID: session.id))
        await model.chatFacade.refreshChatData(for: session.id)
        XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: "input", sessionID: session.id), .admitted)
        XCTAssertFalse(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        XCTAssertEqual(harness.submissions.count, 1)
    }

    func testDefinitiveRejectionRefundsOnlyItsOwnMeteredReservationOnce() async throws {
        let (model, harness, session) = try await connectedHarness()
        defer { model.disconnect() }
        let persistence = InjectionUsageStore()
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free),
            usageStore: persistence, purchaseManager: OpenClientPurchaseManager())
        model.commerceFacade.hydratePersistedState()
        harness.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        for metered in [false, true] {
            let id = "rejected-\(metered)"
            let accepted = await model.chatFacade.sendMessage("No", in: session, userVisible: true, messageID: id, meterPrompt: metered)
            XCTAssertFalse(accepted)
            XCTAssertEqual(model.usageMeter.dailyPromptCount, 3)
            XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: id, sessionID: session.id), .rejected)
            XCTAssertFalse(model.messages.contains { $0.id == id })
            _ = await model.chatFacade.sendMessage("No", in: session, userVisible: true, messageID: id, meterPrompt: metered)
            XCTAssertEqual(model.usageMeter.dailyPromptCount, 3)
        }
        XCTAssertEqual(harness.submissions.count, 2)

        // The animation path reserves at tap time and transfers refund ownership to sendMessage.
        XCTAssertTrue(model.chatFacade.reserveUserPromptIfAllowed())
        let day = model.chatFacade.reservedPromptDay
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 4)
        _ = await model.chatFacade.sendMessage("Animated", in: session, userVisible: true, messageID: "animated",
            appendOptimisticMessage: false, meterPrompt: false, reservedPromptDay: day)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 3)

        harness.admissionResult = { .uncertain(sessionID: $0.sessionID, messageID: $0.messageID) }
        _ = await model.chatFacade.sendMessage("Unknown", in: session, userVisible: true, messageID: "unknown", meterPrompt: true)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 4)
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
    }

    func testThrownSubmissionIsUnknownAndCannotOverwriteANewerDraft() async throws {
        let (model, harness, session) = try await connectedHarness()
        defer { model.disconnect() }
        harness.beforeSubmission = {
            model.chatFacade.saveMessageDraft("Newer draft", forSessionID: session.id)
            throw URLError(.timedOut)
        }
        let accepted = await model.chatFacade.sendMessage("Old draft", in: session, userVisible: true, messageID: "timeout", meterPrompt: false)
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: "timeout", sessionID: session.id), .uncertain)
        XCTAssertEqual(model.draftMessage, "Newer draft")
        XCTAssertTrue(model.messages.contains { $0.id == "timeout" })
        let retry = await model.chatFacade.sendMessage("Newer draft", in: session, userVisible: true, meterPrompt: false)
        XCTAssertFalse(retry)
        XCTAssertEqual(harness.submissions.count, 1)
    }

    func testUncertainResultAfterNavigationLocksOnlyItsSessionWithoutRestoringOldDraft() async throws {
        let (model, harness, session) = try await connectedHarness()
        defer { model.disconnect() }
        let other = OpenCodeSession(id: "other", title: "Other", workspaceID: nil, directory: "/harness",
            projectID: session.projectID, parentID: nil)
        harness.storedSessions.append(other)
        await model.sessionListFacade.refresh()
        harness.beforeSubmission = {
            await model.chatFacade.selectSession(other)
            model.chatFacade.saveMessageDraft("Other draft", forSessionID: other.id)
            model.errorMessage = "Other error"
        }
        harness.admissionResult = { .uncertain(sessionID: $0.sessionID, messageID: $0.messageID) }
        let accepted = await model.chatFacade.sendMessage("Original", in: session, userVisible: true, messageID: "original", meterPrompt: false)
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.draftMessage, "Other draft")
        XCTAssertEqual(model.errorMessage, "Other error")
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        XCTAssertFalse(model.chatFacade.hasPendingPromptAdmission(sessionID: other.id))
        let retry = await model.sendMessage("Original", in: session, userVisible: true, meterPrompt: false)
        XCTAssertFalse(retry)
        XCTAssertEqual(harness.submissions.count, 1)
    }

    func testPromptDraftConfirmationGuardRejectsNewContextOrRevision() async throws {
        let (model, _, session) = try await connectedHarness()
        defer { model.disconnect() }
        let token = UUID()
        let context = model.chatFacade.promptContextID
        // The non-v2 animation uses the same pure identity/revision guard as v2, not a Boolean failure.
        let draft = OpenCodeV2RetryDraft(messageID: "input", sessionID: session.id, contextID: context,
            revision: 1, resetToken: token, text: "Hello", mentions: [], attachments: [])
        XCTAssertTrue(draft.canClear(admittedMessageID: "input", sessionID: session.id, contextID: context,
            revision: 1, resetToken: token, text: "Hello", mentions: [], attachments: []))
        XCTAssertFalse(draft.canClear(admittedMessageID: "input", sessionID: session.id, contextID: context,
            revision: 2, resetToken: token, text: "Hello", mentions: [], attachments: []))
        XCTAssertFalse(draft.canClear(admittedMessageID: "input", sessionID: session.id, contextID: "replacement",
            revision: 1, resetToken: token, text: "Hello", mentions: [], attachments: []))
    }

    func testCanonicalEvidenceWinsOverConflictingRejectionWithoutRefund() async throws {
        let (model, harness, session) = try await connectedHarness()
        defer { model.disconnect() }
        let persistence = InjectionUsageStore()
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free),
            usageStore: persistence, purchaseManager: OpenClientPurchaseManager())
        model.commerceFacade.hydratePersistedState()
        let connectionID = try model.requireBackendConnection().id
        harness.beforeSubmission = {
            let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Hello", messageID: "confirmed", sessionID: session.id)
            XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: connectionID))
        }
        harness.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        let accepted = await model.chatFacade.sendMessage("Hello", in: session, userVisible: true, messageID: "confirmed", meterPrompt: true)
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 4)
        XCTAssertTrue(model.messages.contains { $0.id == "confirmed" })
    }

    func testStaleAdmissionAndCanonicalCallbackCannotTouchReplacementConnectionDraft() async throws {
        let (model, harness, session) = try await connectedHarness()
        defer { model.disconnect() }
        let connectionID = try model.requireBackendConnection().id
        let contextID = model.chatFacade.promptContextID
        harness.beforeSubmission = {
            await model.connectionFacade.connect()
            let project = try XCTUnwrap(model.projects.first)
            await model.projectFacade.completeSelection(model.projectFacade.beginSelection(project))
            await model.chatFacade.selectSession(session)
            model.chatFacade.saveMessageDraft("Replacement", forSessionID: session.id)
            model.errorMessage = "Replacement error"
        }
        harness.admissionResult = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        let accepted = await model.chatFacade.sendMessage("Old", in: session, userVisible: true, messageID: "stale", meterPrompt: false)
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.draftMessage, "Replacement")
        XCTAssertEqual(model.errorMessage, "Replacement error")
        XCTAssertNotEqual(model.chatFacade.promptContextID, contextID)
        XCTAssertNil(model.chatFacade.promptAdmissionPhase(messageID: "stale", sessionID: session.id))
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Old", messageID: "stale", sessionID: session.id)
        XCTAssertFalse(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: connectionID))
        XCTAssertEqual(model.draftMessage, "Replacement")
    }

    private func connectedHarness() async throws -> (AppViewModel, InjectionTestHarness, OpenCodeSession) {
        let factory = InjectionTestFactory()
        let model = AppViewModel(backendFactory: factory)
        await model.connectionFacade.connect()
        let project = try XCTUnwrap(model.projects.first)
        await model.projectFacade.completeSelection(model.projectFacade.beginSelection(project))
        let session = try XCTUnwrap(model.sessions.first)
        await model.chatFacade.selectSession(session)
        return (model, try XCTUnwrap(factory.harnesses.last), session)
    }

    func testOneSourceFansOutAndCloseRejectsOldCallbacks() async throws {
        let factory = InjectionTestFactory()
        let connection = try await factory.connect()
        let harness = try XCTUnwrap(factory.harnesses.last)
        var first = connection.eventStream().makeAsyncIterator()
        var second = connection.eventStream().makeAsyncIterator()
        XCTAssertEqual(harness.startCount, 1)

        harness.emit(.status("live"))
        let firstEvent = await first.next()
        let secondEvent = await second.next()
        guard case .status("live")? = firstEvent, case .status("live")? = secondEvent else {
            return XCTFail("Both subscribers must receive the same event")
        }
        let staleCallback = harness.receive
        connection.close()
        staleCallback?(.status("stale"))
        let endFirst = await first.next()
        let endSecond = await second.next()
        XCTAssertNil(endFirst)
        XCTAssertNil(endSecond)
        XCTAssertTrue(connection.isClosed)
        XCTAssertThrowsError(try connection.require(.terminal)) { error in
            XCTAssertEqual(error as? BackendError, .disconnected)
        }
    }

    func testCancellingLastSubscriberStopsTheSource() async throws {
        let factory = InjectionTestFactory()
        let connection = try await factory.connect()
        let harness = try XCTUnwrap(factory.harnesses.last)
        let stopped = expectation(description: "Source stopped after subscription cancellation")
        harness.onStop = { stopped.fulfill() }
        let stream = connection.eventStream()
        let consumer = Task { for await _ in stream {} }
        consumer.cancel()
        await consumer.value
        await fulfillment(of: [stopped], timeout: 1)
        harness.onStop = nil
        connection.close()
    }

    func testReconnectCreatesANewLifetimeAndClosesTheOldConnection() async throws {
        let factory = InjectionTestFactory()
        let viewModel = AppViewModel(backendFactory: factory)
        await viewModel.connectionFacade.connect()
        let first = try viewModel.requireBackendConnection()
        await viewModel.connectionFacade.connect()
        let second = try viewModel.requireBackendConnection()
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertEqual(first.descriptor, second.descriptor)
        XCTAssertTrue(first.isClosed)
        XCTAssertFalse(viewModel.isCurrentBackendConnection(first))
        XCTAssertTrue(viewModel.isCurrentBackendConnection(second))
        viewModel.connectionFacade.disconnect()
        XCTAssertTrue(second.isClosed)
        XCTAssertNil(viewModel.backendConnection)
    }

    func testInvalidatedFactoryResultIsClosedWithoutApplyingIt() async throws {
        let factory = InjectionTestFactory()
        let store = ConnectionStore()
        var current = true
        factory.beforeReturn = { current = false }
        await ConnectionCoordinator(connectionStore: store).connect(
            factory: factory, isCurrentAttempt: { current },
            applyConnection: { _ in XCTFail("Stale factory result") },
            handleFailure: { XCTFail("Stale attempts must not mutate current failure state") }
        )
        XCTAssertTrue(try XCTUnwrap(factory.connections.last).isClosed)
        XCTAssertFalse(store.isConnected)
    }

    func testCancelledFactoryResultIsClosedEvenWhenFactoryIgnoresCancellation() async throws {
        let factory = InjectionTestFactory()
        let store = ConnectionStore()
        let waiting = expectation(description: "Factory suspended")
        var release: CheckedContinuation<Void, Never>?
        factory.beforeReturn = {
            await withCheckedContinuation { continuation in
                release = continuation
                waiting.fulfill()
            }
        }
        var failures = 0
        let task = Task {
            await ConnectionCoordinator(connectionStore: store).connect(
                factory: factory,
                applyConnection: { _ in XCTFail("Cancelled result") },
                handleFailure: { failures += 1 }
            )
        }
        await fulfillment(of: [waiting], timeout: 1)
        task.cancel()
        release?.resume()
        await task.value
        XCTAssertTrue(try XCTUnwrap(factory.connections.last).isClosed)
        XCTAssertEqual(failures, 1)
        XCTAssertFalse(store.isLoading)
        XCTAssertFalse(store.isConnected)
    }
}

@MainActor
private final class InjectionTestFactory: BackendFactory {
    var capabilities: Set<BackendCapability> = []
    var harnesses: [InjectionTestHarness] = []
    var connections: [BackendConnection] = []
    var beforeReturn: (@MainActor () async -> Void)?

    func connect() async throws -> BackendConnection {
        let harness = InjectionTestHarness()
        let connection = BackendConnection(
            descriptor: .init(id: "in-memory-harness", name: "Harness", version: "1"),
            capabilities: capabilities,
            projects: harness, sessions: harness, chat: harness, models: harness, events: harness
        )
        harnesses.append(harness)
        connections.append(connection)
        await beforeReturn?()
        return connection
    }
}

@MainActor
private final class InjectionTestHarness: BackendProjectsService, BackendSessionsService, BackendChatService, BackendModelsService, BackendEventSource {
    var storedSessions: [OpenCodeSession] = [.init(id: "harness-existing", title: "Existing", workspaceID: nil,
        directory: "/harness", projectID: "harness-project", parentID: nil)]
    var storedMessages: [OpenCodeMessageEnvelope] = [.local(role: "assistant", text: "Earlier answer",
        messageID: "history", sessionID: "harness-existing")]
    var receive: (@MainActor (BackendEvent) -> Void)?
    var onStop: (@MainActor () -> Void)?
    var startCount = 0
    var interruptions: [String] = []
    var listScopes: [BackendScope] = []
    var catalogScopes: [BackendScope] = []
    var creations: [BackendSessionCreation] = []
    var submissions: [BackendSubmission] = []
    var beforeTranscript: (@MainActor () async -> Void)?
    var beforeSubmission: (@MainActor () async throws -> Void)?
    var admissionResult: (@MainActor (BackendSubmission) -> BackendAdmission)?

    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        .init(projects: [.init(id: "harness-project", worktree: "/harness", vcs: nil, name: "Harness", sandboxes: nil, icon: nil, time: nil)])
    }

    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        listScopes.append(scope)
        return .init(sessions: Array(storedSessions.prefix(limit)))
    }

    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        try XCTUnwrap(storedSessions.first { $0.id == id })
    }

    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        creations.append(request)
        let session = OpenCodeSession(id: "harness-session", title: request.title, workspaceID: request.scope.workspaceID,
            directory: request.scope.directory, projectID: request.scope.projectID, parentID: nil)
        storedSessions.append(session)
        return session
    }

    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession {
        let previous = try await session(id: id, scope: scope)
        let renamed = OpenCodeSession(id: id, title: title, workspaceID: previous.workspaceID,
            directory: previous.directory, projectID: previous.projectID, parentID: previous.parentID)
        storedSessions = storedSessions.map { $0.id == id ? renamed : $0 }
        return renamed
    }

    func deleteSession(id: String, scope: BackendScope) async throws { storedSessions.removeAll { $0.id == id } }

    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] {
        Array(storedSessions.filter { $0.title?.contains(query) == true }.prefix(limit))
    }

    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        let messages = storedMessages.filter { $0.info.sessionID == sessionID }
        await beforeTranscript?()
        return .init(messages: messages)
    }

    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        submissions.append(request)
        try await beforeSubmission?()
        if let admissionResult { return admissionResult(request) }
        let input = OpenCodeMessageEnvelope.local(role: "user", text: request.text, messageID: request.messageID, sessionID: request.sessionID)
        let answer = OpenCodeMessageEnvelope.local(role: "assistant", text: "Harness answer", messageID: "output-1", sessionID: request.sessionID)
        storedMessages = [input, answer]
        for message in storedMessages {
            emit(.mutation(directory: request.scope.directory, event: .messageUpdated(message.info)))
            for part in message.parts { emit(.mutation(directory: request.scope.directory, event: .messagePartUpdated(part))) }
        }
        return .accepted(sessionID: request.sessionID, messageID: request.messageID)
    }

    func interrupt(sessionID: String, scope: BackendScope) async throws {
        interruptions.append(sessionID)
        emit(.mutation(directory: scope.directory, event: .sessionStatus(sessionID: sessionID, status: "idle")))
    }

    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog {
        catalogScopes.append(scope)
        return .init(agents: [.init(name: "harness-agent", description: nil, mode: "primary", hidden: false, model: nil, variant: nil)],
            providers: [.init(id: "harness", name: "Harness", models: ["reasoner": .init(id: "reasoner", providerID: "harness",
                name: "Reasoner", capabilities: .init(reasoning: true), variants: ["high": .bool(true)])])],
            defaults: ["harness": "reasoner"])
    }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { startCount += 1; self.receive = receive }
    func stop() { receive = nil; onStop?() }
    func emit(_ event: BackendEvent) { receive?(event) }
}

private final class InjectionUsageStore: OpenClientUsagePersisting {
    var meter = OpenClientUsageMeter(promptDay: OpenClientUsageMeter.dayString(for: Date()), dailyPromptCount: 3, createdSessionCount: 0)
    func load() -> OpenClientUsageMeter { meter }
    func save(_ meter: OpenClientUsageMeter) { self.meter = meter }
}
