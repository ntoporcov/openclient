import Combine
import XCTest
@testable import OpenClient

@MainActor
final class TalkSessionCoordinatorTests: XCTestCase {
    private var originalDraftData: Data?
    private var originalDefaultsData: Data?

    override func setUp() async throws {
        originalDraftData = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
        originalDefaultsData = UserDefaults.standard.data(forKey: "newSessionDefaults")
    }

    override func tearDown() async throws {
        TalkV2URLProtocol.handler = nil
        UserDefaults.standard.set(originalDraftData, forKey: OpenClientStorageKey.messageDraftsByChat)
        UserDefaults.standard.set(originalDefaultsData, forKey: "newSessionDefaults")
    }

    func testFirstTurnBindsCanonicalChatBeforeReceiptAndSnapshotsVoiceSelection() async throws {
        let (model, backend, controller, talk) = try await connectedTalk()
        defer { talk.stop(); model.disconnect() }
        let voice = OpenCodeModelReference(providerID: "talk", modelID: "voice")
        model.newSessionDefaults.voiceModeProviderID = voice.providerID
        model.newSessionDefaults.voiceModeModelID = voice.modelID
        model.newSessionDefaults.agentName = "talk-agent"
        let project = try XCTUnwrap(model.projects.first)
        talk.start(project: project, workspaceDirectory: project.worktree)
        model.newSessionDefaults.voiceModeModelID = "changed-after-start"
        let posted = expectation(description: "First input POST is suspended")
        backend.onSubmit = { posted.fulfill() }
        controller.receiveFinalTranscript("First spoken turn")
        await fulfillment(of: [posted], timeout: 1)

        let request = try XCTUnwrap(backend.submissions.first)
        XCTAssertEqual(talk.phase, .conversation)
        XCTAssertEqual(talk.activeSessionID, request.sessionID)
        XCTAssertEqual(model.selectedSession?.id, request.sessionID)
        XCTAssertEqual(model.chatFacade.activeChatSessionID, request.sessionID)
        XCTAssertEqual(model.chatStore.preparedSessionID, request.sessionID)
        XCTAssertGreaterThan(model.chatDetailPresentationRequest, 0)
        XCTAssertEqual(backend.creations.first?.scope.directory, project.worktree)
        XCTAssertEqual(backend.creations.first?.model, voice)
        XCTAssertEqual(backend.creations.first?.agent, "talk-agent")
        XCTAssertNil(model.backendConnection?.openCodeCompatibility)

        let visible = expectation(description: "Canonical answer is visible while POST is suspended")
        let observation = model.chatStore.$messages.first { messages in
            messages.contains { $0.id == "talk-answer" && $0.parts.first?.text == "Canonical answer" }
        }.sink { _ in visible.fulfill() }
        backend.emitAnswer(for: request)
        await fulfillment(of: [visible], timeout: 1)
        observation.cancel()
        XCTAssertNotNil(backend.receipt)
        XCTAssertEqual(backend.eventStarts, 1)
        XCTAssertFalse(controller.hasStartedLiveActivity)
        backend.finish(.accepted(sessionID: request.sessionID, messageID: request.messageID))
    }

    func testUnknownChildFormsPauseAndSettleOnlyResumesForegroundWithoutPaywall() async throws {
        let (model, backend, controller, talk) = try await connectedTalk()
        defer { talk.stop(); model.disconnect() }
        talk.start(project: try XCTUnwrap(model.projects.first))
        let posted = expectation(description: "Input suspended")
        backend.onSubmit = { posted.fulfill() }
        controller.receiveFinalTranscript("Ask a question")
        await fulfillment(of: [posted], timeout: 1)
        let request = try XCTUnwrap(backend.submissions.first)
        let owner = model.chatFacade.directoryStore(forSessionID: request.sessionID)
        owner.sessions.append(.init(id: "child", title: "Child", workspaceID: nil,
            directory: "/talk", projectID: "talk-project", parentID: request.sessionID))
        let form = BackendForm(id: "unknown-form", sessionID: "child", title: "Needs input", fields: [])
        XCTAssertFalse(form.contract.isSupported())
        let paused = expectation(description: "Unknown native child form pauses Talk")
        let observation = controller.$state.first { $0 == .paused }.sink { _ in paused.fulfill() }
        owner.sessionFormStore.upsert(form)
        await fulfillment(of: [paused], timeout: 1)
        observation.cancel()
        XCTAssertEqual(model.chatFacade.sessionForms(forSessionID: request.sessionID), [form])

        talk.applicationActivityChanged(isActive: false)
        owner.sessionFormStore.settle(form.key)
        await drainMainQueue()
        XCTAssertEqual(controller.state, .paused)
        model.commerceFacade.store.paywallReason = .manual
        talk.applicationActivityChanged(isActive: true)
        XCTAssertEqual(controller.state, .paused)
        model.commerceFacade.store.paywallReason = nil
        await drainMainQueue()
        XCTAssertEqual(controller.state, .waitingForResponse)
        XCTAssertEqual(backend.submissions.count, 1)
        backend.finish(.accepted(sessionID: request.sessionID, messageID: request.messageID))
    }

    func testUncertainReceiptRetainsOriginalIdentityAndNeverResubmits() async throws {
        let (model, backend, controller, talk) = try await connectedTalk()
        defer { talk.stop(); model.disconnect() }
        talk.start(project: try XCTUnwrap(model.projects.first))
        let posted = expectation(description: "Original input posted")
        backend.onSubmit = { posted.fulfill() }
        controller.receiveFinalTranscript("Keep this identity")
        await fulfillment(of: [posted], timeout: 1)
        let request = try XCTUnwrap(backend.submissions.first)
        let paused = expectation(description: "Lost receipt pauses auto listening")
        let observation = controller.$state.first { $0 == .paused }.sink { _ in paused.fulfill() }
        backend.finish(.uncertain(sessionID: request.sessionID, messageID: request.messageID))
        await fulfillment(of: [paused], timeout: 1)
        observation.cancel()
        XCTAssertEqual(talk.pendingMessageID, request.messageID)
        XCTAssertEqual(talk.activeSessionID, request.sessionID)
        talk.applicationActivityChanged(isActive: false)
        talk.applicationActivityChanged(isActive: true)
        controller.receiveFinalTranscript("Do not send again")
        await drainMainQueue()
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(backend.creations.count, 1)
        XCTAssertEqual(backend.submissions.map(\.messageID), [request.messageID])

        let connectionID = try XCTUnwrap(model.backendConnection?.id)
        let unrelated = OpenCodeMessageEnvelope.local(role: "user", text: "Other input",
            messageID: "other-input", sessionID: request.sessionID)
        XCTAssertFalse(model.confirmCanonicalPromptAdmission(unrelated.info, connectionID: connectionID))
        await drainMainQueue()
        XCTAssertEqual(controller.state, .paused)
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: request.text,
            messageID: request.messageID, sessionID: request.sessionID)
        XCTAssertTrue(model.confirmCanonicalPromptAdmission(canonical.info, connectionID: connectionID))
        await drainMainQueue()
        XCTAssertNil(talk.pendingMessageID)
        XCTAssertNotEqual(controller.state, .paused)
        XCTAssertEqual(backend.submissions.count, 1)
    }

    func testNavigationAndReconnectCannotApplySuspendedTalkCompletionToAnotherChat() async throws {
        let (model, backend, controller, talk) = try await connectedTalk()
        defer { talk.stop(); model.disconnect() }
        talk.start(project: try XCTUnwrap(model.projects.first))
        let posted = expectation(description: "Original input posted")
        backend.onSubmit = { posted.fulfill() }
        controller.receiveFinalTranscript("Old chat")
        await fulfillment(of: [posted], timeout: 1)
        let request = try XCTUnwrap(backend.submissions.first)
        let other = OpenCodeSession(id: "other-chat", title: "Other", workspaceID: nil,
            directory: "/talk", projectID: "talk-project", parentID: nil)
        model.prepareSessionSelection(other)
        model.chatFacade.saveMessageDraft("Other draft", forSessionID: other.id)
        model.errorMessage = "Other error"
        await drainMainQueue()
        XCTAssertEqual(controller.state, .paused)
        backend.finish(.accepted(sessionID: request.sessionID, messageID: request.messageID))
        await drainMainQueue()
        XCTAssertEqual(model.selectedSession?.id, other.id)
        XCTAssertEqual(model.draftMessage, "Other draft")
        XCTAssertEqual(model.errorMessage, "Other error")
        await model.connectionFacade.connect()
        await drainMainQueue()
        XCTAssertEqual(talk.phase, .inactive)
        XCTAssertEqual(controller.state, .inactive)
    }

    func testV2TalkAvailabilityDoesNotRequireOrStartLiveActivities() async throws {
        let (model, _, controller, talk) = try await connectedTalk()
        defer { talk.stop(); model.disconnect() }
        model.connectionStore.apiProfile = .v2
        model.connectionStore.backendMode = .serverV2
        XCTAssertTrue(model.projectFacade.allowsNewTalk)
        talk.start(project: try XCTUnwrap(model.projects.first))
        XCTAssertEqual(talk.phase, .listening)
        XCTAssertTrue(controller.isActive)
        XCTAssertFalse(controller.hasStartedLiveActivity)
        talk.applicationActivityChanged(isActive: false)
        controller.resume(isSessionBusy: false)
        XCTAssertEqual(controller.state, .paused)
    }

    func testNavigationDuringCreationRetainsCreatedSessionWithoutSelectingOrPostingIntoAnotherChat() async throws {
        let (model, backend, controller, talk) = try await connectedTalk()
        defer { talk.stop(); model.disconnect() }
        let other = OpenCodeSession(id: "other-before-receipt", title: "Other", workspaceID: nil,
            directory: "/talk", projectID: "talk-project", parentID: nil)
        backend.storedSessions.append(other)
        backend.beforeCreationReturn = {
            await model.chatFacade.selectSession(other)
            model.chatFacade.saveMessageDraft("Other draft", forSessionID: other.id)
            model.errorMessage = "Other error"
        }
        talk.start(project: try XCTUnwrap(model.projects.first))
        let paused = expectation(description: "Creation callback refuses stale navigation")
        let observation = controller.$state.first { $0 == .paused }.sink { _ in paused.fulfill() }
        controller.receiveFinalTranscript("Do not redirect the other chat")
        await fulfillment(of: [paused], timeout: 1)
        observation.cancel()
        await drainMainQueue()
        XCTAssertEqual(model.selectedSession?.id, other.id)
        XCTAssertEqual(model.draftMessage, "Other draft")
        XCTAssertEqual(model.errorMessage, "Other error")
        XCTAssertEqual(talk.activeSessionID, "talk-created")
        XCTAssertNotNil(talk.pendingMessageID)
        XCTAssertEqual(backend.creations.count, 1)
        XCTAssertTrue(backend.submissions.isEmpty)
    }

    func testExistingTalkWaitsQueuedModelConfigurationAndUsesCoreAdmission() async throws {
        let model = makeV2Model()
        let controller = ConversationModeController(usesNativeAudio: false)
        controller.setHoldToTalkEnabled(true)
        var configurationReceipt: CheckedContinuation<Void, Never>?
        var turnReceipt: CheckedContinuation<Void, Never>?
        defer {
            controller.stop()
            model.disconnect()
            configurationReceipt?.resume()
            turnReceipt?.resume()
        }
        let session = OpenCodeSession(id: "talk-created", title: "Existing", workspaceID: nil,
            directory: "/talk", projectID: "talk-project", parentID: nil)
        let voiceModel = OpenCodeModelReference(providerID: "test", modelID: "configured-voice")
        let configurationStarted = expectation(description: "V2 model switch waits for its receipt")
        let turnStarted = expectation(description: "Admitted prompt reaches the v2 turn wait")
        var mutationOrder: [String] = []
        var postedMessageIDs: [String] = []
        TalkV2URLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/talk-created/model":
                XCTAssertEqual(request.httpMethod, "POST")
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                let selection = try XCTUnwrap(body["model"] as? [String: Any])
                XCTAssertEqual(selection["providerID"] as? String, voiceModel.providerID)
                XCTAssertEqual(selection["id"] as? String, voiceModel.modelID)
                mutationOrder.append("model")
                await withCheckedContinuation { continuation in
                    configurationReceipt = continuation
                    configurationStarted.fulfill()
                }
                return (204, "")
            case "/api/session/talk-created/prompt":
                XCTAssertEqual(request.httpMethod, "POST")
                XCTAssertEqual(mutationOrder, ["model"])
                XCTAssertEqual(model.modelConfigurationStore.selectedModelReference(for: session.id), voiceModel)
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
                let messageID = try XCTUnwrap(body["id"] as? String)
                XCTAssertEqual(body["text"] as? String, "Existing chat voice")
                XCTAssertEqual(messageID, controller.submittedMessageID)
                postedMessageIDs.append(messageID)
                mutationOrder.append("prompt")
                return (200, #"{"data":{"id":"\#(messageID)","sessionID":"talk-created","timeCreated":1,"delivery":"accepted"}}"#)
            case "/api/session/talk-created/wait":
                XCTAssertEqual(request.httpMethod, "POST")
                mutationOrder.append("wait")
                await withCheckedContinuation { continuation in
                    turnReceipt = continuation
                    turnStarted.fulfill()
                }
                return (204, "")
            case "/api/session/talk-created/message":
                return (200, Self.v2CanonicalPage)
            default:
                return Self.v2Response(to: request)
            }
        }
        model.directoryStore.sessions = [session]
        await model.chatFacade.selectSession(session)
        model.chatFacade.selectModel(voiceModel, for: session)
        await fulfillment(of: [configurationStarted], timeout: 1)
        controller.start(initialTranscript: "")
        controller.receiveFinalTranscript("Existing chat voice")
        controller.submitTurn(in: session, chatFacade: model.chatFacade)
        let originalMessageID = try XCTUnwrap(controller.submittedMessageID)
        await drainMainQueue()
        XCTAssertEqual(mutationOrder, ["model"])
        XCTAssertTrue(postedMessageIDs.isEmpty)
        XCTAssertNotEqual(model.modelConfigurationStore.selectedModelReference(for: session.id), voiceModel)
        configurationReceipt?.resume()
        configurationReceipt = nil
        await fulfillment(of: [turnStarted], timeout: 1)
        XCTAssertEqual(mutationOrder, ["model", "prompt", "wait"])
        XCTAssertEqual(postedMessageIDs, [originalMessageID])
        XCTAssertNil(controller.submittedMessageID, "The admission lock is released while generation continues")
        XCTAssertTrue(model.chatFacade.isPromptAdmitted(messageID: originalMessageID, sessionID: session.id))
        XCTAssertEqual(controller.state, .waitingForResponse)
        XCTAssertFalse(controller.hasStartedLiveActivity)
    }

    func testV2FirstTurnHydratesOnceAndShowsFormsBeforePromptReceipt() async throws {
        let model = makeV2Model()
        let controller = ConversationModeController(usesNativeAudio: false)
        controller.setHoldToTalkEnabled(true)
        let talk = TalkSessionCoordinator(viewModel: model, conversationController: controller)
        defer { talk.stop(); model.disconnect() }
        let generation = model.sessionNavigationGeneration
        let reading = expectation(description: "Canonical initial read is suspended")
        let posted = expectation(description: "First prompt receipt is suspended")
        let waited = expectation(description: "Accepted prompt reaches turn wait")
        var readReceipt: CheckedContinuation<Void, Never>?
        var promptReceipt: CheckedContinuation<Void, Never>?
        var reads = 0
        var posts = 0
        TalkV2URLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/talk-created/message":
                reads += 1
                if reads == 1 {
                    await withCheckedContinuation { readReceipt = $0; reading.fulfill() }
                }
                return (200, Self.v2CanonicalPage)
            case "/api/session/talk-created/prompt":
                posts += 1
                let id = try XCTUnwrap(talk.pendingMessageID)
                await withCheckedContinuation { promptReceipt = $0; posted.fulfill() }
                return (200, #"{"data":{"id":"\#(id)","sessionID":"talk-created","timeCreated":1,"delivery":"accepted"}}"#)
            case "/api/session/talk-created/wait":
                waited.fulfill()
                return (204, "")
            default:
                return Self.v2Response(to: request)
            }
        }
        talk.start(project: try XCTUnwrap(model.projects.first))
        controller.receiveFinalTranscript("First v2 turn")
        await fulfillment(of: [reading], timeout: 1)
        XCTAssertEqual(talk.phase, .conversation)
        XCTAssertEqual(talk.activeSessionID, "talk-created")
        XCTAssertEqual(model.chatFacade.activeChatSessionID, "talk-created")
        XCTAssertEqual(model.sessionNavigationGeneration, generation &+ 2)
        XCTAssertTrue(model.chatStore.isHydratingV2Transcript(sessionID: "talk-created"))
        XCTAssertTrue(model.chatStore.isLoadingSelectedSession)
        XCTAssertNil(model.chatStore.preparedSessionID)
        readReceipt?.resume()
        await fulfillment(of: [posted], timeout: 1)
        XCTAssertEqual(reads, 1)
        XCTAssertEqual(model.sessionNavigationGeneration, generation &+ 2)
        XCTAssertEqual(model.chatStore.preparedSessionID, "talk-created")
        XCTAssertFalse(model.chatStore.isHydratingV2Transcript(sessionID: "talk-created"))
        XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
        XCTAssertTrue(model.messages.contains { $0.id == "canonical" })
        XCTAssertNotNil(model.backendConnection?.sessionSelection)
        XCTAssertTrue(model.chatFacade.supportsTalkLiveActivities)
        XCTAssertFalse(controller.hasStartedLiveActivity)

        let form = BackendForm(id: "native-form", sessionID: "talk-created", title: "Input required", fields: [])
        model.handleBackendEvent(.sessionForm(directory: "/talk", event: .created(form)))
        await drainMainQueue()
        XCTAssertEqual(model.chatFacade.sessionForms(forSessionID: "talk-created"), [form])
        XCTAssertEqual(controller.state, .paused)
        XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
        model.commerceFacade.store.paywallReason = .manual
        model.handleBackendEvent(.sessionForm(directory: "/talk", event: .cancelled(form.key)))
        await drainMainQueue()
        XCTAssertTrue(model.chatFacade.isPaywallPresented)
        XCTAssertEqual(controller.state, .paused)
        model.commerceFacade.store.paywallReason = nil
        await drainMainQueue()
        XCTAssertEqual(controller.state, .waitingForResponse)
        model.connectionStore.isConnected = false
        await drainMainQueue()
        controller.resume(isSessionBusy: true)
        XCTAssertEqual(controller.state, .paused)
        XCTAssertEqual(posts, 1)
        let finished = expectation(description: "First turn finishes without restarting navigation")
        let observation = controller.$state.first { $0 == .ready }.sink { _ in finished.fulfill() }
        model.connectionStore.isConnected = true
        promptReceipt?.resume()
        await fulfillment(of: [waited, finished], timeout: 1)
        observation.cancel()
        XCTAssertEqual(model.sessionNavigationGeneration, generation &+ 2)
        XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
    }

    func testV2NewChatPreservesInFlightAndCompletedEarlyHydration() async throws {
        for earlyHydration in ["none", "in-flight", "completed"] {
            let model = makeV2Model()
            defer { model.disconnect() }
            let generation = model.sessionNavigationGeneration
            var earlySession: OpenCodeSession?
            var reads = 0
            TalkV2URLProtocol.handler = { request in
                if request.url?.path == "/api/session", request.httpMethod == "GET",
                   earlyHydration == "completed", let session = earlySession {
                    let hydrated = await model.hydrateV2Transcript(for: session,
                        navigationGeneration: model.sessionNavigationGeneration,
                        expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
                    XCTAssertTrue(hydrated)
                    XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
                }
                if request.url?.path == "/api/session/talk-created/message" {
                    reads += 1
                    XCTAssertTrue(model.chatStore.isHydratingV2Transcript(sessionID: "talk-created"))
                    XCTAssertTrue(model.chatStore.isLoadingSelectedSession)
                    XCTAssertNil(model.chatStore.preparedSessionID)
                    return (200, Self.v2CanonicalPage)
                }
                return Self.v2Response(to: request)
            }
            let started = await model.startNewProjectChat(prompt: "New chat", projectID: "talk-project",
                onSessionCreated: { session in
                    if earlyHydration != "none" {
                        _ = model.beginSessionNavigation(session)
                        earlySession = session
                    }
                }, submitInitialPrompt: { session, _, _ in
                    XCTAssertEqual(model.chatStore.preparedSessionID, session.id)
                    XCTAssertFalse(model.chatStore.isHydratingV2Transcript(sessionID: session.id))
                    XCTAssertFalse(model.chatStore.isLoadingSelectedSession)
                    XCTAssertEqual(model.messages.map(\.id), ["canonical"])
                    return true
                })
            XCTAssertTrue(started, earlyHydration)
            XCTAssertEqual(reads, 1, earlyHydration)
            XCTAssertEqual(model.sessionNavigationGeneration, generation &+ 2, earlyHydration)
            XCTAssertFalse(model.chatStore.isLoadingSelectedSession, earlyHydration)
        }
    }

    func testNormalizedV2WireMetadataIsExcludedFromSpeech() async throws {
        let model = makeV2Model()
        defer { model.disconnect() }
        let origins = ["synthetic", "system", "skill", "agent-switched", "model-switched", "location-switched"]
        let records = origins.map { #"{"id":"\#($0)","type":"\#($0)","text":"Wire metadata"}"# }
        TalkV2URLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/talk-created/message")
            let answer = #"{"id":"answer","type":"assistant","content":[{"type":"reasoning","text":"Private thought"},{"type":"text","text":"Public answer"}]}"#
            return (200, "{\"data\":[" + (records + [answer]).joined(separator: ",") + "],\"cursor\":{}}")
        }
        let page = try await XCTUnwrap(model.backendConnection).chat.transcript(sessionID: "talk-created",
            scope: .init(projectID: "talk-project", directory: "/talk"), cursor: nil, limit: 200)
        XCTAssertEqual(page.messages.filter { origins.contains($0.id) }.count, origins.count)
        XCTAssertTrue(page.messages.filter { origins.contains($0.id) }.allSatisfy { $0.parts.allSatisfy { $0.synthetic == true } })
        XCTAssertEqual(ConversationModeController.responseText(from: page.messages, excludingMessageIDs: []), "Public answer")
    }

    func testGlobalFormArrivingDuringNewChatPreparationRefundsPrepaidPromptWithoutPosting() async throws {
        let model = makeV2Model()
        let usage = GlobalFormUsagePersistence()
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free), usageStore: usage)
        defer { model.disconnect() }
        let preparing = expectation(description: "New chat creation suspended after reservation")
        var resume: CheckedContinuation<Void, Never>?
        var promptPosts = 0
        TalkV2URLProtocol.handler = { request in
            if request.url?.path == "/api/session", request.httpMethod == "POST" {
                XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
                await withCheckedContinuation { resume = $0; preparing.fulfill() }
            }
            if request.url?.path.hasSuffix("/prompt") == true {
                promptPosts += 1
                XCTFail("Pending global input must reject before POST")
                return (422, "{}")
            }
            if request.url?.path == "/api/session/talk-created/message" { return (200, Self.v2CanonicalPage) }
            return Self.v2Response(to: request)
        }
        let task = Task { await model.startNewProjectChat(prompt: "New chat", projectID: "talk-project") }
        await fulfillment(of: [preparing], timeout: 2)
        let form = BackendForm(id: "frm_global", sessionID: "global", title: "Input", fields: [])
        model.handleBackendEvent(.globalForm(location: .init(directory: "/talk"), event: .created(form)))
        resume?.resume()
        let accepted = await task.value
        XCTAssertFalse(accepted)
        XCTAssertEqual(promptPosts, 0)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 0)
        XCTAssertEqual(usage.meter.dailyPromptCount, 0)
        XCTAssertEqual(model.usageMeter.createdSessionCount, 1, "The session was created; only its unspent prompt is refunded")
    }

    func testGlobalFormDoesNotRefundAdmissionOwnedOrWrongDayReservationAndInterruptRemainsAvailable() async throws {
        let model = makeV2Model()
        let usage = GlobalFormUsagePersistence()
        model.commerceFacade = CommerceFacade(store: CommerceStore(debugEntitlementOverride: .free), usageStore: usage)
        defer { model.disconnect() }
        let session = OpenCodeSession(id: "talk-created", title: "Busy", workspaceID: nil, directory: "/talk", projectID: "talk-project", parentID: nil)
        model.directoryStore.sessions = [session]
        model.prepareSessionSelection(session)
        model.directoryStore.applySessionStatus("busy", forSessionID: session.id)
        model.handleBackendEvent(.globalForm(location: .init(directory: "/talk"), event: .created(
            .init(id: "frm_global", sessionID: "global", title: "Input", fields: []))))
        XCTAssertTrue(model.reserveUserPromptIfAllowed())
        let day = model.usageMeter.promptDay
        let optimistic = OpenCodeMessageEnvelope.local(role: "user", text: "Already posted", messageID: "msg_owned", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(optimistic, sessionID: session.id))
        var interrupts = 0
        TalkV2URLProtocol.handler = { request in
            if request.url?.path == "/api/session/talk-created/interrupt" { interrupts += 1; return (204, "") }
            if request.url?.path == "/api/session/talk-created/message" { return (200, Self.v2CanonicalPage) }
            return Self.v2Response(to: request)
        }
        let owned = await model.sendV2TextPrompt("Already posted", in: session, messageID: "msg_owned", reservedPromptDay: day)
        XCTAssertFalse(owned)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
        model.chatStore.rollbackV2Prompt(messageID: "msg_owned", sessionID: session.id)
        let stale = await model.sendV2TextPrompt("Not posted", in: session, reservedPromptDay: "2000-01-01")
        XCTAssertFalse(stale)
        XCTAssertEqual(model.usageMeter.dailyPromptCount, 1)
        XCTAssertTrue(model.chatFacade.hasGlobalForms(sessionID: session.id))
        let stopped = await model.chatFacade.interruptV2Session(sessionID: session.id)
        XCTAssertTrue(stopped)
        XCTAssertEqual(interrupts, 1)
    }

    func testExistingChatAdmissionCannotResumeThroughPaywallOrDisconnect() async throws {
        let (model, backend, _, talk) = try await connectedTalk()
        // Existing ChatView owns its controller independently of the new-Talk coordinator.
        let controller = ConversationModeController(usesNativeAudio: false)
        controller.setHoldToTalkEnabled(true)
        defer { controller.stop(); talk.stop(); model.disconnect() }
        let session = OpenCodeSession(id: "existing", title: "Existing", workspaceID: nil,
            directory: "/talk", projectID: "talk-project", parentID: nil)
        model.directoryStore.sessions = [session]
        model.prepareSessionSelection(session)
        controller.start(initialTranscript: "")
        controller.receiveFinalTranscript("Existing voice turn")
        XCTAssertEqual(controller.state, .submitting)
        let posted = expectation(description: "Existing voice POST is suspended")
        backend.onSubmit = { posted.fulfill() }
        controller.submitTurn(in: session, chatFacade: model.chatFacade)
        await fulfillment(of: [posted], timeout: 1)
        let request = try XCTUnwrap(backend.submissions.first)
        model.commerceFacade.store.paywallReason = .manual
        controller.refreshPromptAdmission(chatFacade: model.chatFacade)
        XCTAssertEqual(controller.state, .paused)
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: request.text,
            messageID: request.messageID, sessionID: session.id)
        _ = model.confirmCanonicalPromptAdmission(canonical.info, connectionID: try XCTUnwrap(model.backendConnection?.id))
        controller.refreshPromptAdmission(chatFacade: model.chatFacade)
        controller.resume(isSessionBusy: false)
        XCTAssertEqual(controller.state, .paused)
        model.commerceFacade.store.paywallReason = nil
        model.connectionStore.isConnected = false
        controller.setAudioAvailable(true)
        controller.refreshPromptAdmission(chatFacade: model.chatFacade)
        controller.resume(isSessionBusy: false)
        XCTAssertEqual(controller.state, .paused)
        backend.finish(.accepted(sessionID: session.id, messageID: request.messageID))
    }

    private func makeV2Model() -> AppViewModel {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TalkV2URLProtocol.self]
        let model = AppViewModel()
        model.config = .init(baseURL: "https://talk-v2.invalid", apiPreference: .v2)
        let client = OpenCodeAPIClient(config: model.config, session: URLSession(configuration: configuration))
        model.backendConnection = OpenCodeBackendFactory(client: client, eventManager: model.eventManager)
            .makeConnection(profile: .v2, version: "test", healthy: true)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        model.commerceFacade.store.debugEntitlementOverride = .unlocked
        model.newSessionDefaults = NewSessionDefaults()
        model.projects = [.init(id: "talk-project", worktree: "/talk", vcs: nil,
            name: "Talk", sandboxes: nil, icon: nil, time: nil)]
        model.currentProject = model.projects.first
        model.selectedDirectory = "/talk"
        return model
    }

    private static let v2CanonicalPage = #"{"data":[{"id":"canonical","type":"user","text":"Canonical input","time":{"created":1}}],"cursor":{}}"#
    private static let v2Session = #"{"id":"talk-created","projectID":"talk-project","location":{"directory":"/talk"},"agent":"plan","model":{"providerID":"test","id":"voice"},"time":{"created":1,"updated":2},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}"#

    private static func v2Response(to request: URLRequest) -> (Int, String) {
        switch request.url?.path {
        case "/api/session":
            return request.httpMethod == "POST" ? (200, "{\"data\":" + v2Session + "}")
                : (200, "{\"data\":[" + v2Session + "],\"cursor\":{}}")
        case "/api/session/active": return (200, #"{"data":{}}"#)
        case "/api/model/default": return (200, #"{"data":null}"#)
        case "/api/agent", "/api/provider", "/api/model", "/api/command",
             "/api/session/talk-created/permission", "/api/session/talk-created/form":
            return (200, #"{"data":[]}"#)
        default:
            XCTFail("Unexpected Talk request: \(request.httpMethod ?? "") \(request.url?.path ?? "")")
            return (500, "{}")
        }
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }

    private func connectedTalk() async throws -> (AppViewModel, TalkBackend, ConversationModeController, TalkSessionCoordinator) {
        let backend = TalkBackend()
        let model = AppViewModel(backendFactory: backend)
        model.commerceFacade.store.debugEntitlementOverride = .unlocked
        await model.connectionFacade.connect()
        let project = try XCTUnwrap(model.projects.first)
        await model.projectFacade.completeSelection(model.projectFacade.beginSelection(project))
        let controller = ConversationModeController(usesNativeAudio: false, responseSpeaker: { _ in })
        controller.setHoldToTalkEnabled(true)
        let talk = TalkSessionCoordinator(viewModel: model, conversationController: controller)
        return (model, backend, controller, talk)
    }

    private func drainMainQueue() async {
        // Store publishers announce will-change; Talk consumes the settled snapshot next turn.
        for _ in 0..<4 {
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }
}

private final class GlobalFormUsagePersistence: OpenClientUsagePersisting {
    var meter: OpenClientUsageMeter = .empty
    func load() -> OpenClientUsageMeter { meter }
    func save(_ meter: OpenClientUsageMeter) { self.meter = meter }
}

private final class TalkV2URLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?
    private struct Delivery: @unchecked Sendable { let loader: TalkV2URLProtocol }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, body) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(request.url), statusCode: status,
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch {
                delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error)
            }
        }
    }
    override func stopLoading() {}
}

@MainActor
private final class TalkBackend: BackendFactory, BackendProjectsService, BackendSessionsService,
    BackendChatService, BackendModelsService, BackendEventSource {
    var creations: [BackendSessionCreation] = []
    var submissions: [BackendSubmission] = []
    var storedSessions: [OpenCodeSession] = []
    var receipt: CheckedContinuation<BackendAdmission, Never>?
    var onSubmit: (() -> Void)?
    var beforeCreationReturn: (() async -> Void)?
    var receive: (@MainActor (BackendEvent) -> Void)?
    var eventStarts = 0

    func connect() async throws -> BackendConnection {
        .init(descriptor: .init(id: "talk-test", name: "Talk Test", version: "1"),
            projects: self, sessions: self, chat: self, models: self, events: self)
    }
    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        .init(projects: [.init(id: "talk-project", worktree: "/talk", vcs: nil,
            name: "Talk", sandboxes: nil, icon: nil, time: nil)])
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        .init(sessions: storedSessions)
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession {
        try XCTUnwrap(storedSessions.first { $0.id == id })
    }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        creations.append(request)
        let session = OpenCodeSession(id: "talk-created", title: request.title, workspaceID: request.scope.workspaceID,
            directory: request.scope.directory, projectID: request.scope.projectID, parentID: nil)
        storedSessions.append(session)
        await beforeCreationReturn?()
        return session
    }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession {
        throw BackendError.invalidScope
    }
    func deleteSession(id: String, scope: BackendScope) async throws {}
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { [] }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        .init(messages: [])
    }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        submissions.append(request)
        return await withCheckedContinuation { continuation in
            receipt = continuation
            onSubmit?()
        }
    }
    func interrupt(sessionID: String, scope: BackendScope) async throws {}
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog {
        .init(agents: [.init(name: "talk-agent", description: nil, mode: "primary", hidden: false, model: nil, variant: nil)],
            providers: [.init(id: "talk", name: "Talk", models: [
                "voice": .init(id: "voice", providerID: "talk", name: "Voice", capabilities: .init(reasoning: false))
            ])], defaults: ["talk": "voice"])
    }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { eventStarts += 1; self.receive = receive }
    func stop() {
        receive = nil
        if let request = submissions.last {
            finish(.uncertain(sessionID: request.sessionID, messageID: request.messageID))
        }
    }
    func finish(_ admission: BackendAdmission) { receipt?.resume(returning: admission); receipt = nil }
    func emitAnswer(for request: BackendSubmission) {
        let input = OpenCodeMessageEnvelope.local(role: "user", text: request.text,
            messageID: request.messageID, sessionID: request.sessionID)
        var answer = OpenCodeMessageEnvelope.local(role: "assistant", text: "Canonical answer",
            messageID: "talk-answer", sessionID: request.sessionID)
        answer.parts = [OpenCodePart(
            id: "talk-answer-text", messageID: answer.id, sessionID: request.sessionID,
            type: "text", mime: nil, filename: nil, url: nil, reason: nil,
            tool: nil, callID: nil, state: nil, text: "Canonical answer", time: .init(start: 1, end: 2)
        )]
        for message in [input, answer] {
            receive?(.mutation(directory: request.scope.directory, event: .messageUpdated(message.info)))
            for part in message.parts {
                receive?(.mutation(directory: request.scope.directory, event: .messagePartUpdated(part)))
            }
        }
    }
}
