import SwiftUI

#if DEBUG
struct ToolGroupingFixture: View {
    @State private var tools = true
    @State private var reasoning = true
    @State private var grouping = true
    @State private var contexts = true
    @State private var expanded: Set<String> = []
    @State private var images = OpenClientImageLoadingStore()
    @State private var videos = OpenClientVideoPlaybackStore()

    var body: some View {
        NavigationStack {
            VStack {
                if ProcessInfo.processInfo.environment["OPENCLIENT_GALLERY"] != "1" {
                HStack {
                    Button { tools.toggle() } label: { Text(verbatim: "Tools") }
                        .accessibilityIdentifier("grouping.tools")
                    Button { reasoning.toggle() } label: { Text(verbatim: "Reasoning") }
                        .accessibilityIdentifier("grouping.reasoning")
                    Button { grouping.toggle() } label: { Text(verbatim: "Grouping") }
                        .accessibilityIdentifier("grouping.grouping")
                    Button { contexts.toggle() } label: { Text(verbatim: "Context") }
                        .accessibilityIdentifier("grouping.context")
                }
                }
                ScrollView {
                    ForEach(grouping ? TranscriptActivityGrouping.slices(messages) : messages.map {
                        TranscriptActivitySlice(source: $0, parts: $0.parts, isActivity: false)
                    }) { slice in
                    let message = slice.message
                    MessageBubble(message: message, detailedMessage: nil, currentSessionID: "ses_fixture",
                        isStreamingMessage: false, animatesStreamingText: false,
                        showsToolCalls: tools, groupsToolCalls: grouping, hidesReasoningBlocks: !reasoning,
                        reserveEntryFromComposer: false, animateEntryFromComposer: false,
                        expandedReasoningPartIDs: [], expandedContextGroupIDs: expanded, showsAllActivity: true,
                        resolveTaskSessionID: { _, _ in nil }, onSelectPart: { _ in }, onOpenTaskSession: { _ in },
                        onForkMessage: { _ in }, onInspectDebugMessage: { _ in }, onEntryAnimationStarted: { _ in },
                        onToggleReasoningPart: { _ in }, onToggleContextGroup: { id in
                            if expanded.contains(id) { expanded.remove(id) } else { expanded.insert(id) }
                        }, onShowEarlierActivity: {}, onOpenVisualHTML: { _ in }, imageContent: nil,
                        imageLoadingStore: images, videoStreams: nil, videoPlaybackStore: videos)
                        .padding()
                    }
                }
            }
            .navigationTitle(ProcessInfo.processInfo.environment["OPENCLIENT_GALLERY"] == "1" ? Text(verbatim: "Polish the experience") : Text(verbatim: ""))
            .opencodeInlineNavigationTitle()
        }
    }

    private var messages: [OpenCodeMessageEnvelope] {
        message.parts.enumerated().map { index, part in
            var source = OpenCodeMessageEnvelope.local(role: "assistant", text: "", messageID: "msg_\(index)", sessionID: "ses_fixture", partID: "initial")
            source.parts = [part]
            return TranscriptActivityGrouping.filteringContext(source, showsContextChanges: contexts)
        }
    }

    private var message: OpenCodeMessageEnvelope {
        var message = OpenCodeMessageEnvelope.local(role: "assistant", text: "", messageID: "msg_fixture", sessionID: "ses_fixture", partID: "initial")
        func part(_ id: String, type: String, text: String? = nil, tool: String? = nil) -> OpenCodePart {
            OpenCodePart(id: id, messageID: message.id, sessionID: "ses_fixture", type: type, mime: nil,
                filename: nil, url: nil, reason: nil, tool: tool, callID: tool == nil ? nil : id,
                state: tool == nil ? nil : .init(status: "completed", title: tool, error: nil, input: nil, output: "Done", metadata: nil),
                text: text, synthetic: type == "system" || type == "model-switched")
        }
        message.parts = [part("model", type: "model-switched", text: "openai / gpt-6"),
                         part("date", type: "system", text: "Today's date: Tue Sep 29 2026"),
                         part("read", type: "tool", tool: "read"), part("shell", type: "tool", tool: "shell"),
                         part("thinking", type: "reasoning", text: "Checking the results."),
                         part("patch", type: "tool", tool: "patch"),
                         part("answer", type: "text", text: "The changes are ready.")]
        return message
    }
}
#endif
