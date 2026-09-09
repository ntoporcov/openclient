import XCTest
@testable import OpenClient

@MainActor
final class LegacySubmissionRecoveryTests: XCTestCase {
    private let session = OpenCodeSession(id: "ses_legacy", title: "Legacy", workspaceID: nil,
        directory: "/repo", projectID: "project", parentID: nil)

    override func tearDown() {
        LegacyRecoveryURLProtocol.handler = nil
        super.tearDown()
    }

    private func model(host: String = "legacy-recovery.invalid") -> AppViewModel {
        let model = AppViewModel()
        model.config = .init(baseURL: "https://\(host)", apiPreference: .legacy)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [LegacyRecoveryURLProtocol.self]
        let adapter = OpenCodeBackendAdapter(client: .init(config: model.config, session: URLSession(configuration: configuration)), profile: .legacy)
        model.backendConnection = BackendConnection(descriptor: .init(id: host, name: "Legacy", version: "1"),
            capabilities: [], projects: adapter, sessions: adapter, chat: adapter, models: adapter,
            events: OpenCodeBackendEventSource(client: adapter.client, profile: .legacy, manager: model.eventManager))
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.commerceFacade.debugEntitlementOverride = .unlocked
        model.directoryStoreRegistry.activate("/repo")
        model.directoryStore.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        model.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: [])
        model.chatStore.finishLoadingSelectedSession()
        return model
    }

    func testLegacyWorktreeHeaderPartsAndDeltaRouteThroughProjectRootOwner() async throws {
        let model = model()
        let root = model.directoryStore
        let worktree = OpenCodeSession(id: "ses_worktree", title: "Worktree", workspaceID: "workspace",
            directory: "/repo/worktree", projectID: "project", parentID: nil)
        root.insertV2Session(worktree)
        _ = model.beginSessionNavigation(worktree)
        model.prepareSessionSelection(worktree, preservingDraftForSessionID: nil, animatesChanges: false)
        XCTAssertTrue(model.directoryStore === root)
        XCTAssertEqual(model.directoryStoreRegistry.key(for: root), "/repo")
        var posts = 0
        LegacyRecoveryURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.url?.path, "/session/ses_worktree/prompt_async")
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/repo/worktree")
            posts += 1
            return (204, "")
        }
        let accepted = await model.chatFacade.sendMessage("canonical worktree", in: worktree, userVisible: true,
            messageID: "msg_worktree", partID: "part_worktree", meterPrompt: false)
        XCTAssertTrue(accepted)
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "canonical", messageID: "msg_worktree",
            sessionID: worktree.id, partID: "part_worktree")
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: worktree.directory, event: .messageUpdated(canonical.info)))
        XCTAssertEqual(model.chatStore.canonicalSubmissionSessions[canonical.id], worktree.id)
        XCTAssertNotNil(model.chatStore.submissionRecoveries[canonical.id], "The header still needs its canonical part")
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: worktree.directory, event: .messagePartUpdated(canonical.parts[0])))
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: worktree.directory,
            event: .messagePartDelta(sessionID: worktree.id, messageID: canonical.id, partID: "part_worktree", field: "text", delta: " worktree")))
        model.chatFacade.flushBufferedTranscript(reason: "worktree regression")
        await Task.yield()
        XCTAssertNil(model.chatStore.submissionRecoveries[canonical.id])
        XCTAssertEqual(root.syncState.messageEnvelopes(forSessionID: worktree.id).first?.parts.first?.text, "canonical worktree")
        XCTAssertEqual(model.chatFacade.presentationMessages.first?.parts.first?.text, "canonical worktree")
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/foreign",
            event: .messagePartDelta(sessionID: worktree.id, messageID: canonical.id, partID: "part_worktree", field: "text", delta: " BAD")))
        model.chatFacade.flushBufferedTranscript(reason: "foreign scope regression")
        XCTAssertEqual(root.syncState.messageEnvelopes(forSessionID: worktree.id).first?.parts.first?.text, "canonical worktree")
        XCTAssertEqual(posts, 1)
    }

    func testLegacySuccessfulReceiptAndSeparateHeaderPartsNeverLoseDisplayableRow() async throws {
        for inWindow in [false, true] {
            for order in ["receipt-first", "header-first", "parts-first", "usable-parts-first"] {
                let model = model()
                let owner = model.directoryStore
                let facade = inWindow ? ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model,
                    connection: model.backendConnection!, session: session, owner: owner)) : model.chatFacade
                defer { facade.windowContext?.close() }
                let id = "msg_gap"
                let local = OpenCodeMessageEnvelope.local(role: "user", text: "Server text plus local suffix",
                    messageID: id, sessionID: session.id, partID: "part_gap")
                model.chatStore.stageSubmissionPresentation(local, sessionID: session.id, canonical: [], attachments: [], agentMentions: [])
                let posted = expectation(description: "POST held \(order) \(inWindow)")
                var release: CheckedContinuation<Void, Never>?
                var posts = 0
                LegacyRecoveryURLProtocol.handler = { request in
                    XCTAssertEqual(request.url?.path, "/session/ses_legacy/prompt_async")
                    XCTAssertEqual(request.httpMethod, "POST")
                    posts += 1
                    await withCheckedContinuation { release = $0; posted.fulfill() }
                    return (204, "")
                }
                let send = Task { await facade.sendMessage(local.parts.first!.text!, in: session, userVisible: true,
                    messageID: id, partID: "part_gap", appendOptimisticMessage: false, meterPrompt: false) }
                await fulfillment(of: [posted], timeout: 3)
                func snapshot(_ step: String, canonicalText: String? = nil) {
                    let canonical = owner.syncState.messageEnvelopes(forSessionID: session.id)
                    let projected = SubmissionTranscriptPresentation.messages(canonical: canonical,
                        recoveries: facade.recoveryInputs(sessionID: session.id))
                    let visible = projected.filter { MessageBubbleMessageVisibilityPolicy.shouldDisplay($0,
                        showsToolCalls: true, showsReasoningBlocks: true) }
                    XCTAssertEqual(visible.map(\.id), [id], "\(order) window=\(inWindow) \(step)")
                    XCTAssertEqual(visible.first?.parts.first?.text, canonicalText ?? local.parts.first?.text, step)
                    XCTAssertTrue(ChatThinkingPresentation.shouldShow(messages: projected, pendingMessageID: id,
                        isBusy: true, showsToolCalls: true, showsReasoningBlocks: true, runningToolName: nil), step)
                    XCTAssertFalse(canonical.flatMap(\.parts).contains { $0.text == local.parts.first?.text }, step)
                    XCTAssertFalse(model.chatStore.messages.flatMap(\.parts).contains { $0.text == local.parts.first?.text }, step)
                }
                func event(_ body: String) async throws {
                    let envelope = try JSONDecoder().decode(OpenCodeEventEnvelope.self, from: Data(body.utf8))
                    model.handleManagedEvent(.init(directory: "/repo", envelope: envelope,
                        typed: try XCTUnwrap(OpenCodeTypedEvent(envelope: envelope))))
                    await Task.yield()
                }
                let header = #"{"type":"message.updated","properties":{"info":{"id":"msg_gap","role":"user","sessionID":"ses_legacy","time":{"created":1}}}}"#
                let empty = #"{"type":"message.part.updated","properties":{"part":{"id":"part_gap","messageID":"msg_gap","sessionID":"ses_legacy","type":"text","text":""}}}"#
                let usable = #"{"type":"message.part.updated","properties":{"part":{"id":"part_gap","messageID":"msg_gap","sessionID":"ses_legacy","type":"text","text":"Server text"}}}"#
                snapshot("began")
                if order == "receipt-first" {
                    release?.resume(); release = nil
                    let accepted = await send.value
                    XCTAssertTrue(accepted)
                    model.chatStore.discardStagedSubmissionPresentation(messageID: id)
                    snapshot("HTTP accepted")
                }
                if order == "parts-first" { try await event(empty); snapshot("part before header") }
                if order == "usable-parts-first" { try await event(usable); snapshot("usable part before user header") }
                try await event(header)
                XCTAssertEqual(model.chatStore.promptAdmissions[id]?.phase, .admitted)
                XCTAssertEqual(model.chatStore.canonicalSubmissionSessions[id], session.id)
                let textAfterHeader = order == "usable-parts-first" ? "Server text" : nil
                snapshot("header only", canonicalText: textAfterHeader)
                try await event(empty)
                snapshot("empty part", canonicalText: textAfterHeader)
                if let release {
                    release.resume()
                    let accepted = await send.value
                    XCTAssertTrue(accepted)
                    model.chatStore.discardStagedSubmissionPresentation(messageID: id)
                    snapshot("late HTTP accepted", canonicalText: textAfterHeader)
                }
                try await event(usable)
                snapshot("usable shorter canonical", canonicalText: "Server text")
                XCTAssertTrue(facade.recoveryInputs(sessionID: session.id).isEmpty)
                XCTAssertEqual(posts, 1)
            }
        }
    }

    func testLegacyLiveTextDoesNotDropAttachmentAndCommittedHTTPInventoryCanOmitIt() async throws {
        for inWindow in [false, true] {
            for serverOmitsFile in [false, true] {
                let model = model()
                let owner = model.directoryStore
                let facade = inWindow ? ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model,
                    connection: model.backendConnection!, session: session, owner: owner)) : model.chatFacade
                defer { facade.windowContext?.close() }
                let attachment = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
                LegacyRecoveryURLProtocol.handler = { request in
                    if request.httpMethod == "POST" { return (204, "") }
                    return (200, #"[{"info":{"id":"msg_files","role":"user","sessionID":"ses_legacy"},"parts":[{"id":"text","messageID":"msg_files","sessionID":"ses_legacy","type":"text","text":"Short"}]}]"#)
                }
                let accepted = await facade.sendMessage("Short plus local suffix", attachments: [attachment], in: session,
                    userVisible: true, messageID: "msg_files", meterPrompt: false)
                XCTAssertTrue(accepted)
                let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Short", attachments: [attachment],
                    messageID: "msg_files", sessionID: session.id, partID: "text")
                model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messageUpdated(canonical.info)))
                model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messagePartUpdated(canonical.parts[0])))
                await Task.yield()
                let projected = SubmissionTranscriptPresentation.messages(canonical: owner.syncState.messageEnvelopes(forSessionID: session.id),
                    recoveries: facade.recoveryInputs(sessionID: session.id))
                XCTAssertEqual(projected.first?.parts.filter { $0.type == "file" }.count, 1)
                XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).first?.parts.count, 1)
                XCTAssertEqual(model.chatStore.submissionRecoveries[canonical.id]?.phase, .admitted)
                if serverOmitsFile {
                    try await model.loadMessages(for: session, prefetchToolDetails: false, refreshTodos: false,
                        presentationIndependent: inWindow, canonicalOwner: owner)
                } else {
                    model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messagePartUpdated(canonical.parts[1])))
                }
                await Task.yield()
                XCTAssertNil(model.chatStore.submissionRecoveries[canonical.id])
                let committed = owner.syncState.messageEnvelopes(forSessionID: session.id)
                XCTAssertEqual(committed.first?.parts.first?.text, "Short")
                XCTAssertEqual(committed.first?.parts.filter { $0.type == "file" }.count, serverOmitsFile ? 0 : 1)
                XCTAssertEqual(facade.presentationMessages, committed)
            }
        }
    }

    func testRejectedScopeAndWrongIdentityCannotAdmitOrRetireAndRemovalCannotResurrectBridge() throws {
        let model = model()
        let connectionID = try XCTUnwrap(model.backendConnection?.id)
        let request = BackendSubmission(sessionID: session.id, messageID: "msg_scope", text: "Keep", scope: .init(directory: "/repo"))
        XCTAssertTrue(model.chatStore.beginPromptAdmission(request, connectionID: connectionID))
        let canonical = OpenCodeMessageEnvelope.local(role: "user", text: "Keep", messageID: request.messageID, sessionID: session.id)
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/foreign", event: .messageUpdated(canonical.info)))
        XCTAssertNil(model.chatStore.canonicalSubmissionSessions[request.messageID])
        XCTAssertEqual(model.chatStore.promptAdmissions[request.messageID]?.phase, .submitting)
        XCTAssertTrue(model.directoryStore.syncState.messageEnvelopes(forSessionID: session.id).isEmpty)
        for wrong in [OpenCodeMessageEnvelope.local(role: "assistant", text: "", messageID: request.messageID, sessionID: session.id),
                      OpenCodeMessageEnvelope.local(role: "user", text: "", messageID: request.messageID, sessionID: "other")] {
            model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messageUpdated(wrong.info)))
            XCTAssertNil(model.chatStore.canonicalSubmissionSessions[request.messageID])
            XCTAssertEqual(model.chatStore.submissionRecoveries[request.messageID]?.phase, .submitting)
        }
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messageUpdated(canonical.info)))
        XCTAssertEqual(model.chatStore.submissionRecoveries[request.messageID]?.phase, .admitted)
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messageRemoved(sessionID: session.id, messageID: request.messageID)))
        model.chatStore.discardStagedSubmissionPresentation(messageID: request.messageID)
        XCTAssertTrue(model.chatStore.recoveryInputs(sessionID: session.id).isEmpty)
        XCTAssertTrue(SubmissionTranscriptPresentation.messages(canonical: [], recoveries: model.chatStore.recoveryInputs(sessionID: session.id)).isEmpty)
    }

    func testLegacyHeaderCannotConfirmRecoveryOwnedByV2Profile() throws {
        let model = model()
        let factory = OpenCodeBackendFactory(client: .init(config: model.config), eventManager: model.eventManager)
        model.backendConnection = factory.makeConnection(profile: .v2, version: "test", healthy: true)
        model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true)
        let local = OpenCodeMessageEnvelope.local(role: "user", text: "V2 input", messageID: "msg_profile", sessionID: session.id)
        XCTAssertTrue(model.chatStore.beginV2Prompt(local, sessionID: session.id))
        model.handleManagedEvent(try BackendMutationBridge.managed(directory: "/repo", event: .messageUpdated(local.info)))
        XCTAssertNil(model.chatStore.canonicalSubmissionSessions[local.id])
        XCTAssertEqual(model.chatStore.submissionRecoveries[local.id]?.phase, .submitting)
    }

    func testLegacyAdapterLostReceiptAndCanonicalReloadDoNotLeaveAnOrdinaryTailBubble() async throws {
        for inWindow in [false, true] {
            let model = model()
            let owner = model.directoryStore
            let facade = inWindow ? ChatFacade(viewModel: model, windowContext: ChatWindowContext(model: model,
                connection: model.backendConnection!, session: session, owner: owner)) : model.chatFacade
            defer { facade.windowContext?.close() }
            let id = "msg_original"
            let posted = expectation(description: "Legacy POST suspended")
            var release: CheckedContinuation<Void, Never>?
            var posts = 0
            LegacyRecoveryURLProtocol.handler = { request in
                XCTAssertFalse(request.url!.path.hasPrefix("/api/"))
                if request.httpMethod == "POST" {
                    posts += 1
                    XCTAssertEqual(request.url!.path, "/session/ses_legacy/prompt_async")
                    XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/repo")
                    await withCheckedContinuation { release = $0; posted.fulfill() }
                    return (408, "{}")
                }
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.url!.path, "/session/ses_legacy/message")
                return (200, Self.canonicalPage)
            }
            if inWindow {
                _ = facade.insertOptimisticUserMessage("Keep my original text", in: session, messageID: id, animated: false)
            }
            let send = Task { await facade.sendMessage("Keep my original text", in: session, userVisible: true,
                messageID: id, meterPrompt: false) }
            await fulfillment(of: [posted], timeout: 3)
            facade.composerStore.draftMessage = "Newer draft must remain"
            release?.resume()
            let accepted = await send.value
            XCTAssertFalse(accepted)
            XCTAssertEqual(model.chatStore.promptAdmissions[id]?.phase, .uncertain)
            let other = OpenCodeMessage(id: "msg_new_user", role: "user", sessionID: session.id,
                time: .init(created: 100), agent: nil, model: nil)
            let answer = OpenCodeMessage(id: "msg_new_answer", role: "assistant", sessionID: session.id,
                time: .init(created: 101), agent: nil, model: nil)
            model.handleBackendEvent(.mutation(directory: "/repo", event: .messageUpdated(other)))
            model.handleBackendEvent(.mutation(directory: "/repo", event: .messageUpdated(answer)))
            try await model.loadMessages(for: session, prefetchToolDetails: false, refreshTodos: false,
                presentationIndependent: inWindow, canonicalOwner: owner)
            XCTAssertEqual(posts, 1)
            XCTAssertEqual(facade.composerStore.draftMessage, "Newer draft must remain")
            XCTAssertEqual(facade.presentationMessages.map(\.id), ["msg_new_user", "msg_new_answer"])
            XCTAssertEqual(owner.syncState.messageEnvelopes(forSessionID: session.id).map(\.id), ["msg_new_user", "msg_new_answer"])
            XCTAssertEqual(model.chatStore.promptAdmissions[id]?.text, "Keep my original text")
            XCTAssertEqual(facade.recoveryInputs(sessionID: session.id).map(\.id), [id])
            XCTAssertEqual(facade.recoveryInputs(sessionID: session.id).first?.text, "Keep my original text")
        }
    }

    func testLegacyTransportCancellationRetainsAttachmentsMentionsAndUsesOnlyLegacyReadsForRecovery() async throws {
        let model = model()
        let file = OpenCodeComposerAttachment(id: "file", kind: .file, filename: "keep.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
        let mention = OpenCodeAgentMention(name: "build", content: "@build", start: 0, end: 6)
        var methods: [String] = []
        LegacyRecoveryURLProtocol.handler = { request in
            methods.append(request.httpMethod!)
            XCTAssertFalse(request.url!.path.hasPrefix("/api/"))
            if request.httpMethod == "POST" { throw URLError(.cancelled) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "x-opencode-directory"), "/repo")
            if request.url!.path.hasSuffix("/message/msg_original") { return (404, "{}") }
            XCTAssertEqual(request.url!.path, "/session/ses_legacy/message")
            return (200, Self.canonicalPage)
        }
        let accepted = await model.chatFacade.sendMessage("@build keep", agentMentions: [mention], attachments: [file],
            in: session, userVisible: true, messageID: "msg_original", meterPrompt: false)
        XCTAssertFalse(accepted)
        await model.chatFacade.checkRecoveryStatus(messageID: "msg_original", sessionID: session.id)
        let recovery = try XCTUnwrap(model.chatFacade.recoveryInputs(sessionID: session.id).first)
        XCTAssertEqual(recovery.phase, .uncertain)
        XCTAssertEqual(recovery.attachments, [file])
        XCTAssertEqual(recovery.agentMentions, [mention])
        XCTAssertEqual(recovery.id, "msg_original")
        XCTAssertEqual(methods, ["POST", "GET", "GET"])
        let retried = await model.chatFacade.sendMessage("Changed text", in: session, userVisible: true,
            messageID: "msg_retry", meterPrompt: false)
        XCTAssertFalse(retried)
        XCTAssertEqual(methods, ["POST", "GET", "GET"])
    }

    func testSameOwnerReconnectRestoresRecoveryAndForeignServerOrProfileCannotSeeIt() throws {
        let model = model()
        let oldConnection = try XCTUnwrap(model.backendConnection)
        let request = BackendSubmission(sessionID: session.id, messageID: "msg_collision", text: "Owner A",
            scope: .init(directory: "/repo"))
        XCTAssertTrue(model.chatStore.beginPromptAdmission(request, connectionID: oldConnection.id))
        model.chatStore.applyPromptAdmission(.uncertain, messageID: request.messageID, connectionID: oldConnection.id)
        model.disconnect()
        let foreign = self.model(host: "foreign-recovery.invalid")
        model.config = foreign.config
        model.backendConnection = foreign.backendConnection
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        XCTAssertTrue(model.chatStore.beginPromptAdmission(.init(sessionID: session.id, messageID: request.messageID,
            text: "Owner B", scope: .init(directory: "/repo")), connectionID: model.backendConnection!.id))
        model.disconnect()
        let restored = self.model()
        model.config = restored.config
        model.backendConnection = restored.backendConnection
        model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
        model.directoryStoreRegistry.activate("/repo")
        model.directoryStore.insertV2Session(session)
        _ = model.beginSessionNavigation(session)
        XCTAssertEqual(model.chatFacade.recoveryInputs(sessionID: session.id).first?.text, "Owner A")
        XCTAssertTrue(model.chatFacade.hasPendingPromptAdmission(sessionID: session.id))
        model.disconnect()
        let v2 = OpenCodeBackendFactory(client: .init(config: model.config), eventManager: model.eventManager)
            .makeConnection(profile: .v2, version: "0.0.0-next-17155", healthy: true)
        model.backendConnection = v2
        model.connectionStore.applySuccessfulV2Connection(version: "0.0.0-next-17155", healthy: true)
        XCTAssertTrue(model.chatStore.submissionRecoveries.isEmpty)
        XCTAssertTrue(model.chatStore.canonicalSubmissionSessions.isEmpty)
    }

    func testCanonicalLegacyEventRetiresOnlyExactRecoveryAndKeepsNewDraftAndUnrelatedError() throws {
        let model = model()
        let connection = try XCTUnwrap(model.backendConnection)
        let request = BackendSubmission(sessionID: session.id, messageID: "msg_original", text: "Keep", scope: .init(directory: "/repo"))
        XCTAssertTrue(model.chatStore.beginPromptAdmission(request, connectionID: connection.id))
        model.chatStore.applyPromptAdmission(.uncertain, messageID: request.messageID, connectionID: connection.id)
        model.composerStore.draftMessage = "New draft"
        model.connectionStore.applyPromptError("Same warning", connectionID: connection.id, sessionID: session.id, messageID: request.messageID)
        model.errorMessage = "Same warning"
        let wrong = OpenCodeMessage(id: "msg_other", role: "user", sessionID: session.id, time: .init(created: 1), agent: nil, model: nil)
        model.handleBackendEvent(.mutation(directory: "/repo", event: .messageUpdated(wrong)))
        XCTAssertEqual(model.chatStore.submissionRecoveries[request.messageID]?.phase, .uncertain)
        let canonical = OpenCodeMessage(id: request.messageID, role: "user", sessionID: session.id, time: .init(created: 2), agent: nil, model: nil)
        model.handleBackendEvent(.mutation(directory: "/repo", event: .messageUpdated(canonical)))
        XCTAssertEqual(model.chatStore.submissionRecoveries[request.messageID]?.phase, .admitted)
        let bridge = try XCTUnwrap(model.chatStore.submissionRecoveries[request.messageID])
        XCTAssertFalse(SubmissionTranscriptPresentation.showsStatus(input: bridge, now: bridge.submittedAt.addingTimeInterval(100)))
        let projected = SubmissionTranscriptPresentation.messages(canonical: model.chatFacade.presentationMessages, recoveries: [bridge])
        XCTAssertEqual(projected.first(where: { $0.id == request.messageID })?.parts.first?.text, "Keep")
        XCTAssertTrue(model.chatFacade.isPromptAdmitted(messageID: request.messageID, sessionID: session.id))
        XCTAssertEqual(model.chatFacade.presentationMessages.map(\.id), [wrong.id, canonical.id])
        XCTAssertEqual(model.chatStore.applyPromptAdmission(.rejected, messageID: request.messageID, connectionID: connection.id), .admitted)
        XCTAssertEqual(model.composerStore.draftMessage, "New draft")
        XCTAssertEqual(model.errorMessage, "Same warning")
    }

    func testLateLegacyExactReadCannotConfirmForeignCollidingRecovery() async throws {
        let model = model()
        let request = BackendSubmission(sessionID: session.id, messageID: "msg_original", text: "Owner A", scope: .init(directory: "/repo"))
        XCTAssertTrue(model.chatStore.beginPromptAdmission(request, connectionID: model.backendConnection!.id))
        model.chatStore.applyPromptAdmission(.uncertain, messageID: request.messageID, connectionID: model.backendConnection!.id)
        LegacyRecoveryURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url!.path, "/session/ses_legacy/message/msg_original")
            model.disconnect()
            let foreign = self.model(host: "foreign-recovery.invalid")
            model.config = foreign.config
            model.backendConnection = foreign.backendConnection
            model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true)
            XCTAssertTrue(model.chatStore.beginPromptAdmission(.init(sessionID: self.session.id, messageID: "msg_original",
                text: "Owner B", scope: .init(directory: "/repo")), connectionID: model.backendConnection!.id))
            return (200, #"{"info":{"id":"msg_original","sessionID":"ses_legacy","role":"user","time":{"created":1}},"parts":[]}"#)
        }
        await model.chatFacade.checkRecoveryStatus(messageID: request.messageID, sessionID: session.id)
        XCTAssertEqual(model.chatStore.submissionRecoveries[request.messageID]?.text, "Owner B")
        XCTAssertEqual(model.chatStore.submissionRecoveries[request.messageID]?.phase, .submitting)
    }

    func testLegacyCanonicalPageReplacesOldLocalPayloadInsteadOfPreservingItsLongerPrefix() async throws {
        let model = model()
        let request = BackendSubmission(sessionID: session.id, messageID: "msg_original", text: "Server text plus local suffix",
            scope: .init(directory: "/repo"))
        XCTAssertTrue(model.chatStore.beginPromptAdmission(request, connectionID: model.backendConnection!.id))
        let oldOverlay = OpenCodeMessageEnvelope.local(role: "user", text: request.text, messageID: request.messageID,
            sessionID: session.id, partID: "part_original")
        model.chatStore.messages = [oldOverlay]
        model.chatStore.cachedMessagesBySessionID[session.id] = [oldOverlay]
        model.directoryStore.appendMessage(oldOverlay, forSessionID: session.id)
        LegacyRecoveryURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url!.path, "/session/ses_legacy/message")
            return (200, #"[{"info":{"id":"msg_original","sessionID":"ses_legacy","role":"user","time":{"created":1}},"parts":[{"id":"part_original","messageID":"msg_original","sessionID":"ses_legacy","type":"text","text":"Server text"}]}]"#)
        }
        try await model.loadMessages(for: session, prefetchToolDetails: false, refreshTodos: false)
        XCTAssertEqual(model.chatStore.messages.first?.parts.first?.text, "Server text")
        XCTAssertEqual(model.directoryStore.syncState.messageEnvelopes(forSessionID: session.id).first?.parts.first?.text, "Server text")
        XCTAssertTrue(model.chatFacade.recoveryInputs(sessionID: session.id).isEmpty)
        XCTAssertTrue(model.chatFacade.isPromptAdmitted(messageID: request.messageID, sessionID: session.id))
    }

    func testLegacyOlderPageDoesNotReintroduceUnconfirmedOverlay() async throws {
        let model = model()
        let request = BackendSubmission(sessionID: session.id, messageID: "msg_original", text: "Keep me",
            scope: .init(directory: "/repo"))
        XCTAssertTrue(model.chatStore.beginPromptAdmission(request, connectionID: model.backendConnection!.id))
        model.chatStore.applyPromptAdmission(.uncertain, messageID: request.messageID, connectionID: model.backendConnection!.id)
        let oldOverlay = OpenCodeMessageEnvelope.local(role: "user", text: request.text, messageID: request.messageID, sessionID: session.id)
        model.directoryStore.appendMessage(oldOverlay, forSessionID: session.id)
        model.chatStore.applyMessageHistoryPage(nextCursor: "older", forSessionID: session.id)
        LegacyRecoveryURLProtocol.handler = { request in
            XCTAssertEqual(request.httpMethod, "GET")
            XCTAssertEqual(request.url!.path, "/session/ses_legacy/message")
            XCTAssertTrue(request.url!.query!.contains("before=older"))
            return (200, Self.canonicalPage)
        }
        _ = await model.loadOlderMessages(for: session, count: 20)
        XCTAssertEqual(model.chatFacade.presentationMessages.map(\.id), ["msg_new_user", "msg_new_answer"])
        XCTAssertEqual(model.chatFacade.recoveryInputs(sessionID: session.id).first?.text, "Keep me")
    }

    private static let canonicalPage = #"[{"info":{"id":"msg_new_user","sessionID":"ses_legacy","role":"user","time":{"created":100}},"parts":[]},{"info":{"id":"msg_new_answer","sessionID":"ses_legacy","role":"assistant","time":{"created":101}},"parts":[]}]"#
}

private final class LegacyRecoveryURLProtocol: URLProtocol {
    @MainActor static var handler: (@MainActor (URLRequest) async throws -> (Int, String))?
    private struct Delivery: @unchecked Sendable { let loader: LegacyRecoveryURLProtocol }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delivery = Delivery(loader: self)
        let request = request
        Task { @MainActor in
            do {
                let handler = try XCTUnwrap(Self.handler)
                let (status, body) = try await handler(request)
                let response = try XCTUnwrap(HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil,
                    headerFields: ["Content-Type": "application/json"]))
                delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
                delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
                delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
            } catch { delivery.loader.client?.urlProtocol(delivery.loader, didFailWithError: error) }
        }
    }
    override func stopLoading() {}
}
