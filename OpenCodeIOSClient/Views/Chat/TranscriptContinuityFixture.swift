#if DEBUG && canImport(UIKit)
import SwiftUI
import UIKit

@MainActor
enum TranscriptContinuityDiagnostics {
    static var enabled: Bool { ProcessInfo.processInfo.environment["OPENCLIENT_TRANSCRIPT_CONTINUITY"] == "1" }
    static var starts: [String: Int] = [:]
    static var progress: [Double] = []
    static var updates: [String] = []
    static var gated: Bool { ProcessInfo.processInfo.environment["OPENCLIENT_MATERIALIZATION_GATES"] == "1" }
    static var toolGated: Bool { ProcessInfo.processInfo.environment["OPENCLIENT_THINKING_TOOLS"] == "1" }
    static var outgoingID: String?
    static var outgoingRemovals = 0
    static var sampleRows: (() -> [[String: String]])?
    static var rowTrace: [[[String: String]]] = []
    static var thinkingProgress: [Double] = []
    static var thinkingEvents: [String] = []
    static var entryCompletedAt: [String: Double] = [:]
    static var thinkingFrameTimes: [Double] = []
    static var thinkingVisible = false
    static var thinkingDuringOutgoingMotion = false
    static var outgoingFrameRows: [[[String: String]]] = []
    static var postedAt: Double?
    static var whenEntryStarted: ((String) -> Void)?
    static var earlyResponse: String? { ProcessInfo.processInfo.environment["OPENCLIENT_THINKING_EARLY_RESPONSE"] }
    static var earlyCanonicalAt: Double?
    static var entryStartedAt: [String: Double] = [:]
    static var reducesMotion: Bool { ProcessInfo.processInfo.environment["OPENCLIENT_THINKING_REDUCE_MOTION"] == "1" }

    static func entryCompleted(_ id: String, reduced: Bool) {
        guard enabled else { return }
        entryCompletedAt[id] = Date().timeIntervalSinceReferenceDate
    }

    static func thinkingFrame(_ progress: Double) {
        guard enabled, thinkingProgress.count < 180 else { return }
        thinkingProgress.append(progress)
        thinkingFrameTimes.append(Date().timeIntervalSinceReferenceDate)
    }

    static func started(_ id: String) {
        guard enabled else { return }
        starts[id, default: 0] += 1
        entryStartedAt[id] = Date().timeIntervalSinceReferenceDate
        whenEntryStarted?(id)
    }

    static func frame(_ progress: CGFloat) {
        guard enabled, Self.progress.count < 180 else { return }
        Self.progress.append(Double(progress))
        if progress < 1, thinkingVisible { thinkingDuringOutgoingMotion = true }
        if gated { outgoingFrameRows.append(sampleRows?() ?? []) }
    }
}

/// A private URLSession intercepts every request. This fixture never contacts a server.
private final class TranscriptContinuityURLProtocol: URLProtocol {
    @MainActor static var posts = 0
    @MainActor static var release: CheckedContinuation<Void, Never>?
    @MainActor static var whenPosted: (() -> Void)?
    private struct Delivery: @unchecked Sendable { let loader: TranscriptContinuityURLProtocol }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let delivery = Delivery(loader: self)
        let request = request
        Task { @MainActor in
            let isSubmission = request.httpMethod == "POST"
                && ["prompt", "prompt_async", "message", "command"].contains(request.url?.lastPathComponent ?? "")
            if isSubmission {
                Self.posts += 1
                TranscriptContinuityDiagnostics.postedAt = Date().timeIntervalSinceReferenceDate
                Self.whenPosted?()
                Self.whenPosted = nil
                await withCheckedContinuation { Self.release = $0 }
            }
            let success = TranscriptContinuityDiagnostics.gated && isSubmission
            let body = success ? "{\"data\":{\"id\":\"\(TranscriptContinuityDiagnostics.outgoingID ?? "")\",\"sessionID\":\"continuity\",\"timeCreated\":1,\"delivery\":\"queued\"}}"
                : (isSubmission ? "{}" : (request.httpMethod == "POST" ? "" : "[]"))
            guard let url = request.url,
                  let response = HTTPURLResponse(url: url, statusCode: success ? 200 : (isSubmission ? 408 : (request.httpMethod == "POST" ? 204 : 200)),
                    httpVersion: nil, headerFields: ["Content-Type": "application/json"]) else { return }
            delivery.loader.client?.urlProtocol(delivery.loader, didReceive: response, cacheStoragePolicy: .notAllowed)
            // V2's POST /wait is a read-side completion wait, not another submission.
            delivery.loader.client?.urlProtocol(delivery.loader, didLoad: Data(body.utf8))
            delivery.loader.client?.urlProtocolDidFinishLoading(delivery.loader)
        }
    }
    override func stopLoading() {}
}

struct TranscriptContinuityFixture: View {
    @State private var model: AppViewModel
    @State private var facade: ChatFacade
    @State private var canonical: [OpenCodeMessageEnvelope]
    @State private var confirmedID: String?
    @State private var streaming = false
    @State private var ended = false
    @State private var gate = 0
    private let session: OpenCodeSession
    private var fixtureAttachment: OpenCodeComposerAttachment {
        OpenCodeComposerAttachment(id: "fixture-file", kind: .file, filename: "note.txt", mime: "text/plain", dataURL: "data:text/plain;base64,aGk=")
    }

    init() {
        // Each fixture uses a fresh app process. View.init can repeat without remounting its state.
        let profile: OpenCodeAPIProfile = ProcessInfo.processInfo.environment["OPENCLIENT_RECOVERY_PROFILE"] == "legacy" ? .legacy : .v2
        let model = AppViewModel()
        model.config = .init(baseURL: "https://transcript-continuity.invalid", apiPreference: profile == .legacy ? .legacy : .v2)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TranscriptContinuityURLProtocol.self]
        let adapter = OpenCodeBackendAdapter(client: .init(config: model.config, session: URLSession(configuration: configuration)), profile: profile)
        let connection = BackendConnection(descriptor: .init(id: "continuity", name: "Continuity", version: "1"),
            capabilities: [.interactions], projects: adapter, sessions: adapter, chat: adapter, models: adapter,
            events: OpenCodeBackendEventSource(client: adapter.client, profile: profile, manager: model.eventManager))
        model.backendConnection = connection
        if profile == .legacy { model.connectionStore.applySuccessfulServerConnection(version: "1", healthy: true) }
        else { model.connectionStore.applySuccessfulV2Connection(version: "test", healthy: true) }
        model.localCacheRepository = NoOpOpenCodeLocalCacheRepository()
        model.commerceFacade.debugEntitlementOverride = .unlocked
        let splitOwner = ProcessInfo.processInfo.environment["OPENCLIENT_MATERIALIZATION_SPLIT_OWNER"] == "1"
        model.directoryStoreRegistry.activate(splitOwner ? nil : "/continuity")
        let session = OpenCodeSession(id: "continuity", title: "Continuity", workspaceID: nil, directory: "/continuity", projectID: "project", parentID: nil)
        model.directoryStore.insertV2Session(session)
        if !splitOwner { _ = model.beginSessionNavigation(session) }
        let history = ChatKeyboardFrameProbe.enabled
            ? (0..<40).map { OpenCodeMessageEnvelope.local(role: "user", text: "Keyboard history row \($0)\nLine two\nLine three\nLine four", messageID: "history-\($0)", sessionID: session.id) }
            : [OpenCodeMessageEnvelope.local(role: "user", text: "Continuity history", messageID: "history", sessionID: session.id)]
        model.chatStore.beginSelectingSession(sessionID: session.id, cachedMessages: history)
        model.chatStore.applyCanonicalMessages(history, forSessionID: session.id, isActiveSession: true)
        model.directoryStore.applyV2Messages(history, forSessionID: session.id)
        model.chatStore.finishLoadingSelectedSession()
        model.directoryStore.applySessionStatus("idle", forSessionID: session.id)
        let historical = OpenCodeMessageEnvelope.local(role: "user", text: "Historical unconfirmed input", messageID: "historical-recovery", sessionID: session.id)
        if !TranscriptContinuityDiagnostics.toolGated, TranscriptContinuityDiagnostics.earlyResponse == nil {
            model.chatStore.stageSubmissionPresentation(historical, sessionID: session.id, canonical: [], attachments: [], agentMentions: [])
        }
        let context = ProcessInfo.processInfo.environment["OPENCLIENT_RECOVERY_WINDOW"] == "1"
            ? ChatWindowContext(model: model, connection: connection, session: session, owner: model.directoryStore) : nil
        self.session = session
        _model = State(initialValue: model)
        let facade = context.map { ChatFacade(viewModel: model, windowContext: $0) } ?? model.chatFacade
        if splitOwner {
            // The window keeps the global-list owner it captured before root navigation creates the directory owner.
            _ = model.beginSessionNavigation(session)
            model.directoryStore.applyV2Messages(history, forSessionID: session.id)
            model.chatStore.applyInitialV2Transcript(history, olderCursor: nil, sessionID: session.id)
        }
        _facade = State(initialValue: facade)
        _canonical = State(initialValue: history)
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if ChatKeyboardFrameProbe.enabled {
                    Button { ChatKeyboardFrameProbe.frames = [] } label: { Text(verbatim: "Record") }
                        .accessibilityIdentifier("continuity.keyboard.record")
                    Button { UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil) }
                        label: { Text(verbatim: "Hide keyboard") }
                        .accessibilityIdentifier("continuity.keyboard.hide")
                } else if TranscriptContinuityDiagnostics.toolGated {
                    Button { startTool() } label: { Text(verbatim: "Tool") }
                        .accessibilityIdentifier("continuity.tool")
                    Button { model.appCustomizationStore.setShowsToolCalls(!model.appCustomizationStore.showsToolCalls) } label: { Text(verbatim: "Tools") }
                        .accessibilityIdentifier("continuity.tools")
                    Button { model.appCustomizationStore.setShowsReasoningBlocks(!model.appCustomizationStore.showsReasoningBlocks) } label: { Text(verbatim: "Reasoning") }
                        .accessibilityIdentifier("continuity.reasoning")
                    Button { addContent(type: "reasoning") } label: { Text(verbatim: "Reason") }
                        .accessibilityIdentifier("continuity.addReasoning")
                    Button { addContent(type: "text") } label: { Text(verbatim: "Text") }
                        .accessibilityIdentifier("continuity.addText")
                } else if TranscriptContinuityDiagnostics.gated {
                    Button { advanceGate() } label: { Text(verbatim: "Advance fixture") }
                        .accessibilityIdentifier("continuity.advance")
                } else {
                    Button { finish() } label: { Text(verbatim: "Finish fixture") }
                        .accessibilityIdentifier("continuity.finish")
                }
            }
            TimelineView(.periodic(from: .now, by: 0.1)) { _ in
                if ChatKeyboardFrameProbe.enabled {
                    Text(verbatim: "Keyboard frames")
                        .font(.system(size: 10, design: .monospaced))
                        .accessibilityIdentifier("continuity.keyboard.frames")
                        .accessibilityValue(Text(verbatim: String(data: (try? JSONSerialization.data(withJSONObject: ChatKeyboardFrameProbe.frames)) ?? Data(), encoding: .utf8) ?? "[]"))
                }
                let progress = TranscriptContinuityDiagnostics.progress
                Text(verbatim: "posts=\(TranscriptContinuityURLProtocol.posts) starts=\(TranscriptContinuityDiagnostics.starts.values.reduce(0, +)) historical=\(TranscriptContinuityDiagnostics.starts["historical-recovery", default: 0]) frames=\(progress.count) moving=\(progress.contains { $0 > 0 && $0 < 0.95 }) streaming=\(streaming) ended=\(ended)")
                    .font(.system(size: 10, design: .monospaced))
                    .accessibilityIdentifier("continuity.diagnostics")
                    .accessibilityValue(Text(verbatim: TranscriptContinuityDiagnostics.gated ? gateSnapshot() : "progress=\(progress) updates=\(TranscriptContinuityDiagnostics.updates)"))
            }
            NavigationStack {
                ChatView(chatFacade: facade, browser: facade.windowContext?.browser ?? model.appShellFacade.browser, sessionID: session.id)
            }
        }
        .onReceive(facade.chatStore.$stagedSubmissionPresentations) { values in
            guard confirmedID == nil, let input = values.values.first(where: { $0.id != "historical-recovery" }) else { return }
            confirmedID = input.id
            TranscriptContinuityDiagnostics.outgoingID = input.id
            guard !TranscriptContinuityDiagnostics.gated else { return }
            Task { @MainActor in
                // Exact canonical content arrives during the slide, before the held receipt.
                if TranscriptContinuityURLProtocol.posts == 0 {
                    await withCheckedContinuation { continuation in
                        TranscriptContinuityURLProtocol.whenPosted = { continuation.resume() }
                    }
                }
                let confirmed = OpenCodeMessageEnvelope.local(role: "user", text: "Continuity outgoing",
                    messageID: input.id, sessionID: session.id, partID: "canonical-part")
                canonical.append(confirmed)
                _ = facade.chatStore.confirmCanonicalSubmission(confirmed.info)
                facade.directoryStore(forSessionID: session.id).applyV2Messages(canonical, forSessionID: session.id)
                facade.chatStore.applyCanonicalMessages(canonical, forSessionID: session.id, isActiveSession: true)
                model.finishTranscriptCommit(in: facade.directoryStore(forSessionID: session.id), sessionID: session.id)
                try? await Task.sleep(for: .milliseconds(900))
                guard !ended else { return }
                streaming = true
                canonical.append(.local(role: "assistant", text: "Continuity completed answer\n\n" + String(repeating:
                    "A streamed paragraph preserves the same canonical answer through completion.\n\n", count: 24),
                    messageID: "answer", sessionID: session.id, partID: "answer-part"))
                facade.directoryStore(forSessionID: session.id).applySessionStatus("busy", forSessionID: session.id)
                facade.directoryStore(forSessionID: session.id).applyV2Messages(canonical, forSessionID: session.id)
                facade.chatStore.applyCanonicalMessages(canonical, forSessionID: session.id, isActiveSession: true)
            }
        }
        .onAppear {
            if let earlyResponse = TranscriptContinuityDiagnostics.earlyResponse {
                TranscriptContinuityDiagnostics.whenEntryStarted = { id in
                    Task { @MainActor in
                        let user = OpenCodeMessageEnvelope.local(role: "user", text: "Continuity outgoing",
                            messageID: id, sessionID: session.id, partID: "canonical-part")
                        canonical.append(user)
                        if earlyResponse == "answer" {
                            canonical.append(.local(role: "assistant", text: "Early fixture answer", messageID: "answer", sessionID: session.id))
                        }
                        let owner = facade.directoryStore(forSessionID: session.id)
                        _ = facade.chatStore.confirmCanonicalSubmission(user.info)
                        owner.applySessionStatus("busy", forSessionID: session.id)
                        owner.applyV2Messages(canonical, forSessionID: session.id)
                        facade.chatStore.applyCanonicalMessages(canonical, forSessionID: session.id, isActiveSession: true)
                        model.finishTranscriptCommit(in: owner, sessionID: session.id)
                        TranscriptContinuityDiagnostics.earlyCanonicalAt = Date().timeIntervalSinceReferenceDate
                    }
                }
            }
            if TranscriptContinuityDiagnostics.toolGated {
                model.appCustomizationStore.setShowsToolCalls(true)
                model.appCustomizationStore.setShowsReasoningBlocks(ProcessInfo.processInfo.environment["OPENCLIENT_THINKING_REASONING"] == "1")
            }
            if ProcessInfo.processInfo.environment["OPENCLIENT_MATERIALIZATION_ATTACHMENT"] == "1" {
                facade.addDraftAttachments([fixtureAttachment])
            }
        }
        .onDisappear {
            TranscriptContinuityDiagnostics.whenEntryStarted = nil
            TranscriptContinuityURLProtocol.release?.resume()
            TranscriptContinuityURLProtocol.release = nil
            facade.windowContext?.close()
            model.stopEventStream()
        }
    }

    private func gateSnapshot() -> String {
        let rows = TranscriptContinuityDiagnostics.sampleRows?() ?? []
        if TranscriptContinuityDiagnostics.rowTrace.last != rows, TranscriptContinuityDiagnostics.rowTrace.count < 100 {
            TranscriptContinuityDiagnostics.rowTrace.append(rows)
        }
        let value: [String: Any] = ["gate": gate, "rows": rows, "outgoingID": confirmedID ?? "",
            "removals": TranscriptContinuityDiagnostics.outgoingRemovals,
            "admitted": confirmedID.map { facade.isPromptAdmitted(messageID: $0, sessionID: session.id) } ?? false,
            "bridge": confirmedID.map { facade.chatStore.submissionRecoveries[$0] != nil } ?? false,
            "rootOwner": model.directoryStoreRegistry.key(for: model.directoryStore) ?? "",
            "windowOwner": model.directoryStoreRegistry.key(for: facade.directoryStore(forSessionID: session.id)) ?? "",
            "rootText": model.directoryStore.syncState.messageEnvelopes(forSessionID: session.id).first { $0.id == confirmedID }?.parts.first?.text ?? "",
            "windowText": facade.presentationMessages.first { $0.id == confirmedID }?.parts.first?.text ?? "",
            "trace": TranscriptContinuityDiagnostics.rowTrace, "updates": TranscriptContinuityDiagnostics.updates,
            "thinkingProgress": TranscriptContinuityDiagnostics.thinkingProgress,
            "thinkingEvents": TranscriptContinuityDiagnostics.thinkingEvents,
            "entryCompletedAt": TranscriptContinuityDiagnostics.entryCompletedAt,
            "entryStartedAt": TranscriptContinuityDiagnostics.entryStartedAt,
            "thinkingFrameTimes": TranscriptContinuityDiagnostics.thinkingFrameTimes,
            "thinkingDuringOutgoingMotion": TranscriptContinuityDiagnostics.thinkingDuringOutgoingMotion,
            "outgoingFrameRows": TranscriptContinuityDiagnostics.outgoingFrameRows,
            "postedAt": TranscriptContinuityDiagnostics.postedAt ?? 0,
            "earlyCanonicalAt": TranscriptContinuityDiagnostics.earlyCanonicalAt ?? 0,
            "canonicalIDs": facade.presentationMessages.map(\.id),
            "canonicalParts": facade.presentationMessages.flatMap { $0.parts.map { "\($0.id ?? ""):\($0.type):\($0.text ?? ""):\($0.state?.status ?? "")" } }]
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])).flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    }

    private func startTool() {
        guard let id = confirmedID, !streaming else { return }
        streaming = true
        let user = OpenCodeMessageEnvelope.local(role: "user", text: "Continuity outgoing",
            messageID: id, sessionID: session.id, partID: "canonical-part")
        var assistant = OpenCodeMessageEnvelope.local(role: "assistant", text: "", messageID: "answer", sessionID: session.id)
        assistant.parts = [try! JSONDecoder().decode(OpenCodePart.self, from: Data(#"{"id":"tool","type":"tool","tool":"bash","callID":"fixture-call","state":{"status":"running","input":{"command":"true"},"title":"Fixture tool"}}"#.utf8))]
        canonical += [user, assistant]
        _ = facade.chatStore.confirmCanonicalSubmission(user.info)
        let owner = facade.directoryStore(forSessionID: session.id)
        owner.applySessionStatus("busy", forSessionID: session.id)
        owner.applyV2Messages(canonical, forSessionID: session.id)
        facade.chatStore.applyCanonicalMessages(canonical, forSessionID: session.id, isActiveSession: true)
        model.finishTranscriptCommit(in: owner, sessionID: session.id)
    }

    private func addContent(type: String) {
        guard let index = canonical.firstIndex(where: { $0.id == "answer" }),
              !canonical[index].parts.contains(where: { $0.type == type }) else { return }
        canonical[index].parts.append(try! JSONDecoder().decode(OpenCodePart.self,
            from: Data("{\"id\":\"\(type)\",\"type\":\"\(type)\",\"text\":\"Fixture \(type) content\"}".utf8)))
        facade.directoryStore(forSessionID: session.id).applyV2Messages(canonical, forSessionID: session.id)
        facade.chatStore.applyCanonicalMessages(canonical, forSessionID: session.id, isActiveSession: true)
    }

    private func advanceGate() {
        guard let id = confirmedID else { return }
        let headerFirst = ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_FIRST"] == "1"
        var steps = headerFirst ? ["header", "receipt", "empty", "usable"] : ["receipt", "header", "empty", "usable"]
        if ProcessInfo.processInfo.environment["OPENCLIENT_MATERIALIZATION_ATTACHMENT"] == "1" { steps.append("file") }
        guard gate < steps.count else { return }
        let step = steps[gate]
        if step == "receipt" {
            guard let release = TranscriptContinuityURLProtocol.release else { return }
            TranscriptContinuityURLProtocol.release = nil
            release.resume()
        } else {
            let user = OpenCodeMessageEnvelope.local(role: "user", text: step == "usable" ? "Continuity outgoing" : "",
                attachments: step == "file" ? [fixtureAttachment] : [], messageID: id, sessionID: session.id, partID: "canonical-part")
            if model.connectionStore.apiProfile == .legacy {
                let event: OpenCodeTypedEvent = step == "header" ? .messageUpdated(user.info) : .messagePartUpdated(user.parts[0])
                if let managed = try? BackendMutationBridge.managed(directory: session.directory, event: event) {
                    model.handleManagedEvent(managed)
                }
            } else {
                // V2 reads are complete envelope snapshots, not invented legacy header events.
                let incoming = OpenCodeMessageEnvelope(info: user.info, parts: step == "header" ? [] : user.parts)
                let page = canonical + [incoming]
                facade.chatStore.applyV2EventProjection(page, olderCursor: nil, sessionID: session.id)
                let owner = ProcessInfo.processInfo.environment["OPENCLIENT_MATERIALIZATION_SPLIT_OWNER"] == "1"
                    ? model.directoryStore : facade.directoryStore(forSessionID: session.id)
                owner.applyV2Messages(page, forSessionID: session.id)
                model.finishTranscriptCommit(in: owner, sessionID: session.id, completeInventory: page)
            }
        }
        gate += 1
    }

    private func finish() {
        guard !ended, streaming, let index = canonical.firstIndex(where: { $0.id == "answer" }) else { return }
        ended = true
        streaming = false
        canonical[index].info = OpenCodeMessage(id: "answer", role: "assistant", sessionID: session.id,
            time: .init(created: 1, completed: 2), agent: nil, model: nil)
        facade.directoryStore(forSessionID: session.id).applyV2Messages(canonical, forSessionID: session.id)
        facade.chatStore.applyCanonicalMessages(canonical, forSessionID: session.id, isActiveSession: true)
        facade.directoryStore(forSessionID: session.id).applySessionStatus("idle", forSessionID: session.id)
        TranscriptContinuityURLProtocol.release?.resume()
        TranscriptContinuityURLProtocol.release = nil
    }
}
#endif
