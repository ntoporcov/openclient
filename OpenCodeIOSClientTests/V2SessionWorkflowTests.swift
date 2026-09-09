import XCTest
import Combine
@testable import OpenClient

@MainActor
final class V2SessionWorkflowTests: XCTestCase {
    private var originalDraftData: Data?

    override func setUp() async throws {
        originalDraftData = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
        _ = URLProtocol.registerClass(V2SessionWorkflowURLProtocol.self)
    }

    override func tearDown() async throws {
        V2SessionWorkflowURLProtocol.handler = nil
        URLProtocol.unregisterClass(V2SessionWorkflowURLProtocol.self)
        UserDefaults.standard.set(originalDraftData, forKey: OpenClientStorageKey.messageDraftsByChat)
    }

    func testCommittedRootTranscriptReachesExistingGlobalOwnerWindowsBeforeBridgeRetirement() async throws {
        for viaHTTP in [true, false] {
            let model = makeModel()
            defer { model.stopEventStream() }
            let session = Self.session(id: "ses_v2", directory: "/repo/worktree")
            let global = model.directoryStoreRegistry.activate(nil)
            global.insertV2Session(session)
            let connection = try model.requireBackendConnection()
            let input = OpenCodeMessageEnvelope.local(role: "user", text: "local longer content", messageID: "msg_local", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
            let header = OpenCodeMessageEnvelope(info: input.info, parts: [])
            model.chatStore.beginV2TranscriptHydration(sessionID: session.id)
            XCTAssertTrue(model.chatStore.applyInitialV2Transcript([header], olderCursor: nil, sessionID: session.id))
            global.applyV2Messages([header], forSessionID: session.id)
            let windows = (0..<2).map { _ in ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model,
                connection: connection, session: session, owner: global)) }
            defer { windows.forEach { $0.windowContext?.close() } }
            windows[0].composerStore.draftMessage = "Window draft"
            _ = model.beginSessionNavigation(session)
            let root = model.directoryStore
            XCTAssertFalse(root === global)
            let otherWorkspace = OpenCodeSession(id: session.id, title: nil, workspaceID: "other-workspace",
                directory: session.directory, projectID: nil, parentID: nil)
            let foreign = model.directoryStoreRegistry.store(for: "/foreign-container")
            foreign.insertV2Session(otherWorkspace)
            let foreignMessage = OpenCodeMessageEnvelope.local(role: "user", text: "Other workspace", messageID: input.id, sessionID: session.id)
            foreign.applyV2Messages([foreignMessage], forSessionID: session.id)
            let facades = [model.chatFacade] + windows
            func visible(_ facade: ChatFacade, recoveries: [ChatStore.SubmissionRecovery]) -> [OpenCodeMessageEnvelope] {
                let canonical = facade.directoryStore(forSessionID: session.id).syncState.messageEnvelopes(forSessionID: session.id)
                return SubmissionTranscriptPresentation.messages(canonical: canonical, recoveries: recoveries)
                    .filter { MessageBubbleMessageVisibilityPolicy.shouldDisplay($0, showsToolCalls: true, showsReasoningBlocks: true) }
            }
            for facade in facades {
                XCTAssertEqual(visible(facade, recoveries: facade.recoveryInputs(sessionID: session.id)).map(\.id), [input.id])
            }
            var retirementSnapshots = 0
            let observation = model.chatStore.$submissionRecoveries.dropFirst().sink { recoveries in
                guard recoveries[input.id] == nil else { return }
                retirementSnapshots += 1
                for facade in facades {
                    let rows = visible(facade, recoveries: Array(recoveries.values))
                    XCTAssertEqual(rows.map(\.id), [input.id], "Every actual presentation source must be committed before retirement")
                    XCTAssertEqual(rows.first?.parts.first?.text, "canonical")
                }
            }
            V2SessionWorkflowURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET", "Propagating a commit must not submit or retry a prompt")
                XCTAssertEqual(request.url?.path, "/api/session/ses_v2/message")
                return (200, Self.page(input.id))
            }
            if viaHTTP {
                let hydrated = await model.hydrateV2Transcript(for: session, navigationGeneration: model.sessionNavigationGeneration,
                    expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
                XCTAssertTrue(hydrated)
            } else {
                XCTAssertTrue(model.chatStore.applyInitialV2Transcript([header], olderCursor: nil, sessionID: session.id))
                root.applyV2Messages([header], forSessionID: session.id)
                for json in [
                    #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"msg_local","input":{"type":"user","delivery":"steer","data":{"text":"canonical"}}}}"#,
                    #"{"type":"session.input.promoted","data":{"sessionID":"ses_v2","inputID":"msg_local"}}"#
                ] {
                    model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: json)))
                }
            }
            await Task.yield()
            XCTAssertEqual(retirementSnapshots, 1)
            XCTAssertTrue(model.chatStore.recoveryInputs(sessionID: session.id).isEmpty)
            for facade in facades {
                XCTAssertEqual(visible(facade, recoveries: []).first?.parts.first?.text, "canonical")
                XCTAssertEqual(facade.presentationMessages, root.syncState.messageEnvelopes(forSessionID: session.id))
            }
            XCTAssertEqual(windows[0].composerStore.draftMessage, "Window draft")
            XCTAssertEqual(foreign.syncState.messageEnvelopes(forSessionID: session.id), [foreignMessage])
            for json in [
                #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_answer","ordinal":0}}"#,
                #"{"type":"session.text.delta","data":{"sessionID":"ses_v2","assistantMessageID":"msg_answer","ordinal":0,"delta":"Live answer"}}"#
            ] {
                model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: json)))
            }
            for facade in facades {
                XCTAssertEqual(facade.presentationMessages.last?.parts.first?.text, "Live answer", "Copies stay current after the bridge retires")
            }
            withExtendedLifetime(observation) {}
        }
    }

    func testRevertAfterHeaderClearsOnlyInclusiveCanonicalRangeAndHTTPDoesNotResurrectBridge() async throws {
        let model = makeModel()
        defer { model.stopEventStream() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let owner = model.directoryStore
        owner.insertV2Session(session)
        let connection = try model.requireBackendConnection()
        let ids = ["before", "boundary", "after"]
        for id in ids {
            XCTAssertTrue(model.chatStore.beginPromptAdmission(.init(sessionID: session.id, messageID: id,
                text: "Local \(id)", scope: .init(directory: session.directory)), connectionID: connection.id))
            model.chatStore.applyPromptAdmission(.admitted, messageID: id, connectionID: connection.id)
        }
        var canonicalIDs = ids
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/message")
            reads += 1
            let records = canonicalIDs.enumerated().reversed().map { index, id in
                #"{"id":"\#(id)","type":"user","text":"","time":{"created":\#(index + 1)}}"#
            }.joined(separator: ",")
            return (200, #"{"data":[\#(records)],"cursor":{}}"#)
        }
        let hydrated = await model.hydrateV2Transcript(for: session, navigationGeneration: model.sessionNavigationGeneration,
            expectedDirectoryKey: model.directoryStoreRegistry.activeKey)
        XCTAssertTrue(hydrated)
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ids)
        let unknown = OpenCodeMessageEnvelope.local(role: "user", text: "Unknown input", messageID: "unknown", sessionID: session.id)
        model.chatStore.stageSubmissionPresentation(unknown, sessionID: session.id,
            canonical: owner.syncState.messageEnvelopes(forSessionID: session.id), attachments: [], agentMentions: [])
        model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"unknown","input":{"type":"user","delivery":"steer","data":{"text":"Canonical unknown"}}}}"#)))
        let ledger = model.chatStore.canonicalSubmissionSessions
        let usage = model.usageMeter
        for boundary in ["not-loaded", "boundary"] {
            let json = #"{"type":"session.revert.committed","data":{"sessionID":"ses_v2","to":"\#(boundary)"}}"#
            model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from: json)))
            if boundary == "not-loaded" {
                XCTAssertEqual(Set(model.chatStore.recoveryInputs(sessionID: session.id).map(\.id)), Set(ids + ["unknown"]))
            }
        }
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["before"], "The boundary is removed inclusively before any HTTP reconciliation")
        XCTAssertEqual(Set(model.chatStore.recoveryInputs(sessionID: session.id).map(\.id)), ["before", "unknown"])
        canonicalIDs = ["before"]
        for _ in 0..<2 {
            await model.reconcileV2TimelineFromEvent(sessionID: session.id)
            XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["before"])
            XCTAssertEqual(Set(model.chatStore.recoveryInputs(sessionID: session.id).map(\.id)), ["before", "unknown"])
            let projected = SubmissionTranscriptPresentation.messages(canonical: model.chatFacade.presentationMessages,
                recoveries: model.chatFacade.recoveryInputs(sessionID: session.id))
            XCTAssertFalse(projected.contains { $0.id == "boundary" || $0.id == "after" })
            XCTAssertEqual(model.chatStore.canonicalSubmissionSessions, ledger)
            XCTAssertEqual(model.chatStore.applyPromptAdmission(.rejected, messageID: "boundary", connectionID: connection.id), .admitted)
            XCTAssertFalse(model.chatStore.beginPromptAdmission(.init(sessionID: session.id, messageID: "boundary", text: "Resend", scope: .init()), connectionID: connection.id))
            XCTAssertEqual(model.usageMeter, usage)
        }
        XCTAssertGreaterThanOrEqual(reads, 3)
        model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"session.input.promoted","data":{"sessionID":"ses_v2","inputID":"unknown"}}"#)))
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).last?.parts.first?.text, "Canonical unknown",
            "An input outside the explicit canonical range must keep its admission payload")
    }

    func testInitialHydrationRetriesStreamRaceBeforePublishingDirectory() async throws {
        let model = makeModel()
        var session = Self.session(id: "ses_v2", directory: "/repo")
        session.agent = "plan"
        model.modelConfigurationStore.selectedAgentNamesBySessionID[session.id] = "build"
        _ = model.beginSessionNavigation(session)
        let owner = model.directoryStore
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/message")
            reads += 1
            if reads == 1 {
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_live","ordinal":0}}"#))
                _ = model.chatStore.applyV2StreamEvent(event, sessionID: session.id)
                return (200, Self.page("msg_stale"))
            }
            XCTAssertFalse(owner.syncState.messageEnvelopes(forSessionID: session.id).contains { $0.id == "msg_stale" })
            return (200, Self.page("msg_canonical"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertTrue(accepted)
        XCTAssertEqual(reads, 2)
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["msg_canonical"])
        XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["msg_canonical"])
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
        XCTAssertEqual(model.modelConfigurationStore.selectedAgentNamesBySessionID[session.id], "plan")
        XCTAssertEqual(model.sessionPreviews[session.id]?.text, "canonical")
    }

    func testV2ProjectActionsAreUnavailableAtBothSnapshotAndIntent() async {
        let model = makeModel()
        let action = OpenCodeAction(commandName: "review", iconName: "bolt")
        model.projectActionsByScope[model.currentProjectPreferenceScopeKey] = [action]
        model.directoryCommands = [.init(name: "review", description: nil, agent: nil, model: nil,
            source: "command", template: "review", subtask: false, hints: [])]
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTFail("Unsupported action must not create hidden work: \(request.url?.path ?? "nil")")
            return (500, "{}")
        }
        XCTAssertFalse(model.supportsProjectActionExecution)
        XCTAssertTrue(model.sessionListFacade.snapshot.currentProjectActions.isEmpty)
        await model.sessionListFacade.runAction(action)
        XCTAssertNotNil(model.errorMessage)
        XCTAssertTrue(model.pendingActionRunsBySessionID.isEmpty)
    }

    func testInitialHydrationCannotPublishAfterServerReset() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let owner = model.directoryStore
        V2SessionWorkflowURLProtocol.handler = { _ in
            model.directoryStoreRegistry.reset()
            model.chatStore.clearActiveTranscript()
            model.errorMessage = "new connection"
            return (200, Self.page("msg_stale"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertFalse(accepted)
        XCTAssertTrue(owner.syncState.messageEnvelopes(forSessionID: session.id).isEmpty)
        XCTAssertTrue(model.chatStore.messages.isEmpty)
        XCTAssertEqual(model.errorMessage, "new connection")
        XCTAssertEqual(model.chatDetailPresentationRequest, 0)
    }

    func testReconcilerCompletingInitialHydrationPresentsDetailOnlyOnce() async throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { _ in
            reads += 1
            if reads == 1 {
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.text.started","data":{"sessionID":"ses_v2","assistantMessageID":"msg_live","ordinal":0}}"#))
                _ = model.chatStore.applyV2StreamEvent(event, sessionID: session.id)
                await model.reconcileV2TimelineFromEvent(sessionID: session.id)
                XCTAssertEqual(model.chatDetailPresentationRequest, 1)
                return (200, Self.page("msg_stale"))
            }
            return (200, Self.page("msg_canonical"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["msg_canonical"])
    }

    func testHydrationCannotPresentDetailAfterNavigatingAway() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        V2SessionWorkflowURLProtocol.handler = { _ in
            _ = model.beginSessionNavigation(Self.session(id: "ses_other", directory: "/other"))
            return (200, Self.page("msg_stale"))
        }

        let accepted = await model.hydrateV2Transcript(for: session,
            navigationGeneration: model.sessionNavigationGeneration, expectedDirectoryKey: model.directoryStoreRegistry.activeKey)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.chatDetailPresentationRequest, 0)
        XCTAssertEqual(model.selectedSession?.id, "ses_other")
        XCTAssertEqual(model.directoryStoreRegistry.activeKey, "/other")
    }

    func testListNavigationPreservesOutgoingTextAndMentionsAndResetsIncomingComposer() {
        let model = makeModel()
        let first = Self.session(id: "ses_v2", directory: "/repo")
        let second = Self.session(id: "ses_other", directory: "/other")
        let mention = OpenCodeAgentMention(name: "explore", content: "@explore", start: 0, end: 8)
        _ = model.beginSessionNavigation(first)
        model.composerStore.resetActiveDraft(text: "@explore inspect", agentMentions: [mention], attachments: [
            .init(id: "file", kind: .file, filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
        ])
        model.composerStore.draftsByChatKey[model.messageDraftStorageKey(for: second)] = .init(text: "second draft")

        _ = model.beginSessionNavigation(second)

        XCTAssertEqual(model.composerStore.draft(forKey: model.messageDraftStorageKey(for: first))?.text, "@explore inspect")
        XCTAssertEqual(model.composerStore.draft(forKey: model.messageDraftStorageKey(for: first))?.agentMentions, [mention])
        XCTAssertEqual(model.draftMessage, "second draft")
        XCTAssertTrue(model.draftAgentMentions.isEmpty)
        XCTAssertTrue(model.draftAttachments.isEmpty)

        _ = model.beginSessionNavigation(first)
        XCTAssertEqual(model.draftMessage, "@explore inspect")
        XCTAssertEqual(model.draftAgentMentions, [mention])
    }

    func testGlobalCreationUsesConcreteLocationAndPresentsHydratedSession() async throws {
        let model = makeModel()
        guard model.hasProUnlock else { throw XCTSkip("Creation tests require the debug entitlement to avoid metering persistence.") }
        model.currentProject = OpenCodeProject(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
        model.selectedDirectory = nil
        // This test bypasses connection bootstrap; provide its concrete execution location.
        model.projectStore.defaultServerDirectory = "/actual/workspace"
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session":
                let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.body(request)) as? [String: Any])
                XCTAssertEqual((body["location"] as? [String: Any])?["directory"] as? String, "/actual/workspace")
                return (200, #"{"data":{"id":"ses_created","projectID":"global","location":{"directory":"/actual/workspace"},"agent":"plan","model":{"providerID":"openai","id":"server-model","variant":"high"},"time":{"created":1,"updated":2},"cost":0,"tokens":{"input":0,"output":0,"reasoning":0,"cache":{"read":0,"write":0}}}}"#)
            case "/api/session/active":
                return (200, #"{"data":{}}"#)
            case "/api/session/ses_created/message":
                XCTAssertEqual(model.selectedSession?.id, "ses_created")
                XCTAssertEqual(model.chatDetailPresentationRequest, 0)
                return (200, #"{"data":[],"cursor":{}}"#)
            case "/api/session/ses_created/permission", "/api/session/ses_created/form":
                return (200, #"{"data":[]}"#)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }

        await model.createSession()

        XCTAssertNil(model.errorMessage)
        XCTAssertEqual(model.directoryStoreRegistry.activeKey, "/actual/workspace")
        XCTAssertEqual(model.chatStore.preparedSessionID, "ses_created")
        XCTAssertEqual(model.chatDetailPresentationRequest, 1)
        XCTAssertEqual(model.modelConfigurationStore.selectedAgentNamesBySessionID["ses_created"], "plan")
        XCTAssertEqual(model.modelConfigurationStore.selectedModelsBySessionID["ses_created"], .init(providerID: "openai", modelID: "server-model"))
        XCTAssertEqual(model.modelConfigurationStore.selectedVariantsBySessionID["ses_created"], "high")
    }

    func testRejectedBackgroundPromptRollsBackCacheWithoutTouchingNewChatOrUsage() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        let other = Self.session(id: "ses_other", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let usage = model.usageMeter
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/api/session/ses_v2/prompt")
            XCTAssertEqual(model.chatStore.cachedMessagesBySessionID[session.id]?.first?.parts.first?.id,
                model.chatStore.cachedMessagesBySessionID[session.id]?.first.map { "\($0.id):v2:text:0" })
            _ = model.beginSessionNavigation(other)
            let message = OpenCodeMessageEnvelope.local(role: "user", text: "other chat", messageID: "other", sessionID: other.id)
            model.chatStore.applyInitialV2Transcript([message], olderCursor: nil, sessionID: other.id)
            model.errorMessage = "other error"
            return (422, #"{"message":"Rejected"}"#)
        }

        let accepted = await model.sendV2TextPrompt("hello", in: session, meterPrompt: false)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.selectedSession?.id, other.id)
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["other"])
        XCTAssertTrue(model.chatStore.cachedMessagesBySessionID[session.id]?.isEmpty == true)
        XCTAssertFalse(model.chatStore.isV2PromptInFlight(sessionID: session.id))
        XCTAssertEqual(model.errorMessage, "other error")
        XCTAssertEqual(model.usageMeter, usage)
    }

    func testUncertainAdmissionPreservesDraftAndBlocksDuplicatePOST() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        model.draftMessage = "hello"
        var posts = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.httpMethod == "POST" {
                posts += 1
                return (503, #"{"message":"Receipt unavailable"}"#)
            }
            return (404, #"{"message":"Projection not ready"}"#)
        }

        let accepted = await model.sendV2TextPrompt("hello", in: session, meterPrompt: false)
        model.stopEventStream()
        let retry = await model.sendV2TextPrompt("hello", in: session, meterPrompt: false)

        XCTAssertFalse(accepted)
        XCTAssertFalse(retry)
        XCTAssertEqual(posts, 1)
        XCTAssertEqual(model.draftMessage, "hello")
        XCTAssertTrue(model.chatStore.isV2PromptInFlight(sessionID: session.id))
    }

    func testReconciliationBridgesGapAndRemovesRevertedLoadedRecords() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let old = OpenCodeMessageEnvelope.local(role: "user", text: "old", messageID: "msg_old", sessionID: session.id)
        let reverted = OpenCodeMessageEnvelope.local(role: "user", text: "reverted", messageID: "msg_reverted", sessionID: session.id)
        model.chatStore.applyInitialV2Transcript([old, reverted], olderCursor: nil, sessionID: session.id)
        let newestIDs = (0 ..< 200).map { "msg_new_\($0)" }
        let records = newestIDs.reversed().map { #"{"id":"\#($0)","type":"user","text":"canonical","time":{"created":1}}"# }.joined(separator: ",")
        var reads = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            reads += 1
            let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
            if reads == 1 {
                XCTAssertEqual(query, [.init(name: "order", value: "desc"), .init(name: "limit", value: "200")])
                return (200, #"{"data":[\#(records)],"cursor":{"next":"older"}}"#)
            }
            XCTAssertEqual(query, [.init(name: "cursor", value: "older"), .init(name: "limit", value: reads == 2 ? "1" : "200")])
            return (200, Self.page("msg_old"))
        }

        await model.reconcileV2TimelineFromEvent(sessionID: session.id)

        XCTAssertEqual(reads, 3, "Existence probe must not consume the older page needed for reconciliation")
        XCTAssertEqual(model.chatStore.messages.map(\.id), ["msg_old"] + newestIDs)
        XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["msg_old"] + newestIDs)
        XCTAssertFalse(model.chatStore.hasOlderV2Messages(sessionID: session.id))
    }

    func testHydratingOneSessionPreservesOtherSessionsAndRacingPermission() async throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let other = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
            #"{"type":"permission.asked","data":{"sessionID":"ses_other","id":"perm_other","action":"read","resources":["*"]}}"#))
        _ = model.directoryStore.applyV2Event(other)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertTrue(request.url?.path.hasPrefix("/api/session/ses_v2/") == true)
            if request.url?.path.hasSuffix("/permission") == true {
                let event = try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"permission.asked","data":{"sessionID":"ses_v2","id":"perm_live","action":"read","resources":["*"]}}"#))
                _ = model.directoryStore.applyV2Event(event)
            }
            return (200, #"{"data":[]}"#)
        }

        await model.hydrateV2Interactions(for: session)

        XCTAssertEqual(model.directoryStore.syncState.permissionsBySessionID["ses_other"]?.map(\.id), ["perm_other"])
        XCTAssertEqual(model.directoryStore.syncState.permissionsBySessionID[session.id]?.map(\.id), ["perm_live"])
    }

    func testOnlyDefinitiveAdmissionFailuresAllowRollbackAndRetry() {
        for code in [400, 401, 403, 404, 422, 429] { XCTAssertTrue(AppViewModel.isDefinitiveV2PromptRejection(code)) }
        for code in [200, 408, 409, 500, 502, 503, 504] { XCTAssertFalse(AppViewModel.isDefinitiveV2PromptRejection(code)) }
    }

    func testPendingInboxReadResolvesExactIDWithoutResendingPrompt() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "queued", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(message, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: message.id, sessionID: session.id)
        var paths: [String] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/inbox") == true {
                return (200, #"{"data":[{"id":"msg_pending"}]}"#)
            }
            return (404, #"{"message":"Still queued"}"#)
        }

        let accepted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: message.id)

        XCTAssertTrue(accepted)
        XCTAssertEqual(paths, ["/api/session/ses_v2/message/msg_pending", "/api/session/ses_v2/inbox"])
        XCTAssertFalse(model.chatStore.isV2PromptInFlight(sessionID: session.id))
        XCTAssertEqual(model.chatStore.submissionRecoveries[message.id]?.phase, .admitted)
    }

    func testPendingInputAbsenceDoesNotUnlockOrSwitchEndpoint() async {
        let model = makeModel()
        model.connectionStore.serverVersion = "2.0.0-next-17155"
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "queued", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(message, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: message.id, sessionID: session.id)
        var paths: [String] = []
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            paths.append(request.url?.path ?? "")
            if request.url?.path.hasSuffix("/pending") == true { return (200, #"{"data":[{"id":"msg_unrelated"}]}"#) }
            return (404, #"{"message":"Not found"}"#)
        }

        let accepted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: message.id)

        XCTAssertFalse(accepted)
        XCTAssertEqual(paths, ["/api/session/ses_v2/message/msg_pending", "/api/session/ses_v2/pending"])
        XCTAssertTrue(model.chatStore.isV2PromptInFlight(sessionID: session.id))
    }

    func testUncertainPOSTIsConfirmedByQueuedInputWithoutAnotherPOST() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        var promptPosts = 0
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_v2/prompt":
                promptPosts += 1
                return (503, #"{"message":"Receipt lost"}"#)
            case "/api/session/ses_v2/message/msg_queued":
                return (404, #"{"message":"Still queued"}"#)
            case "/api/session/ses_v2/inbox":
                return (200, #"{"data":[{"id":"msg_queued"}]}"#)
            case "/api/session/ses_v2/wait":
                XCTAssertEqual(model.chatStore.submissionRecoveries["msg_queued"]?.phase, .admitted)
                return (204, "")
            case "/api/session/ses_v2/message":
                return (200, #"{"data":[],"cursor":{}}"#)
            default:
                XCTFail("Unexpected request: \(request.url?.path ?? "nil")")
                throw URLError(.unsupportedURL)
            }
        }

        let accepted = await model.sendV2TextPrompt("queued", in: session, meterPrompt: false, messageID: "msg_queued")

        XCTAssertTrue(accepted)
        XCTAssertEqual(promptPosts, 1)
        XCTAssertFalse(model.chatStore.isV2PromptInFlight(sessionID: session.id))
        XCTAssertTrue(model.chatStore.messages.isEmpty)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_queued"]?.phase, .admitted)
    }

    func testAdmissionReturnsWhileCompletionIsHeld() async {
        let model = makeModel()
        defer { model.disconnect() }
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let waiting = expectation(description: "Completion wait is held")
        let returned = expectation(description: "Admission returns before completion")
        let reconciled = expectation(description: "Completion still reconciles canonical messages")
        var release: CheckedContinuation<Void, Never>?
        V2SessionWorkflowURLProtocol.handler = { request in
            switch request.url?.path {
            case "/api/session/ses_v2/prompt":
                return (200, #"{"data":{"id":"msg_first","sessionID":"ses_v2","timeCreated":1,"delivery":"accepted"}}"#)
            case "/api/session/ses_v2/wait":
                await withCheckedContinuation { release = $0; waiting.fulfill() }
                return (204, "")
            case "/api/session/ses_v2/message":
                reconciled.fulfill()
                return (200, Self.page("msg_first"))
            default:
                XCTFail("Unexpected request")
                throw URLError(.unsupportedURL)
            }
        }
        let submission = Task {
            let accepted = await model.sendV2TextPrompt("first", in: session, meterPrompt: false, messageID: "msg_first")
            XCTAssertTrue(accepted)
            returned.fulfill()
        }
        await fulfillment(of: [waiting, returned], timeout: 1)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_first"]?.phase, .admitted)
        release?.resume()
        await submission.value
        await fulfillment(of: [reconciled], timeout: 1)
    }

    func testFinishingAnAdmittedRequestCannotChangeNewerAdmissionState() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let completionObserved = expectation(description: "Completion observes a newer submission")
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/prompt") == true {
                return (200, #"{"data":{"id":"msg_first","sessionID":"ses_v2","timeCreated":1,"delivery":"queue"}}"#)
            }
            XCTAssertTrue(request.url?.path.hasSuffix("/wait") == true)
            let second = OpenCodeMessageEnvelope.local(role: "user", text: "second", messageID: "msg_second", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(second, sessionID: session.id))
            completionObserved.fulfill()
            throw URLError(.timedOut)
        }

        let accepted = await model.sendV2TextPrompt("first", in: session, meterPrompt: false, messageID: "msg_first")
        await fulfillment(of: [completionObserved], timeout: 1)
        model.stopEventStream()

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_first"]?.phase, .admitted)
        XCTAssertEqual(model.chatStore.submissionRecoveries["msg_second"]?.phase, .submitting)
        XCTAssertTrue(model.chatStore.isV2PromptInFlight(sessionID: session.id))
    }

    func testLateInboxReadCannotConfirmAdmissionInNewServerGeneration() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let original = OpenCodeMessageEnvelope.local(role: "user", text: "original", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(original, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: original.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            if request.url?.path.hasSuffix("/inbox") == true {
                model.directoryStoreRegistry.reset()
                model.chatStore.clearCachedMessages(forSessionID: session.id)
                let replacement = OpenCodeMessageEnvelope.local(role: "user", text: "new server", messageID: original.id, sessionID: session.id)
                XCTAssertTrue(model.chatStore.beginV2Prompt(replacement, sessionID: session.id))
                return (200, #"{"data":[{"id":"msg_pending"}]}"#)
            }
            return (404, #"{"message":"Not projected"}"#)
        }

        let accepted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: original.id)

        XCTAssertFalse(accepted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[original.id]?.phase, .submitting)
    }

    func testConfirmedPendingIDCannotBeSubmittedAgain() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let message = OpenCodeMessageEnvelope.local(role: "user", text: "queued", messageID: "msg_pending", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(message, sessionID: session.id))
        model.chatStore.confirmSubmissionAdmission(messageID: message.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { _ in
            XCTFail("A confirmed pending ID must not be submitted again")
            throw URLError(.unsupportedURL)
        }

        let accepted = await model.sendV2TextPrompt("queued", in: session, meterPrompt: false, messageID: message.id)

        XCTAssertTrue(accepted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[message.id]?.phase, .admitted)
        XCTAssertFalse(model.chatStore.cachedMessagesBySessionID[session.id]?.contains { $0.id == message.id } == true)
    }

    func testFacadeOlderMessagesCountsCanonicalIDsForRootAndWindow() async throws {
        for inWindow in [false, true] {
            for pageKind in ["empty", "duplicate", "200-new"] {
                let model = makeModel()
                defer { model.disconnect() }
                let connection = try model.requireBackendConnection()
                let root = Self.session(id: "ses_root", directory: "/repo")
                _ = model.beginSessionNavigation(root)
                let session = inWindow ? Self.session(id: "ses_window", directory: "/window") : root
                let owner = model.directoryStoreRegistry.store(for: session.directory)
                owner.insertV2Session(session)
                let context = inWindow ? ChatWindowContext(model: model, connection: connection,
                    session: session, owner: owner) : nil
                defer { context?.close() }
                let facade = inWindow ? ChatFacade(viewModel: model, windowContext: context) : model.chatFacade
                let existing = OpenCodeMessageEnvelope.local(role: "user", text: "canonical",
                    messageID: "msg_existing", sessionID: session.id)
                model.chatStore.beginV2TranscriptHydration(sessionID: session.id)
                XCTAssertTrue(model.chatStore.applyInitialV2Transcript([existing], olderCursor: "older", sessionID: session.id))
                owner.applyV2Messages([existing], forSessionID: session.id)
                let ids = pageKind == "empty" ? [] : pageKind == "duplicate" ? [existing.id]
                    : (1...200).map { "msg_older_\($0)" }
                var reads = 0
                V2SessionWorkflowURLProtocol.handler = { request in
                    reads += 1
                    XCTAssertEqual(request.url?.path, "/api/session/\(session.id)/message")
                    let query = URLComponents(url: try XCTUnwrap(request.url), resolvingAgainstBaseURL: false)?.queryItems
                    XCTAssertEqual(query?.first { $0.name == "cursor" }?.value, "older")
                    XCTAssertEqual(query?.first { $0.name == "limit" }?.value, "200")
                    // Growth in another session must not contribute to the facade's result.
                    let unrelated = OpenCodeMessageEnvelope.local(role: "assistant", text: "live",
                        messageID: "msg_unrelated", sessionID: "ses_unrelated")
                    model.directoryStore.applyV2Messages([unrelated], forSessionID: "ses_unrelated")
                    let records = ids.map {
                        #"{"id":"\#($0)","type":"user","text":"canonical","time":{"created":1}}"#
                    }.joined(separator: ",")
                    return (200, #"{"data":[\#(records)],"cursor":{}}"#)
                }

                let added = await facade.loadOlderMessages(for: session, count: 12)

                XCTAssertEqual(reads, 1, "window=\(inWindow), page=\(pageKind)")
                XCTAssertEqual(added, pageKind == "200-new" ? 200 : 0,
                    "window=\(inWindow), page=\(pageKind)")
                XCTAssertEqual(Set(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id)),
                    Set(ids).union([existing.id]))
                XCTAssertEqual(model.selectedSession?.id, root.id)
            }
        }
    }

    private static func session(id: String, directory: String) -> OpenCodeSession {
        OpenCodeSession(id: id, title: nil, workspaceID: nil, directory: directory, projectID: nil, parentID: nil)
    }

    func testRootAndDedicatedWindowsShareCanonicalOrderButNotRecoveryDrafts() throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let connection = try model.requireBackendConnection()
        let owner = model.directoryStore
        owner.insertV2Session(session)
        let a = ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model, connection: connection, session: session, owner: owner))
        let b = ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model, connection: connection, session: session, owner: owner))
        defer { a.windowContext?.close(); b.windowContext?.close() }
        model.composerStore.draftMessage = "New root draft"
        a.composerStore.draftMessage = "New A draft"
        b.composerStore.draftMessage = "New B draft"
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Unconfirmed", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        let first = OpenCodeMessageEnvelope.local(role: "user", text: "Other input", messageID: "msg_other", sessionID: session.id)
        let answer = OpenCodeMessageEnvelope.local(role: "assistant", text: "Canonical answer", messageID: "msg_answer", sessionID: session.id)
        for page in [[first], [first, answer]] {
            model.chatStore.applyV2EventProjection(page, olderCursor: nil, sessionID: session.id)
            owner.applyV2Messages(model.chatStore.cachedMessagesBySessionID[session.id] ?? [], forSessionID: session.id)
            for facade in [model.chatFacade, a, b] {
                XCTAssertEqual(facade.presentationMessages, page)
                XCTAssertEqual(facade.recoveryInputs(sessionID: session.id).map(\.message), [input])
            }
        }
        model.chatStore.applyV2EventProjection([input, first, answer], olderCursor: nil, sessionID: session.id)
        owner.applyV2Messages(model.chatStore.cachedMessagesBySessionID[session.id] ?? [], forSessionID: session.id)
        model.chatStore.retireSubmissionPresentations(in: owner.syncState.messageEnvelopes(forSessionID: session.id), sessionID: session.id)
        for facade in [model.chatFacade, a, b] {
            XCTAssertEqual(facade.presentationMessages, [input, first, answer])
            XCTAssertTrue(facade.recoveryInputs(sessionID: session.id).isEmpty)
            XCTAssertTrue(facade.isPromptAdmitted(messageID: input.id, sessionID: session.id))
        }
        XCTAssertEqual(model.composerStore.draftMessage, "New root draft")
        XCTAssertEqual(a.composerStore.draftMessage, "New A draft")
        XCTAssertEqual(b.composerStore.draftMessage, "New B draft")
    }

    func testCheckRecoveryStatusUsesOnlyReadsForUncertainAndAdmittedInputs() async throws {
        for queued in [false, true] {
            let model = makeModel()
            model.connectionStore.serverVersion = "0.0.0-next-17155"
            let session = Self.session(id: "ses_v2", directory: "/repo")
            _ = model.beginSessionNavigation(session)
            model.directoryStore.insertV2Session(session)
            let input = OpenCodeMessageEnvelope.local(role: "user", text: "Keep", messageID: "msg_local", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
            model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
            if queued { model.chatStore.confirmSubmissionAdmission(messageID: input.id, sessionID: session.id) }
            var paths: [String] = []
            V2SessionWorkflowURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET", "Check status must never submit or wait via POST")
                let path = request.url!.path
                paths.append(path)
                if path.hasSuffix("/message/msg_local") { return (404, "{}") }
                return (200, #"{"data":[]}"#)
            }
            await model.chatFacade.checkRecoveryStatus(messageID: input.id, sessionID: session.id)
            XCTAssertTrue(paths.contains("/api/session/ses_v2/message/msg_local"))
            XCTAssertTrue(paths.contains("/api/session/ses_v2/pending"))
            XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, queued ? .admitted : .uncertain)
            XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.pendingStatusUnknown, queued)
            XCTAssertTrue(model.chatStore.messages.isEmpty)
        }
    }

    func testReadPromotionBetweenExactAndPendingMissesRemainsUnknownUntilCanonicalPage() async {
        let model = makeModel()
        model.connectionStore.serverVersion = "0.0.0-next-17155"
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Local", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/message/msg_local") { return (404, "{}") }
            if request.url!.path.hasSuffix("/pending") { return (200, #"{"data":[]}"#) }
            return (200, Self.page("msg_local"))
        }
        let admitted = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: input.id)
        XCTAssertFalse(admitted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .uncertain)
        await model.reconcileV2TimelineFromEvent(sessionID: session.id)
        XCTAssertNil(model.chatStore.submissionRecoveries[input.id])
        XCTAssertTrue(model.chatFacade.isPromptAdmitted(messageID: input.id, sessionID: session.id))
        XCTAssertEqual(model.chatStore.messages.first?.parts.first?.text, "canonical")
    }

    func testExactReadKeepsRecoveryUntilCanonicalPageCanSupplyServerOrder() async {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Local content", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/message/msg_local") {
                return (200, #"{"data":{"id":"msg_local","type":"user","text":"Canonical content","time":{"created":1}}}"#)
            }
            return (503, "{}")
        }
        await model.chatFacade.checkRecoveryStatus(messageID: input.id, sessionID: session.id)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .admitted)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.text, "Local content")
        XCTAssertTrue(model.chatStore.messages.isEmpty)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            return (200, Self.page("msg_local"))
        }
        await model.reconcileV2TimelineFromEvent(sessionID: session.id)
        XCTAssertNil(model.chatStore.submissionRecoveries[input.id])
        XCTAssertEqual(model.chatStore.messages.first?.parts.first?.text, "canonical")
    }

    func testLatePendingReadCannotAffectReplacementConnectionOrForeignCollidingInput() async throws {
        let model = makeModel()
        let session = Self.session(id: "ses_v2", directory: "/repo")
        _ = model.beginSessionNavigation(session)
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "A", messageID: "msg_local", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
        model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
        V2SessionWorkflowURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            if request.url!.path.hasSuffix("/inbox") {
                model.disconnect()
                model.config = .init(baseURL: "https://foreign.invalid", apiPreference: .v2)
                model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
                _ = try model.requireBackendConnection()
                let foreign = OpenCodeMessageEnvelope.local(role: "user", text: "B", messageID: input.id, sessionID: session.id)
                XCTAssertTrue(model.chatStore.beginV2Prompt(foreign, sessionID: session.id))
                return (200, #"{"data":[{"id":"msg_local"}]}"#)
            }
            return (404, "{}")
        }
        let result = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: input.id, checkPendingStatus: true)
        XCTAssertFalse(result)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.text, "B")
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .submitting)
    }

    func testConnectionTransitionsIsolateCollidingRecoveryAndRestoreSameOwnerInMemory() throws {
        let model = makeModel()
        let configA = model.config
        let input = OpenCodeMessageEnvelope.local(role: "user", text: "Server A", messageID: "msg_same", sessionID: "ses_same")
        XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: "ses_same"))
        model.disconnect()
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        model.config = .init(baseURL: "https://foreign.invalid", apiPreference: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        _ = try model.requireBackendConnection()
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        let foreign = OpenCodeMessageEnvelope.local(role: "user", text: "Server B", messageID: "msg_same", sessionID: "ses_same")
        XCTAssertTrue(model.chatStore.beginV2Prompt(foreign, sessionID: "ses_same"))
        model.chatStore.confirmSubmissionAdmission(messageID: foreign.id, sessionID: "ses_same")
        model.disconnect()
        model.config = configA
        model.connectionStore.applySuccessfulServerConnection(version: "legacy", healthy: true)
        _ = try model.requireBackendConnection()
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        model.disconnect()
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        _ = try model.requireBackendConnection()
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.message, input)
        XCTAssertEqual(model.chatStore.submissionRecoveries[input.id]?.phase, .uncertain)
        XCTAssertTrue(model.chatStore.cachedMessagesBySessionID.isEmpty)
        XCTAssertTrue(ChatStore().submissionRecoveries.isEmpty, "Recovery is not persisted across app process restarts")
    }

    func testAdmissionEvidenceClearsOnlyOwnedWarningNotAnUnrelatedIdenticalError() async throws {
        for evidence in ["pending", "event", "page"] {
            let model = makeModel()
            let session = Self.session(id: "ses_v2", directory: "/repo")
            _ = model.beginSessionNavigation(session)
            let connection = try model.requireBackendConnection()
            let input = OpenCodeMessageEnvelope.local(role: "user", text: "Local", messageID: "msg_local", sessionID: session.id)
            XCTAssertTrue(model.chatStore.beginV2Prompt(input, sessionID: session.id))
            model.chatStore.markSubmissionUncertain(messageID: input.id, sessionID: session.id)
            model.composerStore.draftMessage = "Newer draft"
            let warning = "Same error text"
            model.connectionStore.applyPromptError(warning, connectionID: connection.id, sessionID: session.id, messageID: input.id)
            V2SessionWorkflowURLProtocol.handler = { request in
                XCTAssertEqual(request.httpMethod, "GET")
                if request.url!.path.hasSuffix("/message/msg_local") { return (404, "{}") }
                if request.url!.path.hasSuffix("/inbox") { return (200, #"{"data":[{"id":"msg_local"}]}"#) }
                return (200, Self.page("msg_local"))
            }
            if evidence == "pending" {
                _ = await model.resolveV2PromptAdmission(sessionID: session.id, messageID: input.id)
            } else if evidence == "event" {
                model.handleV2Event(try XCTUnwrap(OpenCodeEventManager.decodeV2Event(from:
                    #"{"type":"session.input.admitted","data":{"sessionID":"ses_v2","inputID":"msg_local","input":{"type":"user","delivery":"queue","data":{"text":"Local"}}}}"#)))
            } else {
                await model.reconcileV2TimelineFromEvent(sessionID: session.id)
            }
            XCTAssertNil(model.errorMessage, evidence)
            model.connectionStore.applyPromptError(warning, connectionID: connection.id, sessionID: session.id, messageID: input.id)
            model.errorMessage = warning // Different error, even though the visible text happens to match.
            _ = model.confirmCanonicalPromptAdmission(input.info, connectionID: connection.id)
            XCTAssertEqual(model.errorMessage, warning)
            XCTAssertEqual(model.composerStore.draftMessage, "Newer draft")
            model.stopEventStream()
        }
    }

    private func makeModel() -> AppViewModel {
        let model = AppViewModel()
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.config = .init(baseURL: "https://v2-session-workflows.invalid", apiPreference: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        _ = try? model.requireBackendConnection()
        #if DEBUG
        model.commerceFacade.debugEntitlementOverride = .unlocked
        #endif
        model.composerStore.draftsByChatKey = [:]
        model.directoryStoreRegistry.activate("/repo")
        return model
    }

    private static func page(_ id: String, cursor: String? = nil) -> String {
        let cursorJSON = cursor.map { #""next":"\#($0)""# } ?? ""
        return #"{"data":[{"id":"\#(id)","type":"user","text":"canonical","time":{"created":1}}],"cursor":{\#(cursorJSON)}}"#
    }

    private static func body(_ request: URLRequest) throws -> Data {
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
}

private final class V2SessionWorkflowURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?

    // Immutable bridge to Foundation callbacks; delivery is confined to the loading task.
    private struct Delivery: @unchecked Sendable {
        let loader: V2SessionWorkflowURLProtocol
    }

    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "v2-session-workflows.invalid"
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let request = request
        let delivery = Delivery(loader: self)
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(V2SessionWorkflowURLProtocol.handler)
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
