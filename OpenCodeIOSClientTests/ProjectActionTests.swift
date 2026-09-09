import Combine
import XCTest
@testable import OpenClient

@MainActor
final class ProjectActionTests: XCTestCase {
    private let scope = ProjectActionScope(backendID: "fake", contractID: "fake.actions.v1", projectID: "p", directory: "/repo", workspaceID: "ws")
    private let action = OpenCodeAction(commandName: "test", iconName: "bolt.fill")

    private func makeStore() -> ProjectActionStore {
        let name = "ProjectActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        addTeardownBlock { UserDefaults(suiteName: name)?.removePersistentDomain(forName: name) }
        return ProjectActionStore(defaults: defaults)
    }

    private func makeViewModel(fake: ActionBackend) -> AppViewModel {
        // The root currently constructs its own journal. Preserve its bytes across
        // facade tests rather than changing the production owner's injection surface.
        let key = "openclient.project-action-journal.v1"
        let savedJournal = UserDefaults.standard.data(forKey: key)
        addTeardownBlock {
            if let savedJournal { UserDefaults.standard.set(savedJournal, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        let model = AppViewModel(backendFactory: fake)
        model.backendConnection = fake.connection()
        model.isConnected = true
        let project = OpenCodeProject(id: "p", worktree: "/repo", vcs: nil, name: "Project", sandboxes: [], icon: nil, time: nil)
        model.projects = [project]
        model.currentProject = project
        model.selectedDirectory = project.worktree
        return model
    }

    private func run(_ coordinator: ProjectActionCoordinator, fake: ActionBackend, connection: BackendConnection? = nil) async {
        await coordinator.run(action: action, scope: scope, connection: connection ?? fake.connection(), commands: fake,
            agent: "build", model: .init(providerID: "provider", modelID: "model"), variant: "high", isCurrent: { true })
    }

    func testFullContractFakeRunsWithoutOpenCodeClientAndRetainsSuccess() async throws {
        let store = makeStore()
        let fake = ActionBackend()
        let coordinator = ProjectActionCoordinator(store: store)
        await run(coordinator, fake: fake)
        let record = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(record.state, .succeeded)
        XCTAssertTrue(store.isHidden(sessionID: "ses_action", backendID: "fake", contractID: fake.actionContractID))
        XCTAssertEqual(fake.operations, ["create", "command", "wait", "turn", "prompt", "wait", "turn"])
        XCTAssertEqual(fake.creation?.scope, scope.backendScope)
        XCTAssertEqual(fake.creation?.model, .init(providerID: "provider", modelID: "model"))
        XCTAssertEqual(fake.command?.model, fake.creation?.model)
        XCTAssertEqual(fake.evaluation?.model, fake.creation?.model)
        XCTAssertEqual(fake.evaluation?.agent, "build")
        XCTAssertEqual(fake.evaluation?.variant, "high")
        XCTAssertEqual(fake.command?.messageID, record.commandMessageID)
        XCTAssertEqual(fake.evaluation?.messageID, record.evaluationMessageID)
        XCTAssertNotEqual(record.commandMessageID, record.evaluationMessageID)
        XCTAssertEqual(fake.deleteCount, 0)
        XCTAssertEqual(fake.renameCount, 0)
        store.reveal(id: record.id)
        XCTAssertFalse(store.isHidden(sessionID: "ses_action", backendID: "fake", contractID: fake.actionContractID))
    }

    func testOnlyKnownOpenCodeContractsAdvertiseActionsAndFakeCanInjectService() {
        let fake = ActionBackend()
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://action.invalid"))
        XCTAssertNotNil(OpenCodeCommandsService.make(client: client, profile: .legacy, version: "1", sessions: fake, chat: fake))
        XCTAssertNotNil(OpenCodeCommandsService.make(client: client, profile: .v2, version: "0.0.0-next-17155", sessions: fake, chat: fake))
        XCTAssertNil(OpenCodeCommandsService.make(client: client, profile: .v2, version: "unverified", sessions: fake, chat: fake))
        let connection = fake.connection()
        XCTAssertNil(connection.openCodeCompatibility)
        XCTAssertEqual(connection.commands?.actionContractID, fake.actionContractID)
    }

    func testDuplicateReservationPrecedesCreateAwait() async throws {
        let store = makeStore()
        let fake = ActionBackend()
        let coordinator = ProjectActionCoordinator(store: store)
        var resume: CheckedContinuation<Void, Never>?
        fake.beforeCreate = { await withCheckedContinuation { resume = $0 } }
        let first = Task { await self.run(coordinator, fake: fake) }
        while resume == nil { await Task.yield() }
        await run(coordinator, fake: fake)
        XCTAssertEqual(fake.operations, ["create"])
        XCTAssertEqual(store.runs.count, 1)
        resume?.resume()
        await first.value
    }

    func testLostReceiptNeverRetriesOrDeletes() async throws {
        let store = makeStore()
        let fake = ActionBackend()
        fake.uncertainCommand = true
        await run(ProjectActionCoordinator(store: store), fake: fake)
        let record = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(record.state, .failed)
        XCTAssertFalse(record.isHidden)
        XCTAssertEqual(record.sessionID, "ses_action")
        XCTAssertEqual(fake.operations, ["create", "command"])
        XCTAssertEqual(fake.deleteCount, 0)
    }

    func testLostEvaluationReceiptRetainsSessionWithoutRetry() async throws {
        let store = makeStore()
        let fake = ActionBackend()
        fake.uncertainEvaluation = true
        await run(ProjectActionCoordinator(store: store), fake: fake)
        XCTAssertEqual(store.runs.first?.state, .failed)
        XCTAssertFalse(store.runs.first?.isHidden ?? true)
        XCTAssertEqual(fake.operations.filter { $0 == "prompt" }.count, 1)
        XCTAssertEqual(fake.operations.filter { $0 == "wait" }.count, 1)
        XCTAssertEqual(fake.deleteCount, 0)
    }

    func testTimeoutDoesNotTreatIdleAsSuccessOrSendEvaluator() async {
        let store = makeStore()
        let fake = ActionBackend()
        fake.neverCompletes = true
        let coordinator = ProjectActionCoordinator(store: store)
        await coordinator.run(action: action, scope: scope, connection: fake.connection(), commands: fake,
            agent: nil, model: nil, variant: nil, timeout: .milliseconds(10), isCurrent: { true })
        XCTAssertEqual(store.runs.first?.state, .interrupted)
        XCTAssertFalse(store.runs.first?.isHidden ?? true)
        XCTAssertNil(fake.evaluation)
        XCTAssertEqual(fake.deleteCount, 0)
    }

    func testWaitIsOnlyBarrierAndAttentionRevealsWhileStillObserving() async throws {
        let store = makeStore()
        let fake = ActionBackend()
        let coordinator = ProjectActionCoordinator(store: store)
        fake.onFirstTurn = {
            XCTAssertNil(fake.evaluation, "Idle must not start evaluation without the command's canonical completion")
            XCTAssertEqual(store.runs.first?.state, .runningCommand)
            coordinator.receive(.needsAttention(sessionID: "ses_action"), backendID: "fake", contractID: fake.actionContractID)
            XCTAssertFalse(store.runs.first?.isHidden ?? true)
            coordinator.receive(.execution(sessionID: "ses_action"), backendID: "fake", contractID: fake.actionContractID)
        }
        await run(coordinator, fake: fake)
        XCTAssertEqual(store.runs.first?.state, .succeeded)
        XCTAssertFalse(store.runs.first?.isHidden ?? true, "Attention visibility is sticky even after success")
        XCTAssertEqual(fake.operations.filter { $0 == "turn" }.count, 3)
    }

    func testChildAndHydratedInteractionRemainActionable() async {
        for useHydration in [false, true] {
            let store = makeStore()
            let fake = ActionBackend()
            let coordinator = ProjectActionCoordinator(store: store)
            fake.attention = useHydration
            if !useHydration {
                fake.onFirstTurn = {
                    coordinator.receive(.sessionParent(sessionID: "child", parentID: "ses_action"), backendID: "fake", contractID: fake.actionContractID)
                }
            }
            await run(coordinator, fake: fake)
            XCTAssertTrue(store.runs.first?.requiresAttention ?? false)
            XCTAssertFalse(store.runs.first?.isHidden ?? true)
        }
    }

    func testCancellationAfterCreatePreservesLateReceiptWithoutFollowups() async throws {
        let store = makeStore()
        let fake = ActionBackend()
        let connection = fake.connection()
        let coordinator = ProjectActionCoordinator(store: store)
        var resume: CheckedContinuation<Void, Never>?
        fake.beforeCreate = { await withCheckedContinuation { resume = $0 } }
        let task = Task { await self.run(coordinator, fake: fake, connection: connection) }
        while resume == nil { await Task.yield() }
        coordinator.cancel(connectionID: connection.id)
        connection.close()
        resume?.resume()
        await task.value
        let record = try XCTUnwrap(store.runs.first)
        XCTAssertEqual(record.sessionID, "ses_action")
        XCTAssertEqual(record.state, .interrupted)
        XCTAssertFalse(record.isHidden)
        XCTAssertEqual(fake.operations, ["create"])
        XCTAssertEqual(fake.deleteCount, 0)
    }

    func testFailureAndUnconfirmedEvaluationAreAlwaysVisible() async {
        for text in ["FAILURE", "unknown", "SUCCESS\nextra text"] {
            let store = makeStore()
            let fake = ActionBackend()
            fake.result = text
            await run(ProjectActionCoordinator(store: store), fake: fake)
            XCTAssertEqual(store.runs.first?.state, .failed)
            XCTAssertFalse(store.runs.first?.isHidden ?? true)
            XCTAssertEqual(fake.renameCount, 0, "Revealing does not depend on a title mutation")
        }
    }

    func testVisibilityRequiresOwnedSessionBackendAndContractNotTitle() throws {
        let store = makeStore()
        let run = try XCTUnwrap(store.begin(action: action, scope: scope))
        store.update(id: run.id) { $0.sessionID = "owned"; $0.state = .succeeded }
        XCTAssertEqual(store.hiddenSessionIDs(backendID: "fake", contractID: "fake.actions.v1"), ["owned"])
        XCTAssertFalse(store.isHidden(sessionID: "__openclient_action__:test:ordinary", backendID: "fake", contractID: "fake.actions.v1"))
        XCTAssertFalse(store.isHidden(sessionID: "owned", backendID: "other", contractID: "fake.actions.v1"))
        XCTAssertFalse(store.isHidden(sessionID: "owned", backendID: "fake", contractID: "other"))
        let coordinator = ProjectActionCoordinator(store: store)
        coordinator.receive(.needsAttention(sessionID: "owned"), backendID: "other", contractID: "fake.actions.v1")
        XCTAssertTrue(store.run(id: run.id)?.isHidden ?? false)
    }

    func testJournalRestoresSuccessButRevealsUnfinishedRuns() throws {
        let name = "ProjectActionTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let store = ProjectActionStore(defaults: defaults)
        let success = try XCTUnwrap(store.begin(action: action, scope: scope))
        store.update(id: success.id) { $0.sessionID = "success"; $0.state = .succeeded }
        let interrupted = try XCTUnwrap(store.begin(action: action, scope: scope))
        store.update(id: interrupted.id) { $0.sessionID = "interrupted" }
        let restored = ProjectActionStore(defaults: defaults)
        XCTAssertTrue(restored.run(id: success.id)?.isHidden ?? false)
        XCTAssertEqual(restored.run(id: interrupted.id)?.state, .interrupted)
        XCTAssertFalse(restored.run(id: interrupted.id)?.isHidden ?? true)
    }

    func testCanonicalV2EvidenceIgnoresUserToolReasoningSyntheticAndOtherTurn() throws {
        let records = try JSONDecoder().decode([OpenCodeCommandsService.TimelineRecord].self, from: Data(#"""
        [
          {"id":"before","type":"assistant","time":{"completed":1},"content":[{"type":"text","text":"wrong"}]},
          {"id":"eval","type":"user","text":"OPENCLIENT_ACTION_RESULT:nonce:SUCCESS"},
          {"id":"answer","type":"assistant","time":{"completed":2},"content":[
            {"type":"reasoning","text":"OPENCLIENT_ACTION_RESULT:nonce:SUCCESS"},
            {"type":"tool","text":"OPENCLIENT_ACTION_RESULT:nonce:SUCCESS"},
            {"type":"text","text":"OPENCLIENT_ACTION_RESULT:nonce:FAILURE"}]},
          {"id":"synthetic","type":"synthetic","text":"OPENCLIENT_ACTION_RESULT:nonce:SUCCESS"},
          {"id":"other","type":"user"},
          {"id":"other-answer","type":"assistant","time":{"completed":3},"content":[{"type":"text","text":"wrong"}]}
        ]
        """#.utf8))
        let turn = try XCTUnwrap(OpenCodeCommandsService.completedV2Turn(records, sessionID: "s", userMessageID: "eval"))
        XCTAssertEqual(turn.assistantMessageID, "answer")
        XCTAssertEqual(turn.text, "OPENCLIENT_ACTION_RESULT:nonce:FAILURE")
        XCTAssertNil(OpenCodeCommandsService.completedV2Turn(records, sessionID: "s", userMessageID: "missing"))
    }

    func testExactNonceSessionAndEvaluationIdentityRequired() throws {
        let store = makeStore()
        var run = try XCTUnwrap(store.begin(action: action, scope: scope))
        run.sessionID = "s"
        func turn(_ text: String, session: String = "s", input: String? = nil) -> BackendActionTurn {
            .init(sessionID: session, userMessageID: input ?? run.evaluationMessageID, assistantMessageID: "a", text: text, failed: false)
        }
        let marker = "OPENCLIENT_ACTION_RESULT:\(run.id):SUCCESS"
        XCTAssertTrue(ProjectActionCoordinator.isSuccess(turn(marker), run: run))
        XCTAssertFalse(ProjectActionCoordinator.isSuccess(turn(marker, session: "other"), run: run))
        XCTAssertFalse(ProjectActionCoordinator.isSuccess(turn(marker, input: run.commandMessageID), run: run))
        XCTAssertFalse(ProjectActionCoordinator.isSuccess(turn("OPENCLIENT_ACTION_RESULT:other:SUCCESS"), run: run))
        XCTAssertFalse(ProjectActionCoordinator.isSuccess(turn(marker + "\nOPENCLIENT_ACTION_RESULT:\(run.id):FAILURE"), run: run))
    }

    func testV2CommandUsesArgumentsAndDecodesAdmissionWithExplicitSelection() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [ActionCommandURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let client = OpenCodeAPIClient(config: .init(baseURL: "https://action.invalid"), session: session)
        let receipt = try await client.admitV2Command(sessionID: "ses_action", messageID: "msg_action", command: "test",
            arguments: "--all", agent: "build", model: .init(providerID: "provider", modelID: "model"), variant: "high",
            attachments: [.init(id: "file", kind: .file, filename: "test.txt", mime: "text/plain", dataURL: "data:text/plain;base64,YQ==")],
            resume: false)
        XCTAssertEqual(receipt, .init(id: "msg_action", sessionID: "ses_action", timeCreated: 123, delivery: "queued"))
    }

    func testHomeAndSearchBuildersFilterOwnedRunsBeforeLimitWithoutDeletingCandidates() throws {
        let journal = makeStore()
        let run = try XCTUnwrap(journal.begin(action: action, scope: scope))
        journal.update(id: run.id) { $0.sessionID = "owned"; $0.state = .succeeded }
        let owned = OpenCodeSession(id: "owned", title: "Action", workspaceID: nil, directory: "/repo", projectID: "p", parentID: nil)
        let ordinary = OpenCodeSession(id: "ordinary", title: "__openclient_action__:test:lookalike", workspaceID: nil, directory: "/repo", projectID: "p", parentID: nil)
        let store = SessionListStore()
        store.setRecentSessions([owned, ordinary], for: "/repo")
        let previews = [owned.id: SessionPreview(text: "Action result", date: .distantFuture)]
        let hidden = journal.hiddenSessionIDs(backendID: scope.backendID, contractID: scope.contractID)
        XCTAssertEqual(store.recentProjectSessions(projects: [], previews: previews, statuses: [:], hiddenActionSessionIDs: hidden, limit: 1).map(\.session.id), [ordinary.id])
        XCTAssertEqual(store.projectSessionSearchResults(projects: [], previews: previews, statuses: [:], query: "action", hiddenActionSessionIDs: hidden, limit: 1).map(\.session.id), [ordinary.id])
        XCTAssertEqual(store.recentSessionsByDirectory["/repo"], [owned, ordinary])
        journal.reveal(id: run.id)
        XCTAssertEqual(store.recentProjectSessions(projects: [], previews: previews, statuses: [:], hiddenActionSessionIDs: journal.hiddenSessionIDs(backendID: scope.backendID, contractID: scope.contractID), limit: 1).map(\.session.id), [owned.id])
    }

    func testHomeCachedSearchAndActivityReprojectAfterRecoveryWithoutCanonicalRemoval() async throws {
        let fake = ActionBackend()
        let model = makeViewModel(fake: fake)
        let session = try await fake.session(id: "owned-\(UUID().uuidString)", scope: scope.backendScope)
        let ordinary = OpenCodeSession(id: "ordinary", title: "__openclient_action__:test:lookalike", workspaceID: nil, directory: "/repo", projectID: "p", parentID: nil)
        let run = try XCTUnwrap(model.projectActionStore.begin(action: action, scope: scope))
        model.projectActionStore.update(id: run.id) { $0.sessionID = session.id; $0.state = .succeeded }
        model.sessionListStore.setRecentSessions([session, ordinary], for: "/repo")
        _ = model.directoryStore.upsertSessions([session, ordinary])
        model.projectSessionSearchQuery = "action"
        // This is deliberately an already-built response, not just the local builder.
        model.sessionListStore.projectSessionSearchResults = [session, ordinary].map {
            RecentProjectSession(session: $0, projectTitle: "Project", preview: nil, isBusy: false)
        }
        XCTAssertEqual(model.recentProjectSessions.map(\.session.id), [ordinary.id])
        XCTAssertEqual(model.projectFacade.listSnapshot.searchResults.map(\.session.id), [ordinary.id])
        XCTAssertEqual(model.activityFacade.snapshot.recentRows.map(\.recent.session.id), [ordinary.id])

        let restored = expectation(description: "Activity reprojects the retained session on journal recovery")
        let observation = model.activityFacade.$snapshot
            .filter { $0.recentRows.contains { $0.recent.session.id == session.id } }
            .prefix(1)
            .sink { _ in restored.fulfill() }
        let invalidated = expectation(description: "Root observer invalidates derived snapshots after mutation")
        let rootObservation = model.objectWillChange.prefix(1).sink { _ in invalidated.fulfill() }
        model.projectActionStore.reveal(id: run.id)
        await fulfillment(of: [restored, invalidated], timeout: 1)
        XCTAssertEqual(Set(model.recentProjectSessions.map(\.session.id)), [session.id, ordinary.id])
        XCTAssertEqual(Set(model.projectSessionSearchResults.map(\.session.id)), [session.id, ordinary.id])
        XCTAssertEqual(model.sessionListStore.projectSessionSearchResults.count, 2)
        XCTAssertEqual(Set(model.directoryStore.sessions.map(\.id)), [session.id, ordinary.id])
        XCTAssertEqual(model.sessionListStore.recentSessionsByDirectory["/repo"]?.count, 2)
        withExtendedLifetime((observation, rootObservation)) {}
    }

    func testPendingFormRevealsRunningOwnedRunAcrossAllProjectionsAndDeduplicatesQuestion() async throws {
        let fake = ActionBackend()
        let model = makeViewModel(fake: fake)
        let session = try await fake.session(id: "blocked-\(UUID().uuidString)", scope: scope.backendScope)
        let run = try XCTUnwrap(model.projectActionStore.begin(action: action, scope: scope))
        model.projectActionStore.update(id: run.id) { $0.sessionID = session.id; $0.state = .runningCommand }
        model.sessionListStore.setRecentSessions([session], for: "/repo")
        model.projectSessionSearchQuery = "action"
        XCTAssertTrue(model.recentProjectSessions.isEmpty)
        XCTAssertTrue(model.projectSessionSearchResults.isEmpty)
        XCTAssertTrue(model.activityFacade.snapshot.isEmpty)

        let visible = expectation(description: "Canonical form hydration makes a hidden run actionable")
        let observation = model.activityFacade.$snapshot
            .filter { $0.needsInputRows.contains { $0.recent.session.id == session.id && $0.pendingInteractionCount == 1 } }
            .prefix(1)
            .sink { _ in visible.fulfill() }
        let form = BackendForm(id: "form", sessionID: session.id, title: "Needs input", fields: [])
        XCTAssertFalse(form.contract.isSupported(), "Unsupported forms also need user attention")
        model.directoryStore.sessionFormStore.upsert(form)
        XCTAssertFalse(model.hiddenProjectActionSessionIDs.contains(session.id), "Forms can hydrate before the session's canonical row")
        _ = model.directoryStore.applyQuestions([
            .init(id: form.id, sessionID: session.id, questions: [], tool: nil)
        ], ifUnchangedSince: model.directoryStore.questionRevision)
        await fulfillment(of: [visible], timeout: 1)
        XCTAssertEqual(model.recentProjectSessions.map(\.session.id), [session.id])
        XCTAssertEqual(model.projectSessionSearchResults.map(\.session.id), [session.id])
        XCTAssertFalse(model.isActionSession(session))
        // The shared event makes visibility sticky; no SSE owner is created here.
        model.projectActionCoordinator.receive(.needsAttention(sessionID: session.id), backendID: "fake", contractID: fake.actionContractID)
        model.directoryStore.sessionFormStore.settle(form.key)
        _ = model.directoryStore.applyQuestions([], ifUnchangedSince: model.directoryStore.questionRevision)
        XCTAssertFalse(model.hiddenProjectActionSessionIDs.contains(session.id))
        XCTAssertTrue(model.projectActionStore.run(id: run.id)?.requiresAttention ?? false)
        withExtendedLifetime(observation) {}
    }

    func testVisibilityReprojectsForConnectionNamespaceAndContractChanges() async throws {
        let fake = ActionBackend()
        let model = makeViewModel(fake: fake)
        let session = try await fake.session(id: "scoped-\(UUID().uuidString)", scope: scope.backendScope)
        let run = try XCTUnwrap(model.projectActionStore.begin(action: action, scope: scope))
        model.projectActionStore.update(id: run.id) { $0.sessionID = session.id; $0.state = .succeeded }
        model.sessionListStore.setRecentSessions([session], for: "/repo")
        XCTAssertTrue(model.recentProjectSessions.isEmpty)
        model.backendConnection = fake.connection(id: "different-backend")
        model.refreshProjectActionVisibility()
        XCTAssertEqual(model.recentProjectSessions.map(\.session.id), [session.id])
        fake.actionContractID = "different-contract"
        model.backendConnection = fake.connection()
        model.refreshProjectActionVisibility()
        XCTAssertEqual(model.recentProjectSessions.map(\.session.id), [session.id])
        fake.actionContractID = scope.contractID
        model.refreshProjectActionVisibility()
        XCTAssertTrue(model.recentProjectSessions.isEmpty)
    }

    func testInjectedCommandCatalogLoadsWithoutCompatibilityAndDoesNotEnableGames() async throws {
        let fake = ActionBackend()
        let model = makeViewModel(fake: fake)
        model.selectedSession = try await fake.session(id: "catalog", scope: scope.backendScope)
        await model.loadComposerOptions()
        XCTAssertNil(model.backendConnection?.openCodeCompatibility)
        XCTAssertEqual(model.directoryCommands.map(\.name), ["test"])
        XCTAssertEqual(fake.commandCatalogScopes, [scope.backendScope])
        XCTAssertTrue(model.supportsProjectActionExecution)
        XCTAssertFalse(model.allowsFunAndGames)
        fake.failCommandCatalog = true
        await model.loadComposerOptions()
        XCTAssertTrue(model.directoryCommands.isEmpty, "An unsuccessful service read must not leave stale commands enabled")
    }

    func testCommandCatalogDoesNotFollowUpOnReplacedConnection() async {
        let fake = ActionBackend()
        let model = makeViewModel(fake: fake)
        fake.onModelCatalog = { [weak model] in model?.backendConnection = fake.connection(id: "replacement") }
        await model.loadComposerOptions()
        XCTAssertTrue(fake.commandCatalogScopes.isEmpty)
        XCTAssertTrue(model.directoryCommands.isEmpty)
        fake.onModelCatalog = nil
    }

    func testExecutionSignalDoesNotPublishOrRevealRunJournal() throws {
        let store = makeStore()
        let run = try XCTUnwrap(store.begin(action: action, scope: scope))
        store.update(id: run.id) { $0.sessionID = "owned"; $0.state = .runningCommand }
        var publications = 0
        let observation = store.$runs.dropFirst().sink { _ in publications += 1 }
        ProjectActionCoordinator(store: store).receive(.execution(sessionID: "owned"), backendID: scope.backendID, contractID: scope.contractID)
        XCTAssertEqual(publications, 0)
        XCTAssertTrue(store.run(id: run.id)?.isHidden ?? false)
        withExtendedLifetime(observation) {}
    }

    private func commandContext(fake: ActionBackend, isV2: Bool = false) async throws -> (AppViewModel, OpenCodeSession, OpenCodeCommand) {
        let model = makeViewModel(fake: fake)
        model.connectionStore.apiProfile = isV2 ? .v2 : nil
        let session = try await fake.session(id: "composer", scope: scope.backendScope)
        model.selectedSession = session
        model.directoryCommands = try await fake.listCommands(scope: scope.backendScope)
        return (model, session, try XCTUnwrap(model.directoryCommands.first))
    }

    func testInjectedCommandAutocompleteAndDirectSubmissionPreserveSelectionsAndMentions() async throws {
        let fake = ActionBackend()
        let (model, session, command) = try await commandContext(fake: fake)
        let attachment = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "a.txt", mime: "text/plain", dataURL: "data:text/plain;base64,YQ==")
        let mention = OpenCodeAgentMention(name: "explore", content: "@explore", start: 6, end: 14)
        model.composerStore.resetActiveDraft(text: "/test @explore", agentMentions: [mention], attachments: [attachment])
        model.modelConfigurationStore.selectAgent(named: "build", forSessionID: session.id)
        model.modelConfigurationStore.selectModel(.init(providerID: "provider", modelID: "model"), forSessionID: session.id)
        model.modelConfigurationStore.selectVariant("high", forSessionID: session.id)
        XCTAssertEqual(model.chatFacade.commands(forSessionID: session.id, canFork: true).map(\.name), ["test"])
        XCTAssertEqual(model.slashCommandInput(from: model.draftMessage)?.command.name, "test")
        let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            meterPrompt: false, arguments: "@explore", attachments: [attachment])
        XCTAssertTrue(accepted)
        let request = try XCTUnwrap(fake.commandRequests.first)
        XCTAssertEqual(fake.commandRequests.count, 1)
        XCTAssertEqual(request.arguments, "@explore")
        XCTAssertEqual(request.attachments, [attachment])
        XCTAssertEqual(request.agentMentions, [OpenCodeAgentMention(name: "explore", content: "@explore", start: 0, end: 8)])
        XCTAssertEqual(request.scope, scope.backendScope)
        XCTAssertEqual(request.agent, "build")
        XCTAssertEqual(request.model, .init(providerID: "provider", modelID: "model"))
        XCTAssertEqual(request.variant, "high")
        XCTAssertTrue(request.resume)
        XCTAssertEqual(model.chatStore.promptAdmissions[request.messageID]?.phase, .admitted)
        XCTAssertEqual(model.chatStore.promptAdmissions[request.messageID]?.agentMentions, [mention])
        XCTAssertTrue(model.draftMessage.isEmpty)
        XCTAssertTrue(model.draftAttachments.isEmpty)
        XCTAssertEqual(model.directoryStore.sessionStatuses[session.id], "busy", "Admission is not completion")
        XCTAssertEqual(fake.operations, ["command"], "No text-prompt fallback, wait, or evaluator")
    }

    func testInjectedSlashSendUsesCommandServiceInsteadOfTextPrompt() async throws {
        let fake = ActionBackend()
        let (model, _, _) = try await commandContext(fake: fake)
        model.composerStore.resetActiveDraft(text: "/test --all")
        await model.sendCurrentMessage(meterPrompt: false)
        XCTAssertEqual(fake.commandRequests.count, 1)
        XCTAssertEqual(fake.commandRequests.first?.arguments, "--all")
        XCTAssertNil(fake.evaluation)
    }

    func testOptionalServiceAbsenceAndNativeCommandsRemainIndependentlyGated() async throws {
        let fake = ActionBackend()
        fake.includesCommandService = false
        fake.capabilities = [.commands, .fork, .compaction]
        let (model, session, command) = try await commandContext(fake: fake)
        XCTAssertTrue(model.chatFacade.commands(forSessionID: session.id, canFork: true).isEmpty)
        for command in [command, OpenClientChatCommands.fork, OpenClientChatCommands.compact] {
            let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true, meterPrompt: false)
            XCTAssertFalse(accepted)
        }
        XCTAssertTrue(fake.commandRequests.isEmpty, "Capability flags alone cannot enable missing service methods")
        fake.includesCommandService = true
        model.backendConnection = fake.connection()
        model.directoryCommands += [OpenClientChatCommands.fork, OpenClientChatCommands.compact]
        XCTAssertEqual(model.chatFacade.commands(forSessionID: session.id, canFork: true).map(\.name), ["test"])
        let compact = await model.sendCommand(OpenClientChatCommands.compact, arguments: "", attachments: [], in: session, userVisible: true, meterPrompt: false)
        XCTAssertFalse(compact)
        XCTAssertTrue(fake.commandRequests.isEmpty)
    }

    func testUncertainOrMismatchedCommandReceiptRetainsIdentityDraftAndQuotaWithoutRetry() async throws {
        for isV2 in [false, true] {
            let fake = ActionBackend()
            let (model, session, command) = try await commandContext(fake: fake, isV2: isV2)
            let meter = CommandUsageStore()
            model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free),
                usageStore: meter, purchaseManager: OpenClientPurchaseManager())
            model.commerceFacade.hydratePersistedState()
            let mention = OpenCodeAgentMention(name: "explore", content: "@explore", start: 6, end: 14)
            let attachment = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "a.txt", mime: "text/plain", dataURL: "data:text/plain;base64,YQ==")
            model.composerStore.resetActiveDraft(text: "/test @explore", agentMentions: [mention], attachments: [attachment])
            let token = model.composerStore.resetToken
            fake.commandAdmission = { .accepted(sessionID: $0.sessionID, messageID: "wrong-receipt") }
            let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
                arguments: "@explore", attachments: [attachment])
            XCTAssertFalse(accepted)
            let request = try XCTUnwrap(fake.commandRequests.first)
            XCTAssertEqual(model.draftMessage, "/test @explore")
            XCTAssertEqual(model.draftAgentMentions, [mention])
            XCTAssertEqual(model.draftAttachments, [attachment])
            XCTAssertEqual(model.composerStore.resetToken, token)
            XCTAssertEqual(meter.meter.dailyPromptCount, 4)
            XCTAssertEqual(model.chatStore.promptAdmissions[request.messageID]?.phase, .uncertain)
            XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: request.messageID, sessionID: session.id), .uncertain)
            // Idle is not proof of rejection and must not permit a new command POST.
            model.directoryStore.applySessionStatus("idle", forSessionID: session.id)
            let retry = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
                arguments: "@explore", attachments: [attachment])
            XCTAssertFalse(retry)
            XCTAssertEqual(fake.commandRequests.map(\.messageID), [request.messageID])
            XCTAssertEqual(meter.meter.dailyPromptCount, 4)
            XCTAssertNotNil(model.errorMessage)
        }
    }

    func testCommandRejectionRefundsOnlyReservedQuotaAndPreservesNewerDraft() async throws {
        let fake = ActionBackend()
        let (model, session, command) = try await commandContext(fake: fake)
        let meter = CommandUsageStore()
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free),
            usageStore: meter, purchaseManager: OpenClientPurchaseManager())
        model.commerceFacade.hydratePersistedState()
        fake.beforeCommand = { _ in model.composerStore.resetActiveDraft(text: "New draft") }
        fake.commandAdmission = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
        model.composerStore.resetActiveDraft(text: "/test")
        let rejected = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true)
        XCTAssertFalse(rejected)
        XCTAssertEqual(meter.meter.dailyPromptCount, 3)
        XCTAssertEqual(model.draftMessage, "New draft")
        XCTAssertEqual(model.directoryStore.sessionStatuses[session.id], "idle")
        let id = try XCTUnwrap(fake.commandRequests.first?.messageID)
        XCTAssertEqual(model.chatStore.promptAdmissions[id]?.phase, .rejected)
        XCTAssertFalse(model.messages.contains { $0.id == id })
        let unmetered = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true, meterPrompt: false)
        XCTAssertFalse(unmetered)
        XCTAssertEqual(meter.meter.dailyPromptCount, 3)
    }

    func testCanonicalCommandAdmissionWinsOverConflictingRejection() async throws {
        for isV2 in [false, true] {
            let fake = ActionBackend()
            let (model, session, command) = try await commandContext(fake: fake, isV2: isV2)
            fake.beforeCommand = { request in
                let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Expanded command", messageID: request.messageID, sessionID: session.id)
                XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: try XCTUnwrap(model.backendConnection?.id)))
            }
            fake.commandAdmission = { .rejected(sessionID: $0.sessionID, messageID: $0.messageID) }
            model.composerStore.resetActiveDraft(text: "/test")
            let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true, meterPrompt: false)
            XCTAssertTrue(accepted)
            XCTAssertTrue(model.draftMessage.isEmpty)
            XCTAssertEqual(fake.commandRequests.count, 1)
        }
    }

    func testCommandReservationPreventsConcurrentPostsAndFencesReplacementDraft() async throws {
        let fake = ActionBackend()
        let (model, session, command) = try await commandContext(fake: fake)
        model.composerStore.resetActiveDraft(text: "/test")
        var resume: CheckedContinuation<Void, Never>?
        fake.beforeCommand = { _ in await withCheckedContinuation { resume = $0 } }
        let first = Task { await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true, meterPrompt: false) }
        while resume == nil { await Task.yield() }
        let duplicate = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true, meterPrompt: false)
        XCTAssertFalse(duplicate)
        XCTAssertEqual(fake.commandRequests.count, 1)
        model.backendConnection = fake.connection(id: "replacement")
        model.composerStore.resetActiveDraft(text: "Replacement draft")
        model.errorMessage = "Replacement error"
        resume?.resume()
        let accepted = await first.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(model.draftMessage, "Replacement draft")
        XCTAssertEqual(model.errorMessage, "Replacement error")
        XCTAssertEqual(fake.commandRequests.count, 1)
    }

    func testCommandUsesCallerIdentityAndPreReservedQuotaWithoutSecondPost() async throws {
        for isV2 in [false, true] {
            let fake = ActionBackend()
            let (model, session, command) = try await commandContext(fake: fake, isV2: isV2)
            let meter = CommandUsageStore()
            meter.meter.dailyPromptCount = 4
            model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free),
                usageStore: meter, purchaseManager: OpenClientPurchaseManager())
            model.commerceFacade.hydratePersistedState()
            let id = "caller-command-input"
            let mention = OpenCodeAgentMention(name: "explore", content: "@explore", start: 6, end: 14)
            // The animated composer has already captured and cleared its local draft.
            let accepted = await model.sendCommand(command, arguments: "@explore", attachments: [], in: session,
                userVisible: true, messageID: id, agentMentions: [mention], reservedPromptDay: meter.meter.promptDay)
            XCTAssertTrue(accepted)
            XCTAssertEqual(fake.commandRequests.first?.messageID, id)
            XCTAssertEqual(fake.commandRequests.first?.agentMentions.first?.start, 0)
            XCTAssertEqual(meter.meter.dailyPromptCount, 4)
            XCTAssertEqual(model.chatStore.promptAdmissions[id]?.phase, .admitted)
            XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: id, sessionID: session.id), .admitted)
            let repeated = await model.sendCommand(command, arguments: "@explore", attachments: [], in: session,
                userVisible: true, messageID: id, agentMentions: [mention], reservedPromptDay: meter.meter.promptDay)
            XCTAssertTrue(repeated)
            XCTAssertEqual(fake.commandRequests.map(\.messageID), [id])
            XCTAssertEqual(meter.meter.dailyPromptCount, 4)
        }
    }

    func testThrownOrExplicitlyUncertainCommandAdmissionNeverClearsDraft() async throws {
        for throwsTransport in [false, true] {
            let fake = ActionBackend()
            let (model, session, command) = try await commandContext(fake: fake)
            model.composerStore.resetActiveDraft(text: "/test")
            fake.uncertainCommand = true
            if throwsTransport { fake.beforeCommand = { _ in throw URLError(.timedOut) } }
            let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true, meterPrompt: false)
            XCTAssertFalse(accepted)
            XCTAssertEqual(model.draftMessage, "/test")
            let id = try XCTUnwrap(fake.commandRequests.first?.messageID)
            XCTAssertEqual(model.chatStore.promptAdmissions[id]?.phase, .uncertain)
            XCTAssertEqual(fake.commandRequests.count, 1)
        }
    }

    func testServerCommandNamedCompactDoesNotInvokeLocalCompaction() async throws {
        let fake = ActionBackend()
        let (model, session, _) = try await commandContext(fake: fake)
        let command = OpenCodeCommand(name: "compact", description: nil, agent: nil, model: nil, source: nil, template: "Server command", subtask: nil, hints: [])
        model.directoryCommands = [command]
        model.composerStore.resetActiveDraft(text: "/compact")
        let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true, meterPrompt: false)
        XCTAssertTrue(accepted)
        XCTAssertEqual(fake.commandRequests.first?.command, "compact")
        XCTAssertEqual(fake.operations, ["command"])
    }

    func testV2UICommandForwardsCapturedIdentityMentionsAttachmentsAndReservedQuota() async throws {
        let fake = ActionBackend()
        let (model, session, command) = try await commandContext(fake: fake, isV2: true)
        let meter = CommandUsageStore()
        meter.meter.dailyPromptCount = 4
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free),
            usageStore: meter, purchaseManager: OpenClientPurchaseManager())
        model.commerceFacade.hydratePersistedState()
        let attachment = OpenCodeComposerAttachment(id: "captured", kind: .file, filename: "a.txt", mime: "text/plain", dataURL: "data:text/plain;base64,YQ==")
        let mention = OpenCodeAgentMention(name: "explore", content: "@explore", start: 6, end: 14)
        fake.uncertainCommand = true
        // Both UI send paths capture these values before clearing their local draft.
        model.composerStore.resetActiveDraft()
        let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            meterPrompt: false, restoreDraftOnFailure: false, arguments: "@explore", attachments: [attachment],
            messageID: "ui-command", agentMentions: [mention], reservedPromptDay: meter.meter.promptDay)
        XCTAssertFalse(accepted)
        let request = try XCTUnwrap(fake.commandRequests.first)
        XCTAssertEqual(request.messageID, "ui-command")
        XCTAssertEqual(request.attachments, [attachment])
        XCTAssertEqual(request.agentMentions, [.init(name: "explore", content: "@explore", start: 0, end: 8)])
        XCTAssertEqual(model.chatFacade.promptAdmissionPhase(messageID: request.messageID, sessionID: session.id), .uncertain)
        XCTAssertTrue(model.chatFacade.isV2PromptInFlight(sessionID: session.id))
        XCTAssertTrue(model.chatFacade.hasUncertainPromptAdmission(sessionID: session.id))
        XCTAssertFalse(model.chatFacade.isV2PromptAdmitted(messageID: request.messageID, sessionID: session.id))
        XCTAssertEqual(meter.meter.dailyPromptCount, 4)

        fake.transcriptMessages = [.local(role: "user", text: "Expanded server command", messageID: request.messageID, sessionID: session.id)]
        let resolved = await model.chatFacade.resolvePromptAdmission(messageID: request.messageID, sessionID: session.id)
        XCTAssertTrue(resolved)
        XCTAssertTrue(model.chatFacade.isV2PromptAdmitted(messageID: request.messageID, sessionID: session.id))
        let repeated = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            meterPrompt: false, arguments: "@explore", attachments: [attachment], messageID: request.messageID,
            agentMentions: [mention], reservedPromptDay: meter.meter.promptDay)
        XCTAssertTrue(repeated)
        XCTAssertEqual(fake.commandRequests.count, 1)
        XCTAssertEqual(meter.meter.dailyPromptCount, 4)
    }

    func testUncertainGenericCommandBlocksV2TextAcrossDirectAndFacadeEntries() async throws {
        let fake = ActionBackend()
        let (model, session, command) = try await commandContext(fake: fake, isV2: true)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UnexpectedCommandNetworkProtocol.self]
        let network = URLSession(configuration: configuration)
        defer { network.invalidateAndCancel() }
        let config = OpenCodeServerConfig(baseURL: "https://blocked.invalid", apiPreference: .v2)
        let adapter = OpenCodeBackendAdapter(client: OpenCodeAPIClient(config: config, session: network), profile: .v2)
        model.config = config
        model.backendConnection = BackendConnection(descriptor: .init(id: "fake", name: "OpenCode", version: "0.0.0-next-17155"),
            capabilities: [.commands, .interactions], projects: adapter, sessions: fake, chat: fake, models: fake, events: fake, commands: fake)
        model.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true)
        fake.uncertainCommand = true
        let commandAccepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            meterPrompt: false, messageID: "original-command")
        XCTAssertFalse(commandAccepted)
        XCTAssertEqual(model.chatStore.submissionRecoveries["original-command"]?.phase, .uncertain,
            "V2 commands retain recovery content separately from their connection-scoped admission receipt")
        model.directoryStore.applySessionStatus("idle", forSessionID: session.id)

        let directText = await model.sendV2TextPrompt("new text", in: session, meterPrompt: false, messageID: "new-text")
        let facadeText = await model.chatFacade.sendV2TextPrompt("new text", in: session, messageID: "another-text")
        let sameIDText = await model.sendV2TextPrompt("different payload", in: session, meterPrompt: false, messageID: "original-command")
        let anotherCommand = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            meterPrompt: false, messageID: "new-command")
        XCTAssertFalse(directText)
        XCTAssertFalse(facadeText)
        XCTAssertFalse(sameIDText)
        XCTAssertFalse(anotherCommand)
        XCTAssertNil(fake.evaluation, "None of the text entry points may POST while a command receipt is unresolved")
        XCTAssertEqual(fake.commandRequests.map(\.messageID), ["original-command"])
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
    }

    func testPendingV2TextBlocksCommandAndUnifiedPredicateRequiresExactEvidence() async throws {
        let fake = ActionBackend()
        let (model, session, command) = try await commandContext(fake: fake, isV2: true)
        let optimistic = OpenCodeMessageEnvelope.local(role: "user", text: "same text", messageID: "pending-text", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(optimistic, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: optimistic.id, sessionID: session.id)
        let commandAccepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            meterPrompt: false, messageID: "blocked-command")
        XCTAssertFalse(commandAccepted)
        XCTAssertTrue(fake.commandRequests.isEmpty)
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        XCTAssertFalse(model.chatFacade.isPromptAdmitted(messageID: optimistic.id, sessionID: session.id))
        model.chatStore.confirmSubmissionAdmission(messageID: optimistic.id, sessionID: session.id)
        XCTAssertTrue(model.chatFacade.isPromptAdmitted(messageID: optimistic.id, sessionID: session.id))
        XCTAssertFalse(model.chatFacade.isPromptAdmitted(messageID: optimistic.id, sessionID: "different-session"))
        XCTAssertFalse(model.chatFacade.isPromptAdmitted(messageID: "different-id", sessionID: session.id))
        XCTAssertFalse(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
    }

    func testAcceptedUICommandDoesNotResetAlreadyClearedComposerAgain() async throws {
        let fake = ActionBackend()
        let (model, session, command) = try await commandContext(fake: fake, isV2: true)
        model.composerStore.resetActiveDraft()
        let uiResetToken = model.composerStore.resetToken
        let accepted = await model.chatFacade.sendCommand(command, sessionID: session.id, userVisible: true,
            meterPrompt: false, restoreDraftOnFailure: false, messageID: "ui-owned-reset")
        XCTAssertTrue(accepted)
        XCTAssertEqual(model.composerStore.resetToken, uiResetToken,
            "The view may already contain a newer unpersisted draft; admission must not trigger another UI reset")
    }

    func testRetryResolutionDoesNotTreatCachedOptimisticRowsAsCanonical() async throws {
        let fake = ActionBackend()
        let (model, session, _) = try await commandContext(fake: fake, isV2: true)
        let local = OpenCodeMessageEnvelope.local(role: "user", text: "/test", messageID: "retry-input", sessionID: session.id)
        model.chatStore.cacheMessages([local], forSessionID: session.id)
        XCTAssertFalse(model.chatFacade.isPromptAdmitted(messageID: local.id, sessionID: session.id))
        var resolved = await model.chatFacade.resolvePromptAdmission(messageID: local.id, sessionID: session.id)
        XCTAssertFalse(resolved)
        fake.transcriptMessages = [.local(role: "assistant", text: "/test", messageID: local.id, sessionID: session.id)]
        resolved = await model.chatFacade.resolvePromptAdmission(messageID: local.id, sessionID: session.id)
        XCTAssertFalse(resolved)
        fake.transcriptMessages = [.local(role: "user", text: "/test", messageID: local.id, sessionID: "wrong-session")]
        resolved = await model.chatFacade.resolvePromptAdmission(messageID: local.id, sessionID: session.id)
        XCTAssertFalse(resolved)
        // Only the raw backend transcript response is authoritative, not the identical cached value.
        fake.transcriptMessages = [local]
        resolved = await model.chatFacade.resolvePromptAdmission(messageID: local.id, sessionID: session.id)
        XCTAssertTrue(resolved)
        XCTAssertTrue(model.chatFacade.isPromptAdmitted(messageID: local.id, sessionID: session.id))
        XCTAssertEqual(fake.transcriptReads, 4)
        XCTAssertTrue(fake.commandRequests.isEmpty)
        XCTAssertNil(fake.evaluation)
        model.backendConnection = fake.connection(id: "replacement")
        XCTAssertFalse(model.chatFacade.isPromptAdmitted(messageID: local.id, sessionID: session.id))
    }

    func testQuotedCommandLiteralRemainsTextWhileSlashActionUsesCommandEndpoint() async throws {
        for literal in ["\"/test --all\"", "`/test --all`", "Explain /test --all", "/unknown --all"] {
            let fake = ActionBackend()
            let (model, _, _) = try await commandContext(fake: fake)
            XCTAssertNil(model.chatFacade.slashCommandInput(from: literal))
            model.composerStore.resetActiveDraft(text: literal)
            await model.sendCurrentMessage(meterPrompt: false)
            XCTAssertTrue(fake.commandRequests.isEmpty)
            XCTAssertEqual(fake.evaluation?.text, literal)
            XCTAssertEqual(fake.operations, ["prompt"])
        }
        let fake = ActionBackend()
        let (model, _, _) = try await commandContext(fake: fake)
        model.composerStore.resetActiveDraft(text: "/test \"quoted argument\"")
        await model.sendCurrentMessage(meterPrompt: false)
        XCTAssertEqual(fake.commandRequests.first?.arguments, "\"quoted argument\"")
        XCTAssertNil(fake.evaluation)
        XCTAssertEqual(fake.operations, ["command"])
    }
}

@MainActor
private final class ActionBackend: BackendFactory, BackendProjectsService, BackendSessionsService, BackendChatService, BackendModelsService, BackendEventSource, BackendCommandsService {
    var actionContractID = "fake.actions.v1"
    var commandCatalogScopes: [BackendScope] = []
    var failCommandCatalog = false
    var onModelCatalog: (() -> Void)?
    var includesCommandService = true
    var capabilities: Set<BackendCapability> = []
    var commandRequests: [BackendCommandSubmission] = []
    var commandAdmission: ((BackendCommandSubmission) -> BackendAdmission)?
    var beforeCommand: ((BackendCommandSubmission) async throws -> Void)?
    var transcriptMessages: [OpenCodeMessageEnvelope] = []
    var transcriptReads = 0
    var operations: [String] = []
    var creation: BackendSessionCreation?
    var command: BackendCommandSubmission?
    var evaluation: BackendSubmission?
    var beforeCreate: (() async -> Void)?
    var onFirstTurn: (() -> Void)?
    var uncertainCommand = false
    var uncertainEvaluation = false
    var neverCompletes = false
    var attention = false
    var result = "SUCCESS"
    var deleteCount = 0
    var renameCount = 0

    func connect() async throws -> BackendConnection { connection() }

    func connection(id: String = "fake") -> BackendConnection {
        .init(descriptor: .init(id: id, name: "Fake", version: "1"),
              capabilities: capabilities, projects: self, sessions: self, chat: self, models: self, events: self,
              commands: includesCommandService ? self : nil)
    }

    func projectsSnapshot() async throws -> BackendProjectsSnapshot { .init(projects: []) }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage { .init(sessions: []) }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        .init(id: id, title: "Action", workspaceID: scope.workspaceID, directory: scope.directory, projectID: scope.projectID, parentID: nil)
    }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        creation = request
        operations.append("create")
        await beforeCreate?()
        return try await session(id: "ses_action", scope: request.scope)
    }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession {
        renameCount += 1
        throw BackendError.disconnected
    }
    func deleteSession(id: String, scope: BackendScope) async throws { deleteCount += 1 }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        transcriptReads += 1
        return .init(messages: transcriptMessages)
    }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        operations.append("prompt")
        evaluation = request
        return uncertainEvaluation ? .uncertain(sessionID: request.sessionID, messageID: request.messageID)
            : .accepted(sessionID: request.sessionID, messageID: request.messageID)
    }
    func interrupt(sessionID: String, scope: BackendScope) async throws { }
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog {
        onModelCatalog?()
        return .init()
    }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { }
    func stop() { }
    func listCommands(scope: BackendScope) async throws -> [OpenCodeCommand] {
        commandCatalogScopes.append(scope)
        if failCommandCatalog { throw BackendError.disconnected }
        return [.init(name: "test", description: nil, agent: nil, model: nil, source: nil, template: "Run tests", subtask: nil, hints: [])]
    }
    func submitCommand(_ request: BackendCommandSubmission) async throws -> BackendAdmission {
        operations.append("command")
        command = request
        commandRequests.append(request)
        try await beforeCommand?(request)
        if let commandAdmission { return commandAdmission(request) }
        return uncertainCommand ? .uncertain(sessionID: request.sessionID, messageID: request.messageID)
            : .accepted(sessionID: request.sessionID, messageID: request.messageID)
    }
    func waitUntilIdle(sessionID: String, scope: BackendScope) async throws { operations.append("wait") }
    func completedTurn(sessionID: String, userMessageID: String, scope: BackendScope) async throws -> BackendActionTurn? {
        operations.append("turn")
        if neverCompletes { return nil }
        if let onFirstTurn {
            self.onFirstTurn = nil
            onFirstTurn()
            return nil
        }
        let marker = evaluation?.text.components(separatedBy: "\n").first { $0.hasSuffix(":SUCCESS") } ?? "command complete"
        return .init(sessionID: sessionID, userMessageID: userMessageID, assistantMessageID: "assistant-\(userMessageID)",
            text: marker.replacingOccurrences(of: ":SUCCESS", with: ":\(result)"), failed: false)
    }
    func needsAttention(sessionID: String, scope: BackendScope) async throws -> Bool { attention }
}

private final class CommandUsageStore: OpenClientUsagePersisting {
    var meter = OpenClientUsageMeter(promptDay: OpenClientUsageMeter.dayString(for: Date()), dailyPromptCount: 3, createdSessionCount: 0)
    func load() -> OpenClientUsageMeter { meter }
    func save(_ meter: OpenClientUsageMeter) { self.meter = meter }
}

private final class UnexpectedCommandNetworkProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        XCTFail("Pending admission must block network follow-ups: \(request.url?.path ?? "")")
        client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
    }
    override func stopLoading() { }
}

private final class ActionCommandURLProtocol: URLProtocol, @unchecked Sendable {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            XCTAssertEqual(request.url?.path, "/api/session/ses_action/command")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertNil(request.url?.query)
            XCTAssertNil(request.value(forHTTPHeaderField: "x-opencode-directory"))
            var data = request.httpBody ?? Data()
            if data.isEmpty, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    data.append(contentsOf: buffer.prefix(count))
                }
            }
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
            XCTAssertEqual(body["id"] as? String, "msg_action")
            XCTAssertEqual(body["command"] as? String, "test")
            XCTAssertEqual(body["arguments"] as? String, "--all")
            XCTAssertNil(body["text"])
            XCTAssertEqual(body["agent"] as? String, "build")
            XCTAssertEqual(body["model"] as? [String: String], ["providerID": "provider", "id": "model", "variant": "high"])
            XCTAssertEqual(body["files"] as? [[String: String]], [["uri": "data:text/plain;base64,YQ==", "name": "test.txt"]])
            XCTAssertEqual(body["resume"] as? Bool, false)
            let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(#"{"data":{"id":"msg_action","sessionID":"ses_action","timeCreated":123,"type":"user","data":{"text":"expanded command","files":[],"agents":[],"skills":[],"metadata":{}},"delivery":"queued"}}"#.utf8))
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }
    override func stopLoading() { }
}
