#if DEBUG && os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI

/// Exercises the real composer with a permanently busy session and no transport.
struct StreamingDeliveryFixture: View {
    @StateObject private var draft = MessageComposerDraftStore(text: "Keep this streaming draft")
    @State private var accessoryOpen = false
    @State private var delivery: OpenCodePromptDelivery = .queue
    @State private var submissions: [String] = []
    @Namespace private var glassNamespace

    var body: some View {
        VStack {
            Text(verbatim: "Streaming delivery fixture")
                .accessibilityIdentifier("screenshot.scene.streaming-delivery")
            Text(verbatim: submissions.isEmpty ? "No submissions" : submissions.joined(separator: "|"))
                .accessibilityIdentifier("streaming.fixture.submissions")
                .accessibilityValue(Text(verbatim: String(submissions.count)))
            Spacer()
            MessageComposer(
                draftStore: draft,
                isAccessoryMenuOpen: $accessoryOpen,
                commands: [], mentionableAgents: [], pinnedCommands: [], pinnedCommandNames: [],
                attachmentCount: 0, isBusy: true, canFork: false, forkableMessages: [],
                mcpServers: [], connectedMCPServerCount: 0, isLoadingMCP: false,
                togglingMCPServerNames: [], mcpErrorMessage: nil,
                onFocusChange: { _ in }, onTextChange: { _ in }, onAgentMentionsChange: { _ in },
                onHeightChange: { _ in },
                onSend: { submissions.append("\(delivery.rawValue):\(draft.text)") },
                onStop: {}, onSelectCommand: { _ in }, onPinCommand: { _ in },
                onUnpinCommand: { _ in }, onCompact: {}, onForkMessage: { _ in },
                onLoadMCP: {}, onToggleMCP: { _ in }, onAddAttachments: { _ in },
                onOpenBrowser: nil, glassNamespace: glassNamespace,
                prefersAssistantLayout: ProcessInfo.processInfo.environment["OPENCLIENT_STREAMING_ASSISTANT"] == "1",
                streamingDelivery: delivery,
                onSelectStreamingDelivery: { delivery = $0 }
            )
        }
        .padding()
    }
}

/// Scripted server updates exercise the production pending caption and transcript projection.
struct QueuedSubmissionLifecycleFixture: View {
    @StateObject private var store = ChatStore()
    @StateObject private var draft = MessageComposerDraftStore(text: "Pending follow-up")
    @State private var accessoryOpen = false
    @State private var step = 0
    @Namespace private var glassNamespace
    private let sessionID = "queue-lifecycle"

    private var delivery: OpenCodePromptDelivery {
        ProcessInfo.processInfo.environment["OPENCLIENT_QUEUE_LIFECYCLE_DELIVERY"] == "steer" ? .steer : .queue
    }

    private var queuedMessage: OpenCodeMessageEnvelope {
        fixtureMessage("queued", role: "user", text: "Pending follow-up")
    }

    var body: some View {
        let inputs = store.recoveryInputs(sessionID: sessionID)
        let transcript = SubmissionTranscriptPresentation.messages(canonical: store.messages, recoveries: inputs)
        VStack(spacing: 12) {
            Text(verbatim: "Queue lifecycle fixture")
                .accessibilityIdentifier("screenshot.scene.queue-lifecycle")
            Button(action: advance) { Text(verbatim: "Advance server event") }
                .accessibilityIdentifier("queue.fixture.advance")
                .accessibilityValue(Text(verbatim: String(step)))
                .disabled(draft.text != "" || step >= 6)
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(transcript) { message in
                        Text(verbatim: message.parts.compactMap { $0.text ?? $0.tool }.joined(separator: "\n"))
                            .frame(maxWidth: .infinity, alignment: message.info.role == "user" ? .trailing : .leading)
                            .padding(10)
                            .background(message.info.role == "user" ? Color.blue.opacity(0.1) : Color.gray.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                            .accessibilityIdentifier("queue.fixture.transcript.\(message.id)")
                        if let input = inputs.first(where: { $0.id == message.id }) {
                            SubmissionRecoveryView(input: input, checkStatus: { _ in })
                        }
                    }
                }
            }
            MessageComposer(
                draftStore: draft, isAccessoryMenuOpen: $accessoryOpen,
                commands: [], mentionableAgents: [], pinnedCommands: [], pinnedCommandNames: [],
                attachmentCount: 0, isBusy: step < 3, canFork: false, forkableMessages: [],
                mcpServers: [], connectedMCPServerCount: 0, isLoadingMCP: false,
                togglingMCPServerNames: [], mcpErrorMessage: nil,
                onFocusChange: { _ in }, onTextChange: { _ in }, onAgentMentionsChange: { _ in },
                onHeightChange: { _ in }, onSend: queue, onStop: {},
                onSelectCommand: { _ in }, onPinCommand: { _ in }, onUnpinCommand: { _ in },
                onCompact: {}, onForkMessage: { _ in }, onLoadMCP: {}, onToggleMCP: { _ in },
                onAddAttachments: { _ in }, onOpenBrowser: nil, glassNamespace: glassNamespace,
                prefersAssistantLayout: true, streamingDelivery: delivery,
                onSelectStreamingDelivery: { _ in }
            )
        }
        .padding()
        .onAppear {
            if store.messages.isEmpty { store.appendMessage(assistantMessage("tool1")) }
        }
    }

    private func assistantMessage(_ id: String) -> OpenCodeMessageEnvelope {
        var message = fixtureMessage(id, role: "assistant", text: id == "final" ? "Active turn finished" : id)
        if id.hasPrefix("tool") {
            message.parts = [OpenCodePart(id: "part-\(id)", messageID: id, sessionID: sessionID,
                type: "tool", mime: nil, filename: nil, url: nil, reason: nil,
                tool: id, callID: "call-\(id)", state: nil, text: nil)]
        }
        return message
    }

    private func fixtureMessage(_ id: String, role: String, text: String) -> OpenCodeMessageEnvelope {
        var message = OpenCodeMessageEnvelope.local(role: role, text: text,
            messageID: id, sessionID: sessionID, partID: "part-\(id)")
        let order = ["tool1", "tool2", "tool3", "final", "queued", "answer"].firstIndex(of: id) ?? 0
        message.info = OpenCodeMessage(id: id, role: role, sessionID: sessionID,
            time: .init(created: Double(order + 1) * 1_000), agent: nil, model: nil)
        return message
    }

    private func queue() {
        store.stageSubmissionPresentation(queuedMessage, sessionID: sessionID, canonical: store.messages,
            attachments: [], agentMentions: [], delivery: delivery)
        guard store.beginV2Prompt(queuedMessage, sessionID: sessionID, delivery: delivery) else { return }
        store.confirmSubmissionAdmission(messageID: queuedMessage.id, sessionID: sessionID)
        draft.text = ""
    }

    private func advance() {
        switch step {
        case 0: store.appendMessage(assistantMessage("tool2"))
        case 1: store.appendMessage(assistantMessage("tool3"))
        case 2: store.appendMessage(assistantMessage("final"))
        case 3:
            store.confirmCanonicalSubmission(queuedMessage.info)
            store.appendMessage(OpenCodeMessageEnvelope(info: queuedMessage.info, parts: []))
            store.appendMessage(assistantMessage("answer"))
        case 4:
            let full = store.messages.map { $0.id == queuedMessage.id ? queuedMessage : $0 }
            store.replaceActiveMessagesWithCanonical(full)
            store.retireSubmissionPresentations(in: full, sessionID: sessionID)
        case 5:
            // Replayed evidence must not produce another local bubble or pending caption.
            store.confirmCanonicalSubmission(queuedMessage.info)
            store.replaceActiveMessagesWithCanonical(store.messages + [queuedMessage])
        default: return
        }
        step += 1
    }
}
#endif
