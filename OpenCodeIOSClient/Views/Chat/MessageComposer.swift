import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PhotosUI) && canImport(UIKit)
import Photos
import PhotosUI
import UniformTypeIdentifiers
#endif

final class MessageComposerDraftStore: ObservableObject {
    @Published var text: String
    @Published var agentMentions: [OpenCodeAgentMention]

    init(text: String = "", agentMentions: [OpenCodeAgentMention] = []) {
        self.text = text
        self.agentMentions = agentMentions
    }
}

private struct MessageComposerHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

#if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
private struct MessageComposerSpeechRecognitionModifier: ViewModifier {
    @ObservedObject var recognizer: OpenClientSpeechRecognitionController
    @Binding var errorMessage: String?

    func body(content: Content) -> some View {
        content
            .onDisappear {
                recognizer.cancel()
            }
            .alert(
                "Dictation Unavailable",
                isPresented: Binding(
                    get: { errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            errorMessage = nil
                            recognizer.clearError()
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    errorMessage = nil
                    recognizer.clearError()
                }
            } message: {
                Text(errorMessage ?? "")
            }
    }
}

private extension View {
    func messageComposerSpeechRecognition(
        recognizer: OpenClientSpeechRecognitionController,
        errorMessage: Binding<String?>
    ) -> some View {
        modifier(
            MessageComposerSpeechRecognitionModifier(
                recognizer: recognizer,
                errorMessage: errorMessage
            )
        )
    }
}
#endif

private extension View {
    @ViewBuilder
    func composerAccessoryTransitionSource(in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            matchedTransitionSource(id: "composer-accessory-popover", in: namespace)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func composerAccessoryTransitionDestination(in namespace: Namespace.ID) -> some View {
        #if os(iOS)
        if #available(iOS 18.0, *) {
            navigationTransition(.zoom(sourceID: "composer-accessory-popover", in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

struct MessageComposer: View {
    private enum AccessoryDestination: Hashable {
        case fork
        case mcp
    }

    private enum ProminentAction {
        case send
        case stop
        case dictate
        case stopDictation
    }

    @ObservedObject var draftStore: MessageComposerDraftStore
    @Binding var isAccessoryMenuOpen: Bool
    let commands: [OpenCodeCommand]
    let mentionableAgents: [OpenCodeAgent]
    let pinnedCommands: [OpenCodeCommand]
    let pinnedCommandNames: Set<String>
    let attachmentCount: Int
    let isBusy: Bool
    let canFork: Bool
    let forkableMessages: [OpenCodeForkableMessage]
    let mcpServers: [OpenCodeMCPServer]
    let connectedMCPServerCount: Int
    let isLoadingMCP: Bool
    let togglingMCPServerNames: Set<String>
    let mcpErrorMessage: String?
    let onFocusChange: (Bool) -> Void
    let onTextChange: (String) -> Void
    let onAgentMentionsChange: ([OpenCodeAgentMention]) -> Void
    let onHeightChange: (CGFloat) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onSelectCommand: (OpenCodeCommand) -> Void
    let onPinCommand: (OpenCodeCommand) -> Void
    let onUnpinCommand: (OpenCodeCommand) -> Void
    let onCompact: () -> Void
    let onForkMessage: (String) -> Void
    let onLoadMCP: () -> Void
    let onToggleMCP: (String) -> Void
    let onAddAttachments: ([OpenCodeComposerAttachment]) -> Void
    let onOpenBrowser: (() -> Void)?
    let glassNamespace: Namespace.ID
    var allowsTextTools = true
    var allowsSessionTools = true
    var autoFocus = false
    var agentTitle: String = ""
    var selectableAgents: [OpenCodeAgent] = []
    var modelTitle: String = ""
    var providerGroups: [ChatFacade.ToolbarProviderGroup] = []
    var reasoningVariants: [ChatFacade.ToolbarReasoningVariant] = []
    var reasoningTitle: String = ""
    var contextSnapshot: OpenCodeSessionContextSnapshot?
    var onSelectAgent: ((String) -> Void)?
    var onSelectModel: ((OpenCodeModelReference) -> Void)?
    var onSelectReasoningVariant: ((String?) -> Void)?
    var onShowContextMetrics: (() -> Void)?
    var conversationState: ConversationModeController.State = .inactive
    var conversationInputLevel: CGFloat = 0
    var onToggleConversation: (() -> Void)?

#if canImport(PhotosUI) && canImport(UIKit)
    private enum AttachmentImportLimits {
        static let maxItemCount = 10
        static let maxInlineBytes = 10 * 1_024 * 1_024
        static let maxTotalBytes = 24 * 1_024 * 1_024
    }
#endif

    @State private var selectedCommandName: String?
    @State private var accessoryPopoverHeight: CGFloat = 315
    @State private var accessoryNavigationPath: [AccessoryDestination] = []
    @Namespace private var accessoryGlassNamespace
    @Namespace private var accessoryPresentationNamespace
#if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
    @StateObject private var dictationController = OpenClientSpeechRecognitionController()
    @State private var dictationErrorMessage: String?
#endif
#if canImport(PhotosUI) && canImport(UIKit)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var recentPhotoAssets: [PHAsset] = []
    @State private var recentPhotoThumbnails: [String: UIImage] = [:]
    @State private var isShowingPhotosPicker = false
    @State private var isShowingFileImporter = false
    @State private var isImportingAttachments = false
    @State private var attachmentImportError: String?
#if canImport(WebKit)
    @State private var isShowingSketchSheet = false
#endif
#endif

    private var text: String {
        draftStore.text
    }

    private var textBinding: Binding<String> {
        Binding(
            get: { draftStore.text },
            set: { newValue in
                setText(newValue)
            }
        )
    }

    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0
    }

    private var showsSendAction: Bool {
        hasDraftContent || !isBusy
    }

    private var canSend: Bool {
        hasDraftContent
    }

    private var canStop: Bool {
        isBusy
    }

    private var isDictating: Bool {
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        dictationController.isActive
        #else
        false
        #endif
    }

    private var isDictationAction: Bool {
        prominentAction == .dictate || prominentAction == .stopDictation
    }

    private var showsSendActionButton: Bool {
        hasDraftContent && !isDictating && !isConversationModeActive
    }

    private var isSendActionButtonEnabled: Bool {
        showsSendActionButton
    }

    private var showsMicActionButton: Bool {
        (!hasDraftContent || isDictating) && !isConversationModeActive
    }

    private var showsStopStreamButton: Bool {
        isBusy
    }

    private var supportsConversationMode: Bool {
        onToggleConversation != nil
    }

    private var showsConversationActionButton: Bool {
        supportsConversationMode && (!hasDraftContent || isConversationModeActive)
    }

    private var showsTrailingActionButton: Bool {
        showsSendActionButton || showsConversationActionButton
    }

    private var isConversationModeActive: Bool {
        conversationState.isActive
    }

    private var canToggleConversationMode: Bool {
        isConversationModeActive || (!isBusy && attachmentCount == 0 && !isDictating)
    }

    private var conversationStatus: LocalizedStringResource {
        switch conversationState {
        case .inactive:
            "Voice Conversation"
        case .ready:
            "Hold to Talk"
        case .starting:
            "Starting conversation..."
        case .listening, .waitingToSend:
            "Listening..."
        case .finalizing, .submitting:
            "Sending..."
        case .waitingForResponse:
            "Waiting for a response..."
        case .speakingResponse:
            "Speaking..."
        case .paused:
            "Conversation paused"
        }
    }

    private var isListeningForDictation: Bool {
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        dictationController.isRecording
        #else
        false
        #endif
    }

    private var dictationInputLevel: CGFloat {
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        dictationController.inputLevel
        #else
        0
        #endif
    }

    private var composerActionButtonSize: CGFloat {
        composerActionSlotHeight
    }

    private var catalystControlHitTargetSize: CGFloat {
        44
    }

    private var usesCatalystComposerLayout: Bool {
        #if targetEnvironment(macCatalyst)
        true
        #elseif os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }

    private var composerGlassMergeSpacing: CGFloat {
        8
    }

    private var composerActionSlotHeight: CGFloat {
        #if canImport(UIKit)
        ComposerTextViewMetrics.minimumHeight
        #else
        48
        #endif
    }

    private var prominentAction: ProminentAction {
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        if dictationController.isActive {
            return .stopDictation
        }

        if !hasDraftContent {
            return .dictate
        }
        #endif

        if isBusy && !hasDraftContent {
            return .stop
        }

        return .send
    }

    private var prominentActionSystemImage: String {
        switch prominentAction {
        case .send:
            "arrow.up"
        case .stop:
            "stop.fill"
        case .dictate, .stopDictation:
            "mic.fill"
        }
    }

    private var isProminentActionEnabled: Bool {
        switch prominentAction {
        case .send:
            canSend
        case .stop:
            canStop
        case .dictate, .stopDictation:
            true
        }
    }

    private var prominentActionAccessibilityLabel: LocalizedStringResource {
        switch prominentAction {
        case .send:
            "Send"
        case .stop:
            "Stop"
        case .dictate:
            "Dictate"
        case .stopDictation:
            "Stop Dictation"
        }
    }

    private var prominentActionAccessibilityIdentifier: String {
        switch prominentAction {
        case .send:
            "chat.send"
        case .stop:
            "chat.stop"
        case .dictate:
            "chat.dictate"
        case .stopDictation:
            "chat.dictate.stop"
        }
    }

    private var canInsertCommandShortcut: Bool {
        allowsTextTools && text.isEmpty && attachmentCount == 0 && !isBusy && !commands.isEmpty
    }

    private var canInsertAgentMentionShortcut: Bool {
        allowsTextTools && !isBusy && !mentionableAgents.isEmpty
    }

    private var showsPinnedCommands: Bool {
        allowsTextTools && text.isEmpty && attachmentCount == 0 && !isBusy && !pinnedCommands.isEmpty
    }

    private var slashQuery: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }
        let body = String(trimmed.dropFirst())
        guard !body.contains(where: { $0.isWhitespace }) else { return nil }
        return body
    }

    private var filteredCommands: [OpenCodeCommand] {
        guard let query = slashQuery else { return [] }
        if query.isEmpty {
            return commands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return commands
            .filter { command in
                command.name.localizedCaseInsensitiveContains(query) ||
                    (command.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var agentMentionQuery: String? {
        guard let match = currentAgentMentionMatch() else { return nil }
        return match.query
    }

    private var filteredMentionableAgents: [OpenCodeAgent] {
        guard let query = agentMentionQuery else { return [] }
        if query.isEmpty { return Array(mentionableAgents.prefix(10)) }
        return mentionableAgents
            .filter { agent in
                agent.name.localizedCaseInsensitiveContains(query) ||
                    (agent.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .prefix(10)
            .map { $0 }
    }

    private var showsAgentMentionPicker: Bool {
        agentMentionQuery != nil && !isBusy && !mentionableAgents.isEmpty
    }

    private var selectedCommand: OpenCodeCommand? {
        if let selectedCommandName {
            return filteredCommands.first(where: { $0.name == selectedCommandName })
        }
        return filteredCommands.first
    }

    private var showsCommandPicker: Bool {
        allowsTextTools && slashQuery != nil && !isBusy
    }

    private var expandedAccessorySheetDetentHeight: CGFloat {
        #if canImport(PhotosUI) && canImport(UIKit)
        recentPhotoAssets.isEmpty ? 475 : 575
        #else
        380
        #endif
    }

    private var isComposerActionsScreenshotScene: Bool {
        ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] == "composer-actions"
    }

    var body: some View {
        composerContent
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(key: MessageComposerHeightPreferenceKey.self, value: geometry.size.height)
                }
            }
            .onPreferenceChange(MessageComposerHeightPreferenceKey.self) { height in
                onHeightChange(height)
            }
            .onAppear {
                syncSelectedCommand()
            }
            .onChange(of: draftStore.text) { _, _ in
                syncSelectedCommand()
                reconcileAgentMentions()
                if !text.isEmpty {
                    isAccessoryMenuOpen = false
                }
            }
            .onChange(of: isBusy) { _, busy in
                if busy {
                    isAccessoryMenuOpen = false
                    #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
                    dictationController.cancel()
                    #endif
                }
            }
            .onChange(of: isAccessoryMenuOpen) { _, isOpen in
                if isOpen {
                    accessoryPopoverHeight = isComposerActionsScreenshotScene ? expandedAccessorySheetDetentHeight : 315
                    accessoryNavigationPath = []
                }
            }
#if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
            .messageComposerSpeechRecognition(
                recognizer: dictationController,
                errorMessage: $dictationErrorMessage
            )
#endif
#if canImport(PhotosUI) && canImport(UIKit)
            .onChange(of: selectedPhotoItems) { _, _ in
                Task { await loadSelectedPhotoItems() }
            }
            .onChange(of: isAccessoryMenuOpen) { _, isOpen in
                guard isOpen else { return }
                Task { await loadRecentPhotosIfAllowed() }
            }
            .fileImporter(
                isPresented: $isShowingFileImporter,
                allowedContentTypes: [.item],
                allowsMultipleSelection: true
            ) { result in
                importSelectedFiles(result)
            }
            .photosPicker(
                isPresented: $isShowingPhotosPicker,
                selection: $selectedPhotoItems,
                maxSelectionCount: AttachmentImportLimits.maxItemCount,
                matching: .images
            )
            .alert(
                "Attachment Not Added",
                isPresented: Binding(
                    get: { attachmentImportError != nil },
                    set: { isPresented in
                        if !isPresented {
                            attachmentImportError = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    attachmentImportError = nil
                }
            } message: {
                Text(attachmentImportError ?? "")
            }
#endif
            .animation(opencodeSelectionAnimation, value: filteredCommands.map(\.name).joined(separator: "|"))
            .animation(opencodeSelectionAnimation, value: filteredMentionableAgents.map(\.name).joined(separator: "|"))
            .animation(opencodeSelectionAnimation, value: showsAgentMentionPicker)
            .animation(opencodeSelectionAnimation, value: showsPinnedCommands)
            .animation(opencodeSelectionAnimation, value: pinnedCommands.map(\.name).joined(separator: "|"))
            .animation(opencodeSelectionAnimation, value: isAccessoryMenuOpen)
    }

    private var composerContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCommandPicker {
                CommandPicker(
                    commands: filteredCommands,
                    selectedCommandName: selectedCommand?.name,
                    pinnedCommandNames: pinnedCommandNames,
                    onSelect: { command in
                        onSelectCommand(command)
                    },
                    onPin: { command in
                        onPinCommand(command)
                    },
                    onUnpin: { command in
                        onUnpinCommand(command)
                    }
                )
                .transition(
                    .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.98, anchor: .bottom))
                )
            }

            if showsAgentMentionPicker {
                AgentMentionPicker(
                    agents: filteredMentionableAgents,
                    onSelect: insertAgentMention
                )
                .transition(
                    .move(edge: .bottom)
                        .combined(with: .opacity)
                        .combined(with: .scale(scale: 0.98, anchor: .bottom))
                )
            }

            if showsPinnedCommands {
                PinnedCommandStrip(
                    commands: pinnedCommands,
                    onSelect: onSelectCommand,
                    onUnpin: onUnpinCommand
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            if isConversationModeActive {
                conversationStatusBar
            }

            #if os(macOS)
            macComposer
            #else
            iosComposer
            #endif
        }
    }

    #if os(macOS)
    private var macComposer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: textBinding, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1 ... 8)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(minHeight: 46)
                .accessibilityIdentifier("chat.input")

            Button(action: showsSendAction ? onSend : onStop) {
                Image(systemName: showsSendAction ? "arrow.up" : "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity((showsSendAction ? canSend : canStop) ? 1 : 0.78))
                    .frame(width: 18, height: 18)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.96), Color.accentColor.opacity(0.74)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity((showsSendAction ? canSend : canStop) ? 0.18 : 0.10), radius: 10, y: 4)
                    .opacity((showsSendAction ? canSend : canStop) ? 1 : 0.6)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .disabled(showsSendAction ? !canSend : !canStop)
            .accessibilityLabel(showsSendAction ? LocalizedStringResource("Send") : LocalizedStringResource("Stop"))
            .accessibilityIdentifier(showsSendAction ? "chat.send" : "chat.stop")
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
        )
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        .animation(opencodeSelectionAnimation, value: isBusy)
        .animation(opencodeSelectionAnimation, value: canSend)
    }
    #endif

    private var iosComposer: some View {
        Group {
            if usesCatalystComposerLayout {
                catalystComposer
            } else {
                mobileComposer
            }
        }
        .shadow(color: .black.opacity(0.12), radius: 16, y: 5)
        .animation(opencodeSelectionAnimation, value: isBusy)
        .animation(opencodeSelectionAnimation, value: canSend)
        .animation(opencodeSelectionAnimation, value: isDictating)
        .animation(streamStopButtonAnimation, value: isBusy)
        .animation(.snappy(duration: 0.12), value: dictationInputLevel)
        .animation(opencodeSelectionAnimation, value: isAccessoryMenuOpen)
        .animation(opencodeSelectionAnimation, value: conversationState)
#if canImport(UIKit) && canImport(WebKit)
        .sheet(isPresented: $isShowingSketchSheet) {
            NavigationStack {
                ExcalidrawDrawingSheet { attachment in
                    onAddAttachments([attachment])
                    isShowingSketchSheet = false
                }
            }
            .presentationDetents([.large])
        }
#endif
    }

    private var mobileComposer: some View {
        HStack(alignment: .bottom, spacing: 5) {
            accessoryContainer
                .zIndex(3)

            composerInputGlassContainer
                .frame(maxWidth: .infinity)
                .zIndex(1)
        }
    }

    private var accessoryContainer: some View {
        collapsedAccessoryButton
    }

    private func dismissAccessoryMenu() {
        if isAccessoryMenuOpen {
            withAnimation(opencodeSelectionAnimation) {
                isAccessoryMenuOpen = false
            }
        }
    }

    #if os(iOS)
    private var catalystComposer: some View {
        VStack(spacing: 0) {
            composerTextFieldContent
                .frame(maxWidth: .infinity)

            catalystComposerControlBar
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                .onTapGesture {}
        }
        .padding(.bottom, 10)
    }

    private var catalystComposerControlBar: some View {
        HStack(spacing: 4) {
            catalystAccessoryButton

            catalystSelectorMenuRow

            Spacer()

            if let onShowContextMetrics {
                SessionContextUsageToolbarButton(
                    context: contextSnapshot,
                    hitTargetSize: catalystControlHitTargetSize,
                    action: onShowContextMetrics
                )
            }

            if showsStopStreamButton {
                catalystStopStreamButton
                    .transition(stopStreamButtonTransition)
            }

            if showsMicActionButton {
                catalystMicActionButton
            }

            if showsTrailingActionButton {
                catalystTrailingActionSlot
            }
        }
        .padding(.horizontal, 8)
        .frame(height: catalystControlHitTargetSize)
    }

    private var catalystSelectorMenuRow: some View {
        HStack(spacing: 4) {
            if !agentTitle.isEmpty, let onSelectAgent {
                StablePickerMenu(
                    elements: selectableAgents.map { agent in
                        .action(
                            id: agent.name,
                            title: agent.name.capitalized,
                            systemImage: "person.crop.circle",
                            isSelected: agent.name.caseInsensitiveCompare(agentTitle) == .orderedSame
                        )
                    },
                    accessibilityLabel: String(localized: "Agent"),
                    accessibilityValue: agentTitle,
                    accessibilityIdentifier: "chat.composer.agent",
                    onSelect: onSelectAgent
                ) {
                    catalystSelectorLabel(
                        title: agentTitle.capitalized,
                        systemImage: "person.crop.circle"
                    )
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }

            if !modelTitle.isEmpty, onSelectModel != nil {
                StablePickerMenu(
                    elements: modelMenuElements,
                    accessibilityLabel: String(localized: "Model"),
                    accessibilityValue: modelTitle,
                    accessibilityIdentifier: "chat.composer.model",
                    onSelect: selectModel
                ) {
                    catalystSelectorLabel(
                        title: modelTitle,
                        systemImage: "cpu"
                    )
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }

            if !reasoningVariants.isEmpty, let onSelectReasoningVariant {
                StablePickerMenu(
                    elements: reasoningMenuElements,
                    accessibilityLabel: String(localized: "Reasoning"),
                    accessibilityValue: reasoningTitle,
                    accessibilityIdentifier: "chat.composer.reasoning",
                    onSelect: { actionID in
                        if actionID == "reasoning:default" {
                            onSelectReasoningVariant(nil)
                        } else if actionID.hasPrefix("reasoning:variant:") {
                            onSelectReasoningVariant(String(actionID.dropFirst("reasoning:variant:".count)))
                        }
                    }
                ) {
                    catalystSelectorLabel(
                        title: reasoningTitle,
                        systemImage: "brain.head.profile"
                    )
                }
                .transaction { transaction in
                    transaction.animation = nil
                }
            }
        }
    }

    private var catalystAccessoryButton: some View {
        Button(action: presentAccessoryMenu) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: catalystControlHitTargetSize, height: catalystControlHitTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open composer menu")
        .accessibilityIdentifier("chat.composer.menu")
        .composerAccessoryTransitionSource(in: accessoryPresentationNamespace)
        .popover(
            isPresented: $isAccessoryMenuOpen,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            accessoryPopoverContent
        }
    }

    private var catalystTrailingActionSlot: some View {
        ZStack {
            if showsSendActionButton {
                catalystSendActionButton
                    .transition(sendActionButtonTransition)
            }

            if showsConversationActionButton {
                catalystConversationActionButton
                    .transition(conversationActionButtonTransition)
            }
        }
        .frame(width: catalystControlHitTargetSize, height: catalystControlHitTargetSize)
    }

    private var catalystSendActionButton: some View {
        Button {
            guard isSendActionButtonEnabled else { return }
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(isSendActionButtonEnabled ? 1 : 0.68))
                .frame(width: 32, height: 32)
                .background(Color.accentColor.opacity(0.82), in: Circle())
                .frame(width: catalystControlHitTargetSize, height: catalystControlHitTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .disabled(!isSendActionButtonEnabled)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("chat.send")
    }

    private var catalystMicActionButton: some View {
        Button {
            if isDictating {
                stopDictation()
            } else {
                startDictation()
            }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(micActionForeground)
                .frame(width: 32, height: 32)
                .background(Color.primary.opacity(0.07), in: Circle())
                .frame(width: catalystControlHitTargetSize, height: catalystControlHitTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .disabled(!showsMicActionButton)
        .accessibilityLabel(micActionAccessibilityLabel)
        .accessibilityIdentifier(micActionAccessibilityIdentifier)
    }

    private var catalystConversationActionButton: some View {
        Button {
            onToggleConversation?()
        } label: {
            Image(systemName: isConversationModeActive ? "xmark" : "waveform")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(canToggleConversationMode ? 1 : 0.65))
                .frame(width: 32, height: 32)
                .background(Color.blue.opacity(0.82), in: Circle())
                .frame(width: catalystControlHitTargetSize, height: catalystControlHitTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .disabled(!canToggleConversationMode)
        .accessibilityLabel(isConversationModeActive ? LocalizedStringResource("Stop Conversation") : LocalizedStringResource("Start Conversation"))
        .accessibilityIdentifier(isConversationModeActive ? "chat.conversation.stop" : "chat.conversation.start")
    }

    private var catalystStopStreamButton: some View {
        Button {
            OpenCodeHaptics.impact(.soft)
            onStop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
                .background(Color.red.opacity(0.72), in: Circle())
                .frame(width: catalystControlHitTargetSize, height: catalystControlHitTargetSize)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Stop Stream")
        .accessibilityIdentifier("chat.stream.stop")
    }

    private func catalystSelectorLabel(title: String, systemImage: String) -> some View {
        Label(title, systemImage: systemImage)
            .font(.footnote.weight(.medium))
            .foregroundStyle(.primary)
            .lineLimit(1)
            .padding(.horizontal, 6)
            .frame(height: catalystControlHitTargetSize)
            .contentShape(Rectangle())
    }

    private var modelMenuElements: [StablePickerMenuElement] {
        [StablePickerMenuElement.submenu(
            id: "models",
            title: String(localized: "Model"),
            children: providerGroups.map { provider in
                .submenu(
                    id: "provider:\(provider.id)",
                    title: provider.name,
                    children: provider.models.map { model in
                        .action(
                            id: "model:\(provider.id):\(model.id)",
                            title: model.name,
                            systemImage: nil,
                            isSelected: model.name == modelTitle
                        )
                    }
                )
            }
        )]
    }

    private var reasoningMenuElements: [StablePickerMenuElement] {
        [.inline(
            id: "reasoning",
            title: nil,
            children: [
                .action(
                    id: "reasoning:default",
                    title: String(localized: "Default"),
                    systemImage: "sparkles",
                    isSelected: reasoningTitle == String(localized: "Default")
                )
            ] + reasoningVariants.map { variant in
                .action(
                    id: "reasoning:variant:\(variant.id)",
                    title: variant.title,
                    systemImage: "brain.head.profile",
                    isSelected: variant.title == reasoningTitle
                )
            }
        )]
    }

    private func selectModel(_ actionID: String) {
        guard let onSelectModel else { return }
        for provider in providerGroups {
            if let model = provider.models.first(where: {
                "model:\(provider.id):\($0.id)" == actionID
            }) {
                onSelectModel(OpenCodeModelReference(providerID: provider.id, modelID: model.id))
                return
            }
        }
    }
    #endif

    private func startDictation() {
        guard !hasDraftContent else { return }
        dismissAccessoryMenu()
        OpenCodeHaptics.impact(.soft)
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        let baseText = text
        Task { @MainActor in
            do {
                try await dictationController.start(
                    onTranscript: { transcript in
                        setText(baseText + transcript)
                    },
                    onError: { message in
                        dictationErrorMessage = message
                    }
                )
            } catch {
                dictationErrorMessage = error.localizedDescription
            }
        }
        #endif
    }

    private func stopDictation() {
        #if canImport(AVFoundation) && canImport(Speech) && canImport(UIKit)
        OpenCodeHaptics.impact(.soft)
        dictationController.stop()
        #endif
    }

    @ViewBuilder
    private var composerInputGlassContainer: some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: composerGlassMergeSpacing) {
                composerInputActionRow
            }
        } else {
            composerInputActionRow
        }
        #else
        composerInputActionRow
        #endif
    }

    private var composerInputActionRow: some View {
        HStack(alignment: .bottom, spacing: 5) {
            composerTextFieldGlass
                .frame(maxWidth: .infinity)
                .layoutPriority(1)

            if showsTrailingActionButton {
                composerTrailingActionSlot
                    .zIndex(3)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if showsStopStreamButton {
                stopStreamButton
                    .offset(y: stopStreamButtonYOffset)
                    .transition(stopStreamButtonTransition)
                    .zIndex(4)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(opencodeSelectionAnimation, value: hasDraftContent)
    }

    @ViewBuilder
    private var composerTextFieldGlass: some View {
        composerTextFieldContent
            .padding(.trailing, showsMicActionButton ? composerActionButtonSize : 0)
            .overlay(alignment: .bottomTrailing) {
                if showsMicActionButton {
                    micActionButton
                        .transition(micActionButtonTransition)
                        .zIndex(2)
                }
            }
            .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .opencodeGlassSurface(isInteractive: true, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    @ViewBuilder
    private var composerTextFieldContent: some View {
        #if canImport(UIKit)
        ComposerTextView(
            text: textBinding,
            agentMentions: draftStore.agentMentions,
            placeholder: "Message",
            maxLines: 6,
            canSubmit: canSend && !isDictating,
            autoFocus: autoFocus,
            onPasteImages: pastedImageHandler,
            onSubmit: onSend,
            onFocusChange: onFocusChange
        )
        .frame(minHeight: usesCatalystComposerLayout ? ComposerTextViewMetrics.compactMinimumHeight : ComposerTextViewMetrics.minimumHeight)
        .disabled(isConversationModeActive)
        .accessibilityIdentifier("chat.input")
        #else
        TextField("Message", text: textBinding, axis: .vertical)
            .lineLimit(1 ... 6)
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            .frame(minHeight: composerActionSlotHeight)
            .disabled(isConversationModeActive)
            .accessibilityIdentifier("chat.input")
            .simultaneousGesture(TapGesture().onEnded {
                dismissAccessoryMenu()
            })
        #endif
    }

    private var composerTrailingActionSlot: some View {
        ZStack {
            if showsSendActionButton {
                sendActionButton
                    .transition(sendActionButtonTransition)
                    .zIndex(2)
            }

            if showsConversationActionButton {
                conversationActionButton
                    .transition(conversationActionButtonTransition)
                    .zIndex(1)
            }
        }
        .frame(width: composerActionButtonSize, height: composerActionSlotHeight, alignment: .bottom)
    }

    private var sendActionButton: some View {
        Button {
            guard isSendActionButtonEnabled else { return }
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(prominentActionForeground(isEnabled: isSendActionButtonEnabled))
                .frame(width: composerActionButtonSize, height: composerActionButtonSize)
        }
        .opencodeActionGlass(clear: true, tint: Color.accentColor.opacity(0.82), size: composerActionButtonSize, in: Circle())
        .opencodeToolbarGlassID("composer-send-action", in: glassNamespace)
        .opencodeMatchedGlassTransition()
        .buttonBorderShape(.circle)
        .contentShape(Circle())
        .disabled(!isSendActionButtonEnabled)
        .accessibilityLabel("Send")
        .accessibilityIdentifier("chat.send")
    }

    private var micActionButton: some View {
        Button {
            if isDictating {
                stopDictation()
            } else {
                startDictation()
            }
        } label: {
            Image(systemName: "mic.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(micActionForeground)
                .frame(width: composerActionButtonSize, height: composerActionButtonSize)
                .background {
                    if isListeningForDictation {
                        dictationButtonBackground
                    }
                }
        }
        .buttonStyle(.plain)
        .buttonBorderShape(.circle)
        .contentShape(Circle())
        .disabled(!showsMicActionButton)
        .accessibilityLabel(micActionAccessibilityLabel)
        .accessibilityIdentifier(micActionAccessibilityIdentifier)
    }

    private var conversationActionButton: some View {
        Button {
            OpenCodeHaptics.impact(.soft)
            onToggleConversation?()
        } label: {
            Image(systemName: isConversationModeActive ? "xmark" : "waveform")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white.opacity(canToggleConversationMode ? 1 : 0.68))
                .frame(width: composerActionButtonSize, height: composerActionButtonSize)
                .background {
                    if conversationState == .listening {
                        conversationListeningBackground
                    }
                }
        }
        .opencodeActionGlass(clear: true, tint: Color.accentColor.opacity(0.82), size: composerActionButtonSize, in: Circle())
        .opencodeToolbarGlassID("composer-conversation-action", in: glassNamespace)
        .buttonBorderShape(.circle)
        .contentShape(Circle())
        .disabled(!canToggleConversationMode)
        .accessibilityLabel(isConversationModeActive ? LocalizedStringResource("Stop Conversation") : LocalizedStringResource("Start Conversation"))
        .accessibilityIdentifier(isConversationModeActive ? "chat.conversation.stop" : "chat.conversation.start")
    }

    private var stopStreamButton: some View {
        Button {
            OpenCodeHaptics.impact(.soft)
            onStop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: composerActionButtonSize, height: composerActionButtonSize)
        }
        .opencodeActionGlass(tint: Color.red.opacity(0.64), size: composerActionButtonSize, in: Circle())
        .opencodeToolbarGlassID("composer-stop-action", in: glassNamespace)
        .buttonBorderShape(.circle)
        .contentShape(Circle())
        .accessibilityLabel("Stop Stream")
        .accessibilityIdentifier("chat.stream.stop")
        .shadow(color: Color.red.opacity(0.22), radius: 12, y: 4)
    }

    private var streamStopButtonAnimation: Animation {
        .snappy(duration: 0.34, extraBounce: 0.18)
    }

    private var stopStreamButtonYOffset: CGFloat {
        -(composerActionButtonSize + 10)
    }

    private var stopStreamButtonTransition: AnyTransition {
        AnyTransition.asymmetric(
            insertion: AnyTransition.scale(scale: 0.72, anchor: .center)
                .combined(with: AnyTransition.offset(x: -8, y: 0))
                .combined(with: AnyTransition.opacity),
            removal: AnyTransition.scale(scale: 0.66, anchor: .center)
                .combined(with: AnyTransition.offset(x: 0, y: 26))
                .combined(with: AnyTransition.opacity)
        )
    }

    private var sendActionButtonTransition: AnyTransition {
        AnyTransition.scale(scale: 0.68, anchor: .center)
            .combined(with: AnyTransition.opacity)
    }

    private var micActionButtonTransition: AnyTransition {
        AnyTransition.scale(scale: 0.72, anchor: .center)
            .combined(with: AnyTransition.opacity)
    }

    private var conversationActionButtonTransition: AnyTransition {
        AnyTransition.scale(scale: 0.72, anchor: .center)
            .combined(with: AnyTransition.opacity)
    }

    private var micActionForeground: Color {
        isListeningForDictation ? .red : .primary
    }

    private var micActionAccessibilityLabel: LocalizedStringResource {
        isDictating ? "Stop Dictation" : "Dictate"
    }

    private var micActionAccessibilityIdentifier: String {
        isDictating ? "chat.dictate.stop" : "chat.dictate"
    }

    private var dictationButtonBackground: some View {
        ZStack {
            Circle()
                .fill(Color.primary.opacity(isListeningForDictation ? 0.06 + dictationInputLevel * 0.10 : 0.06))

            if isListeningForDictation {
                Circle()
                    .fill(Color.red.opacity(0.10 + dictationInputLevel * 0.18))
                    .frame(width: 20 + dictationInputLevel * 14, height: 20 + dictationInputLevel * 14)
                    .shadow(
                        color: Color.red.opacity(0.30 + dictationInputLevel * 0.62),
                        radius: 5 + dictationInputLevel * 15,
                        y: 0
                    )
                    .blur(radius: 0.35 + dictationInputLevel * 1.35)
            }

            Circle()
                .strokeBorder(Color.primary.opacity(0.12), lineWidth: 1)

            if isListeningForDictation {
                Circle()
                    .strokeBorder(Color.red.opacity(0.24 + dictationInputLevel * 0.46), lineWidth: 1.4)
                    .scaleEffect(1.10 + dictationInputLevel * 0.58)
                    .opacity(0.38 + dictationInputLevel * 0.62)
            }
        }
    }

    private var conversationListeningBackground: some View {
        Circle()
            .fill(Color.white.opacity(0.12 + conversationInputLevel * 0.20))
            .frame(
                width: 20 + conversationInputLevel * 14,
                height: 20 + conversationInputLevel * 14
            )
            .shadow(
                color: Color.blue.opacity(0.32 + conversationInputLevel * 0.46),
                radius: 5 + conversationInputLevel * 12
            )
    }

    private var conversationStatusBar: some View {
        HStack(spacing: 10) {
            Image(systemName: conversationState == .listening ? "waveform" : "waveform.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.blue)
                .symbolEffect(.variableColor.iterative, isActive: conversationState == .listening)

            Text(conversationStatus)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)

            Spacer(minLength: 8)

        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .strokeBorder(Color.blue.opacity(0.14), lineWidth: 1)
        }
    }

    private var collapsedAccessoryButton: some View {
        Button(action: presentAccessoryMenu) {
            Image(systemName: "plus")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 32, height: 32)
        }
        .composerPlusButtonStyle()
        .accessibilityLabel("Open composer menu")
        .accessibilityIdentifier("chat.composer.menu")
        .disabled(isConversationModeActive)
        .contentShape(Circle())
        .opencodeToolbarGlassID("composer-plus-menu", in: accessoryGlassNamespace)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .composerAccessoryTransitionSource(in: accessoryPresentationNamespace)
        .popover(
            isPresented: $isAccessoryMenuOpen,
            attachmentAnchor: .rect(.bounds),
            arrowEdge: .bottom
        ) {
            accessoryPopoverContent
        }
    }

    private func presentAccessoryMenu() {
        OpenCodeHaptics.impact(.soft)
        withAnimation(opencodeSelectionAnimation) {
            isAccessoryMenuOpen = true
        }
    }

    private func prominentActionForeground(isEnabled: Bool) -> Color {
        if prominentAction == .stopDictation {
            return isListeningForDictation ? .red.opacity(isEnabled ? 1 : 0.68) : .primary.opacity(isEnabled ? 1 : 0.68)
        }

        if prominentAction == .dictate {
            return .primary.opacity(isEnabled ? 1 : 0.68)
        }

        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            return .white.opacity(isEnabled ? 1 : 0.68)
        }
        #endif
        return isEnabled ? .primary : .secondary
    }

    private var expandedAccessoryMenu: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
#if canImport(PhotosUI) && canImport(UIKit)
                AccessorySectionTitle("ATTACHMENTS")

                recentPhotosStrip

                HStack(spacing: 10) {
                    AccessoryMenuAction(
                        title: "Photos",
                        subtitle: "Add images",
                        systemImage: "photo.on.rectangle.angled",
                        tint: .pink,
                        isDisabled: isBusy || isImportingAttachments,
                        accessibilityIdentifier: "chat.composer.photos",
                        action: {
                            isAccessoryMenuOpen = false
                            DispatchQueue.main.async {
                                isShowingPhotosPicker = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)

                    AccessoryMenuAction(
                        title: "Files",
                        subtitle: "Add files",
                        systemImage: "doc.badge.plus",
                        tint: .orange,
                        isDisabled: isBusy || isImportingAttachments,
                        accessibilityIdentifier: "chat.composer.files",
                        action: {
                            isAccessoryMenuOpen = false
                            DispatchQueue.main.async {
                                isShowingFileImporter = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }

                if isImportingAttachments {
                    Label("Preparing attachments", systemImage: "hourglass")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 2)
                }

#if canImport(UIKit) && canImport(WebKit)
                AccessoryMenuAction(
                    title: "Sketch",
                    subtitle: "Draw a diagram",
                    systemImage: "scribble.variable",
                    tint: .cyan,
                    isDisabled: isBusy,
                    accessibilityIdentifier: "chat.composer.sketch",
                    action: {
                        isAccessoryMenuOpen = false
                        DispatchQueue.main.async {
                            isShowingSketchSheet = true
                        }
                    }
                )
#endif
#endif

                if allowsTextTools || allowsSessionTools || onOpenBrowser != nil {
                    AccessorySectionTitle("UTILITIES")

                    if let onOpenBrowser {
                        AccessoryMenuAction(
                            title: "Browser",
                            subtitle: "Open a webpage",
                            systemImage: "globe",
                            tint: .blue,
                            isDisabled: false,
                            accessibilityIdentifier: "chat.composer.browser",
                            action: {
                                isAccessoryMenuOpen = false
                                DispatchQueue.main.async {
                                    onOpenBrowser()
                                }
                            }
                        )
                    }

                    if allowsSessionTools {
                        AccessoryMenuAction(
                            title: "MCP",
                            subtitle: "Toggle servers",
                            systemImage: "server.rack",
                            tint: .indigo,
                            isDisabled: false,
                            accessibilityIdentifier: "chat.composer.mcp",
                            action: {
                                expandAccessorySheetForNestedContentIfNeeded()
                                accessoryNavigationPath.append(.mcp)
                            }
                        )
                    }

                    if allowsTextTools {
                        AccessoryMenuAction(
                            title: "Commands",
                            subtitle: "Insert slash command",
                            systemImage: "chevron.left.forwardslash.chevron.right",
                            tint: .blue,
                            isDisabled: !canInsertCommandShortcut,
                            action: insertSlashCommand
                        )

                        AccessoryMenuAction(
                            title: "Agent Mention",
                            subtitle: "Mention a sub agent",
                            systemImage: "brain.head.profile",
                            tint: .purple,
                            isDisabled: !canInsertAgentMentionShortcut,
                            action: insertAgentMentionShortcut
                        )
                    }

                    if allowsSessionTools {
                        AccessoryMenuAction(
                            title: "Compact Session",
                            subtitle: "Summarize context",
                            systemImage: "rectangle.compress.vertical",
                            tint: .teal,
                            isDisabled: isBusy,
                            action: {
                                isAccessoryMenuOpen = false
                                onCompact()
                            }
                        )

                        AccessoryMenuAction(
                            title: "Fork",
                            subtitle: "Start from a message",
                            systemImage: "arrow.triangle.branch",
                            tint: .purple,
                            isDisabled: isBusy || !canFork,
                            action: {
                                expandAccessorySheetForNestedContentIfNeeded()
                                accessoryNavigationPath.append(.fork)
                            }
                        )
                    }
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
        .opencodeSoftScrollEdgeEffect()
    }

#if canImport(PhotosUI) && canImport(UIKit)
    @ViewBuilder
    private var recentPhotosStrip: some View {
        if !recentPhotoAssets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recentPhotoAssets, id: \.localIdentifier) { asset in
                        Button {
                            attachRecentPhoto(asset)
                        } label: {
                            Group {
                                if let image = recentPhotoThumbnails[asset.localIdentifier] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Rectangle()
                                        .fill(.regularMaterial)
                                        .overlay {
                                            Image(systemName: "photo")
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                }
                            }
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy || isImportingAttachments)
                        .accessibilityLabel("Attach recent photo")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 4)
        }
    }
#endif

    private var accessorySheetContent: some View {
        expandedAccessoryMenu
    }

    private var accessoryPopoverContent: some View {
        NavigationStack(path: $accessoryNavigationPath) {
            accessorySheetContent
                .navigationTitle("Message Tools")
                .opencodeInlineNavigationTitle()
                .navigationDestination(for: AccessoryDestination.self) { destination in
                    switch destination {
                    case .fork:
                        ComposerForkListView(
                            messages: forkableMessages,
                            onForkMessage: { messageID in
                                isAccessoryMenuOpen = false
                                onForkMessage(messageID)
                            }
                        )
                    case .mcp:
                        ComposerMCPListView(
                            servers: mcpServers,
                            connectedCount: connectedMCPServerCount,
                            isLoading: isLoadingMCP,
                            togglingServerNames: togglingMCPServerNames,
                            errorMessage: mcpErrorMessage,
                            onLoad: onLoadMCP,
                            onToggle: onToggleMCP
                        )
                    }
                }
        }
        .frame(width: usesCatalystComposerLayout ? 400 : 350, height: accessoryPopoverHeight)
        .presentationCompactAdaptation(.popover)
        .composerAccessoryTransitionDestination(in: accessoryPresentationNamespace)
    }

    private func expandAccessorySheetForNestedContentIfNeeded() {
        if accessoryPopoverHeight == 315 {
            accessoryPopoverHeight = expandedAccessorySheetDetentHeight
        }
    }

    private func syncSelectedCommand() {
        guard showsCommandPicker else {
            selectedCommandName = nil
            return
        }

        if let selectedCommandName,
           filteredCommands.contains(where: { $0.name == selectedCommandName }) {
            return
        }

        selectedCommandName = filteredCommands.first?.name
    }

    private func insertSlashCommand() {
        guard canInsertCommandShortcut else { return }
        setText("/")
        isAccessoryMenuOpen = false
    }

    private func insertAgentMentionShortcut() {
        guard canInsertAgentMentionShortcut else { return }
        let nextText: String
        if text.isEmpty || text.last?.isWhitespace == true {
            nextText = text + "@"
        } else {
            nextText = text + " @"
        }
        setText(nextText)
        isAccessoryMenuOpen = false
    }

    private func currentAgentMentionMatch() -> (range: Range<String.Index>, query: String)? {
        let prefix = text
        guard let atIndex = prefix.lastIndex(of: "@") else { return nil }
        let beforeAt = atIndex == prefix.startIndex ? nil : prefix[prefix.index(before: atIndex)]
        if let beforeAt, !beforeAt.isWhitespace { return nil }

        let queryStart = prefix.index(after: atIndex)
        let query = String(prefix[queryStart...])
        if query.contains(where: { $0.isWhitespace }) { return nil }
        return (atIndex ..< prefix.endIndex, query)
    }

    private func insertAgentMention(_ agent: OpenCodeAgent) {
        guard let match = currentAgentMentionMatch() else { return }
        let content = "@\(agent.name)"
        let start = text.utf16Offset(of: match.range.lowerBound)
        let end = start + content.utf16.count
        var next = text
        next.replaceSubrange(match.range, with: content + " ")
        setText(next)

        let mention = OpenCodeAgentMention(name: agent.name, content: content, start: start, end: end)
        var mentions = draftStore.agentMentions.filter { existing in
            existing.start != mention.start || existing.name != mention.name
        }
        mentions.append(mention)
        mentions.sort { $0.start < $1.start }
        setAgentMentions(OpenCodeAgentMention.reconciled(mentions, in: next))
        OpenCodeHaptics.impact(.soft)
    }

    private func reconcileAgentMentions() {
        let reconciled = OpenCodeAgentMention.reconciled(draftStore.agentMentions, in: text)
        guard reconciled != draftStore.agentMentions else { return }
        setAgentMentions(reconciled)
    }

    private func setAgentMentions(_ mentions: [OpenCodeAgentMention]) {
        guard draftStore.agentMentions != mentions else { return }
        draftStore.agentMentions = mentions
        onAgentMentionsChange(mentions)
    }

    private func setText(_ newValue: String) {
        guard draftStore.text != newValue else { return }
        draftStore.text = newValue
        onTextChange(newValue)
    }

#if canImport(PhotosUI) && canImport(UIKit)
    private var pastedImageHandler: ([UIImage]) -> Bool {
        { images in
            attachPastedImages(images)
        }
    }

    private func attachPastedImages(_ images: [UIImage]) -> Bool {
        let pastedImages = Array(images.prefix(AttachmentImportLimits.maxItemCount))
        guard !pastedImages.isEmpty else { return false }

        if isImportingAttachments {
            return true
        }

        isImportingAttachments = true
        defer { isImportingAttachments = false }

        let importResult = Self.makePastedImageAttachments(from: pastedImages)
        if !importResult.attachments.isEmpty {
            onAddAttachments(importResult.attachments)
            isAccessoryMenuOpen = false
        }
        if !importResult.skippedMessages.isEmpty {
            attachmentImportError = Self.skippedAttachmentMessage(importResult.skippedMessages)
        }

        return true
    }

    private func loadRecentPhotosIfAllowed() async {
        if isComposerActionsScreenshotScene {
            recentPhotoAssets = []
            recentPhotoThumbnails = [:]
            return
        }

        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let authorizedStatus: PHAuthorizationStatus

        if status == .notDetermined {
            authorizedStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            authorizedStatus = status
        }

        guard authorizedStatus == .authorized || authorizedStatus == .limited else {
            recentPhotoAssets = []
            recentPhotoThumbnails = [:]
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 12
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        recentPhotoAssets = assets
        await loadRecentPhotoThumbnails(for: assets)
    }

    private func loadRecentPhotoThumbnails(for assets: [PHAsset]) async {
        var thumbnails: [String: UIImage] = [:]

        for asset in assets {
            if let image = await requestThumbnail(for: asset) {
                thumbnails[asset.localIdentifier] = image
            }
        }

        recentPhotoThumbnails = thumbnails
    }

    private func requestThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded {
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func attachRecentPhoto(_ asset: PHAsset) {
        guard !isBusy, !isImportingAttachments else { return }
        Task {
            isImportingAttachments = true
            defer { isImportingAttachments = false }
            guard let attachment = await makeAttachment(from: asset) else { return }
            onAddAttachments([attachment])
            isAccessoryMenuOpen = false
        }
    }

    private func makeAttachment(from asset: PHAsset) async -> OpenCodeComposerAttachment? {
        guard let (data, uti) = await requestImageData(for: asset), !data.isEmpty else { return nil }
        let type = uti.flatMap(UTType.init) ?? .jpeg
        guard data.count <= AttachmentImportLimits.maxInlineBytes else {
            attachmentImportError = Self.attachmentTooLargeMessage(filename: String(localized: "Photo"), byteCount: data.count)
            return nil
        }

        return Self.imageAttachment(from: data, type: type)
    }

    private func requestImageData(for asset: PHAsset) async -> (Data, String?)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (data, uti))
            }
        }
    }

    private func loadSelectedPhotoItems() async {
        let items = selectedPhotoItems
        selectedPhotoItems = []
        guard !items.isEmpty else { return }

        isImportingAttachments = true
        defer { isImportingAttachments = false }
        var attachments: [OpenCodeComposerAttachment] = []
        var skippedMessages: [String] = []
        var totalBytes = 0

        for item in items.prefix(AttachmentImportLimits.maxItemCount) {
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { continue }
            guard data.count <= AttachmentImportLimits.maxInlineBytes else {
                skippedMessages.append(Self.attachmentTooLargeMessage(filename: String(localized: "Image"), byteCount: data.count))
                continue
            }
            guard totalBytes + data.count <= AttachmentImportLimits.maxTotalBytes else {
                skippedMessages.append(String(localized: "Some images were skipped because attachments are limited to \(Self.formattedByteCount(AttachmentImportLimits.maxTotalBytes)) per message."))
                break
            }

            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .png
            attachments.append(Self.imageAttachment(from: data, type: type))
            totalBytes += data.count
        }

        if !attachments.isEmpty {
            onAddAttachments(attachments)
            isAccessoryMenuOpen = false
        }
        if !skippedMessages.isEmpty {
            attachmentImportError = Self.skippedAttachmentMessage(skippedMessages)
        }
    }

    private func importSelectedFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, !urls.isEmpty, !isImportingAttachments else { return }

        let importURLs = Array(urls.prefix(AttachmentImportLimits.maxItemCount))
        isImportingAttachments = true
        Task {
            let importResult = await Task.detached(priority: .userInitiated) {
                Self.makeFileAttachments(from: importURLs)
            }.value

            isImportingAttachments = false
            if !importResult.attachments.isEmpty {
                onAddAttachments(importResult.attachments)
                isAccessoryMenuOpen = false
            }
            if !importResult.skippedMessages.isEmpty {
                attachmentImportError = Self.skippedAttachmentMessage(importResult.skippedMessages)
            }
        }
    }

    nonisolated private static func makePastedImageAttachments(from images: [UIImage]) -> (attachments: [OpenCodeComposerAttachment], skippedMessages: [String]) {
        var attachments: [OpenCodeComposerAttachment] = []
        var skippedMessages: [String] = []
        var totalBytes = 0

        for image in images {
            guard let encodedImage = encodedPasteImageData(from: image) else {
                skippedMessages.append(String(localized: "Pasted image could not be read."))
                continue
            }
            guard encodedImage.data.count <= AttachmentImportLimits.maxInlineBytes else {
                skippedMessages.append(attachmentTooLargeMessage(filename: String(localized: "Pasted image"), byteCount: encodedImage.data.count))
                continue
            }
            guard totalBytes + encodedImage.data.count <= AttachmentImportLimits.maxTotalBytes else {
                skippedMessages.append(String(localized: "Some images were skipped because attachments are limited to \(formattedByteCount(AttachmentImportLimits.maxTotalBytes)) per message."))
                break
            }

            attachments.append(imageAttachment(from: encodedImage.data, type: encodedImage.type))
            totalBytes += encodedImage.data.count
        }

        return (attachments, skippedMessages)
    }

    nonisolated private static func encodedPasteImageData(from image: UIImage) -> (data: Data, type: UTType)? {
        if let pngData = image.pngData(), pngData.count <= AttachmentImportLimits.maxInlineBytes {
            return (pngData, .png)
        }
        if let jpegData = image.jpegData(compressionQuality: 0.9) {
            return (jpegData, .jpeg)
        }
        if let pngData = image.pngData() {
            return (pngData, .png)
        }
        return nil
    }

    nonisolated private static func makeFileAttachments(from urls: [URL]) -> (attachments: [OpenCodeComposerAttachment], skippedMessages: [String]) {
        var attachments: [OpenCodeComposerAttachment] = []
        var skippedMessages: [String] = []
        var totalBytes = 0

        for url in urls {
            let filename = url.lastPathComponent
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            let values = try? url.resourceValues(forKeys: [.contentTypeKey, .fileSizeKey])
            if let fileSize = values?.fileSize, fileSize > AttachmentImportLimits.maxInlineBytes {
                skippedMessages.append(attachmentTooLargeMessage(filename: filename, byteCount: fileSize))
                continue
            }

            guard let data = try? Data(contentsOf: url, options: [.mappedIfSafe]), !data.isEmpty else {
                skippedMessages.append(String(localized: "\(filename) could not be read."))
                continue
            }
            guard data.count <= AttachmentImportLimits.maxInlineBytes else {
                skippedMessages.append(attachmentTooLargeMessage(filename: filename, byteCount: data.count))
                continue
            }
            guard totalBytes + data.count <= AttachmentImportLimits.maxTotalBytes else {
                skippedMessages.append(String(localized: "Some files were skipped because attachments are limited to \(formattedByteCount(AttachmentImportLimits.maxTotalBytes)) per message."))
                break
            }

            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
            guard let mime = fileAttachmentMimeType(for: type, filename: filename, data: data) else {
                skippedMessages.append(String(localized: "\(filename) is not a supported attachment type."))
                continue
            }
            let attachment = OpenCodeComposerAttachment(
                id: OpenCodeIdentifier.part(),
                kind: mime.lowercased().hasPrefix("image/") ? .image : .file,
                filename: filename,
                mime: mime,
                dataURL: "data:\(mime);base64,\(data.base64EncodedString())"
            )
            attachments.append(attachment)
            totalBytes += data.count
        }

        return (attachments, skippedMessages)
    }

    nonisolated private static func imageAttachment(from data: Data, type: UTType) -> OpenCodeComposerAttachment {
        let normalized = supportedImagePayload(from: data, type: type)
        let mime = normalized.mime
        let fileExtension = normalized.fileExtension
        let filename = "image-\(OpenCodeIdentifier.part()).\(fileExtension)"

        return OpenCodeComposerAttachment(
            id: OpenCodeIdentifier.part(),
            kind: .image,
            filename: filename,
            mime: mime,
            dataURL: "data:\(mime);base64,\(normalized.data.base64EncodedString())"
        )
    }

    nonisolated private static func supportedImagePayload(from data: Data, type: UTType) -> (data: Data, mime: String, fileExtension: String) {
        if let detected = detectedSupportedImageFormat(from: data) {
            return (data, detected.mime, detected.fileExtension)
        }

        let mime = (type.preferredMIMEType ?? "image/jpeg").lowercased()
        if supportedImageMIMETypes.contains(mime) {
            return (data, mime, type.preferredFilenameExtension ?? fileExtension(forSupportedImageMIME: mime))
        }

        if let jpegData = UIImage(data: data)?.jpegData(compressionQuality: 0.9) {
            return (jpegData, "image/jpeg", "jpg")
        }

        return (data, "image/jpeg", "jpg")
    }

    nonisolated private static let supportedImageMIMETypes: Set<String> = [
        "image/jpeg",
        "image/png",
        "image/gif",
        "image/webp",
    ]

    nonisolated private static func detectedSupportedImageFormat(from data: Data) -> (mime: String, fileExtension: String)? {
        let bytes = Array(data.prefix(12))
        if bytes.starts(with: [0xFF, 0xD8, 0xFF]) {
            return ("image/jpeg", "jpg")
        }
        if bytes.starts(with: [0x89, 0x50, 0x4E, 0x47]) {
            return ("image/png", "png")
        }
        if bytes.starts(with: [0x47, 0x49, 0x46, 0x38]) {
            return ("image/gif", "gif")
        }
        if bytes.count >= 12,
           bytes[0...3] == [0x52, 0x49, 0x46, 0x46],
           bytes[8...11] == [0x57, 0x45, 0x42, 0x50] {
            return ("image/webp", "webp")
        }
        return nil
    }

    nonisolated private static func fileExtension(forSupportedImageMIME mime: String) -> String {
        switch mime {
        case "image/png": return "png"
        case "image/gif": return "gif"
        case "image/webp": return "webp"
        default: return "jpg"
        }
    }

    nonisolated private static func attachmentTooLargeMessage(filename: String, byteCount: Int) -> String {
        String(localized: "\(filename) is \(formattedByteCount(byteCount)). Attachments must be under \(formattedByteCount(AttachmentImportLimits.maxInlineBytes)).")
    }

    nonisolated private static func skippedAttachmentMessage(_ messages: [String]) -> String {
        let visibleMessages = messages.prefix(3).joined(separator: "\n")
        if messages.count > 3 {
            return String(localized: "\(visibleMessages)\n\(messages.count - 3) more attachments were skipped.")
        }
        return visibleMessages
    }

    nonisolated private static func formattedByteCount(_ byteCount: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(byteCount), countStyle: .file)
    }

    nonisolated private static func defaultMimeType(for type: UTType) -> String {
        if type.conforms(to: .pdf) { return "application/pdf" }
        if type.conforms(to: .image) { return "image/png" }
        return "application/octet-stream"
    }

    nonisolated private static func fileAttachmentMimeType(for type: UTType, filename: String, data: Data) -> String? {
        let mime = (type.preferredMIMEType ?? defaultMimeType(for: type)).lowercased()

        if mime.hasPrefix("image/") { return mime }
        if mime == "application/pdf" { return mime }
        if isTextLikeMime(mime) || type.conforms(to: .plainText) || type.conforms(to: .text) {
            return "text/plain"
        }
        if isTextLikeFilename(filename) || isProbablyText(data) {
            return "text/plain"
        }
        return nil
    }

    nonisolated private static func isTextLikeMime(_ mime: String) -> Bool {
        if mime.hasPrefix("text/") { return true }
        if mime.hasSuffix("+json") || mime.hasSuffix("+xml") { return true }
        return [
            "application/json",
            "application/ld+json",
            "application/toml",
            "application/x-toml",
            "application/x-yaml",
            "application/xml",
            "application/yaml",
        ].contains(mime)
    }

    nonisolated private static func isTextLikeFilename(_ filename: String) -> Bool {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return [
            "c", "cc", "cjs", "conf", "cpp", "css", "csv", "cts", "env", "go", "gql", "graphql",
            "h", "hh", "hpp", "htm", "html", "ini", "java", "js", "json", "jsx", "log", "md",
            "mdx", "mjs", "mts", "py", "rb", "rs", "sass", "scss", "sh", "sql", "toml", "ts",
            "tsx", "txt", "xml", "yaml", "yml", "zsh",
        ].contains(ext)
    }

    nonisolated private static func isProbablyText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        let sample = data.prefix(4096)
        var controlByteCount = 0

        for byte in sample {
            if byte == 0 { return false }
            if byte < 9 || (byte > 13 && byte < 32) {
                controlByteCount += 1
            }
        }

        return Double(controlByteCount) / Double(sample.count) <= 0.3
    }
#endif
}

#if canImport(UIKit) && !canImport(PhotosUI)
private extension MessageComposer {
    var pastedImageHandler: ([UIImage]) -> Bool {
        { _ in false }
    }
}
#endif

#if canImport(UIKit)
private enum ComposerTextViewMetrics {
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 11
    static let initialContainerHeight: CGFloat = 48
    static let compactMinimumHeight: CGFloat = 40
    static let maxLines = 6

    static var minimumHeight: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        return max(initialContainerHeight, ceil(font.lineHeight + verticalInset * 2))
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let agentMentions: [OpenCodeAgentMention]
    let placeholder: LocalizedStringResource
    let maxLines: Int
    let canSubmit: Bool
    let autoFocus: Bool
    let onPasteImages: ([UIImage]) -> Bool
    let onSubmit: () -> Void
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ComposerPlaceholderTextView {
        let textView = ComposerPlaceholderTextView()
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(
            top: ComposerTextViewMetrics.verticalInset,
            left: ComposerTextViewMetrics.horizontalInset,
            bottom: ComposerTextViewMetrics.verticalInset,
            right: ComposerTextViewMetrics.horizontalInset
        )
        textView.returnKeyType = .default
        textView.keyboardDismissMode = .interactive
        textView.placeholder = String(localized: placeholder)
        textView.canSubmit = canSubmit
        textView.onPasteImages = onPasteImages
        textView.onSubmit = onSubmit
        textView.applyText(text, agentMentions: agentMentions)
        textView.updatePlaceholderVisibility()
        textView.isEditable = true
        textView.isSelectable = true
        context.coordinator.requestAutoFocusIfNeeded(on: textView)
        return textView
    }

    func updateUIView(_ textView: ComposerPlaceholderTextView, context: Context) {
        context.coordinator.parent = self
        var needsLayoutUpdate = false

        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        if textView.font != bodyFont {
            textView.font = bodyFont
            textView.updatePlaceholderFont()
            textView.invalidateFittingCache()
            needsLayoutUpdate = true
        }

        if textView.maximumLineCount != maxLines {
            textView.maximumLineCount = maxLines
            textView.invalidateFittingCache()
            needsLayoutUpdate = true
        }

        if textView.text != text {
            textView.applyText(text, agentMentions: agentMentions)
            textView.updatePlaceholderVisibility()
            needsLayoutUpdate = true
        } else if textView.applyMentionHighlighting(agentMentions: agentMentions) {
            needsLayoutUpdate = true
        }

        let localizedPlaceholder = String(localized: placeholder)
        if textView.placeholder != localizedPlaceholder {
            textView.placeholder = localizedPlaceholder
            needsLayoutUpdate = true
        }

        textView.canSubmit = canSubmit
        textView.onPasteImages = onPasteImages
        textView.onSubmit = onSubmit
        context.coordinator.requestAutoFocusIfNeeded(on: textView)

        guard needsLayoutUpdate else { return }

        textView.invalidateIntrinsicContentSize()
        textView.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerPlaceholderTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = uiView.fittedHeight(width: width, maxLines: maxLines)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView
        private var didCompleteAutoFocus = false
        private var isAutoFocusPending = false
        private var autoFocusAttemptCount = 0

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func requestAutoFocusIfNeeded(on textView: ComposerPlaceholderTextView) {
            guard parent.autoFocus, !didCompleteAutoFocus, !isAutoFocusPending, autoFocusAttemptCount < 6 else { return }
            isAutoFocusPending = true
            autoFocusAttemptCount += 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self, weak textView] in
                guard let self else { return }
                self.isAutoFocusPending = false
                guard self.parent.autoFocus else { return }
                guard let textView, !textView.isFirstResponder else { return }
                guard textView.window != nil, textView.becomeFirstResponder() else {
                    self.requestAutoFocusIfNeeded(on: textView)
                    return
                }
                self.didCompleteAutoFocus = true
            }
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text {
                parent.text = textView.text
            }

            guard let textView = textView as? ComposerPlaceholderTextView else { return }
            textView.invalidateFittingCache()
            _ = textView.applyMentionHighlighting(agentMentions: parent.agentMentions)
            textView.updatePlaceholderVisibility()
            textView.invalidateIntrinsicContentSize()
        }
    }
}

final class ComposerPlaceholderTextView: UITextView {
    private struct FittingCache {
        let width: CGFloat
        let maxLines: Int
        let font: UIFont
        let height: CGFloat
        let isScrollEnabled: Bool
    }

    private let placeholderLabel = UILabel()
    private var fittingCache: FittingCache?
    private var highlightedText: String?
    private var highlightedMentions: [OpenCodeAgentMention] = []
    private var highlightedFont: UIFont?
    var maximumLineCount = ComposerTextViewMetrics.maxLines
    var canSubmit = false
    var onPasteImages: (([UIImage]) -> Bool)?
    var onSubmit: (() -> Void)?

    var placeholder: String = "" {
        didSet {
            placeholderLabel.text = placeholder
            updatePlaceholderVisibility()
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = textContainerInset.left
        let y = textContainerInset.top
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        placeholderLabel.frame = CGRect(x: x, y: y, width: width, height: placeholderLabel.intrinsicContentSize.height)
    }

    func updatePlaceholderFont() {
        placeholderLabel.font = font
        setNeedsLayout()
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    func fittedHeight(width: CGFloat, maxLines: Int) -> CGFloat {
        let currentFont = font ?? UIFont.preferredFont(forTextStyle: .body)
        if let fittingCache,
           abs(fittingCache.width - width) <= 0.5,
           fittingCache.maxLines == maxLines,
           fittingCache.font.isEqual(currentFont) {
            if isScrollEnabled != fittingCache.isScrollEnabled {
                isScrollEnabled = fittingCache.isScrollEnabled
            }
            return fittingCache.height
        }

        let target = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let measuredHeight = sizeThatFits(target).height
        let lineHeight = currentFont.lineHeight
        let minHeight = ceil(lineHeight + textContainerInset.top + textContainerInset.bottom)
        let maxHeight = ceil(lineHeight * CGFloat(max(1, maxLines)) + textContainerInset.top + textContainerInset.bottom)
        let height = min(max(measuredHeight, minHeight), maxHeight)
        let shouldScroll = measuredHeight > maxHeight + 0.5

        fittingCache = FittingCache(
            width: width,
            maxLines: maxLines,
            font: currentFont,
            height: height,
            isScrollEnabled: shouldScroll
        )
        if isScrollEnabled != shouldScroll {
            isScrollEnabled = shouldScroll
        }
        return height
    }

    func invalidateFittingCache() {
        fittingCache = nil
    }

    func applyText(_ text: String, agentMentions: [OpenCodeAgentMention]) {
        self.text = text
        invalidateFittingCache()
        _ = applyMentionHighlighting(agentMentions: agentMentions)
    }

    @discardableResult
    func applyMentionHighlighting(agentMentions: [OpenCodeAgentMention]) -> Bool {
        guard markedTextRange == nil else {
            highlightedText = nil
            highlightedMentions = []
            highlightedFont = nil
            return false
        }

        let previousSelectedRange = selectedRange
        let currentText = text ?? ""
        let font = font ?? UIFont.preferredFont(forTextStyle: .body)
        let reconciledMentions = OpenCodeAgentMention.reconciled(agentMentions, in: currentText)
        let fontMatches = highlightedFont?.isEqual(font) == true

        guard highlightedText != currentText || highlightedMentions != reconciledMentions || !fontMatches else {
            return false
        }

        if agentMentions.isEmpty, highlightedMentions.isEmpty, highlightedFont == nil || fontMatches {
            highlightedText = currentText
            highlightedFont = font
            typingAttributes = [
                .font: font,
                .foregroundColor: UIColor.label,
            ]
            return false
        }

        let attributed = NSMutableAttributedString(
            string: currentText,
            attributes: [
                .font: font,
                .foregroundColor: UIColor.label,
            ]
        )

        for mention in reconciledMentions {
            guard let range = currentText.rangeFromUTF16Offsets(start: mention.start, end: mention.end) else { continue }
            let nsRange = NSRange(range, in: currentText)
            attributed.addAttributes(
                [
                    .foregroundColor: UIColor.systemIndigo,
                    .backgroundColor: UIColor.systemIndigo.withAlphaComponent(0.14),
                    .font: font.bold(),
                ],
                range: nsRange
            )
        }

        highlightedText = currentText
        highlightedMentions = reconciledMentions
        highlightedFont = font

        let didChange = attributedText.string != currentText || !attributedText.isEqual(to: attributed)
        if didChange {
            attributedText = attributed
            selectedRange = previousSelectedRange
            invalidateFittingCache()
        }
        typingAttributes = [
            .font: font,
            .foregroundColor: UIColor.label,
        ]
        return didChange
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -8).contains(point)
    }

    override var keyCommands: [UIKeyCommand]? {
        var commands = [UIKeyCommand]()

        let submitCommand = UIKeyCommand(
            title: "",
            action: #selector(submitIfPossible),
            input: "\r",
            modifierFlags: []
        )
        commands.append(submitCommand)

        let submitEnterCommand = UIKeyCommand(
            title: "",
            action: #selector(submitIfPossible),
            input: "\n",
            modifierFlags: []
        )
        commands.append(submitEnterCommand)

        let newlineCommand = UIKeyCommand(
            title: "",
            action: #selector(insertShiftNewline),
            input: "\r",
            modifierFlags: .shift
        )
        commands.append(newlineCommand)

        return commands
    }

    @objc private func submitIfPossible() {
        guard canSubmit else { return }
        onSubmit?()
    }

    @objc private func insertShiftNewline() {
        insertText("\n")
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        guard
            presses.contains(where: { press in
                guard let key = press.key else { return false }
                let characters = key.charactersIgnoringModifiers
                let isReturn = key.keyCode == .keyboardReturnOrEnter || characters == "\r" || characters == "\n"
                return isReturn && !key.modifierFlags.contains(.shift)
            })
        else {
            super.pressesBegan(presses, with: event)
            return
        }

        if canSubmit {
            onSubmit?()
        }
    }

    override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
        if action == #selector(paste(_:)), UIPasteboard.general.hasImages {
            return true
        }
        return super.canPerformAction(action, withSender: sender)
    }

    override func paste(_ sender: Any?) {
        if let images = UIPasteboard.general.images, !images.isEmpty, onPasteImages?(images) == true {
            return
        }
        super.paste(sender)
    }

    private func setupPlaceholder() {
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = font ?? UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }
}

private extension UIFont {
    func bold() -> UIFont {
        guard let descriptor = fontDescriptor.withSymbolicTraits(.traitBold) else { return self }
        return UIFont(descriptor: descriptor, size: pointSize)
    }
}

#endif

private struct CommandPicker: View {
    let commands: [OpenCodeCommand]
    let selectedCommandName: String?
    let pinnedCommandNames: Set<String>
    let onSelect: (OpenCodeCommand) -> Void
    let onPin: (OpenCodeCommand) -> Void
    let onUnpin: (OpenCodeCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: "hand.tap")
                    .font(.caption.weight(.semibold))
                Text("Hold for more options")
                    .font(.caption.weight(.medium))
            }
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, commands.isEmpty ? 0 : 4)

            if commands.isEmpty {
                Text("No matching commands")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(commands) { command in
                            Button {
                                onSelect(command)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    HStack(spacing: 1) {
                                        Text("/")
                                            .foregroundStyle(.secondary.opacity(0.7))
                                        Text(command.name)
                                            .foregroundStyle(.primary)
                                    }
                                    .font(.subheadline.weight(.semibold))

                                    if let description = command.description, !description.isEmpty {
                                        Text(description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineLimit(1)
                                    } else {
                                        Spacer(minLength: 0)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(command.name == selectedCommandName ? Color.primary.opacity(0.08) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .contextMenu {
                                if pinnedCommandNames.contains(command.name) {
                                    Button {
                                        onUnpin(command)
                                    } label: {
                                        Label("Unpin", systemImage: "pin.slash")
                                    }
                                } else {
                                    Button {
                                        onPin(command)
                                    } label: {
                                        Label("Pin", systemImage: "pin")
                                    }
                                }
                            }
                            .accessibilityIdentifier("chat.command.\(command.name)")
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 220)
            }
        }
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct AgentMentionPicker: View {
    let agents: [OpenCodeAgent]
    let onSelect: (OpenCodeAgent) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Label("Sub agents", systemImage: "brain.head.profile")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, agents.isEmpty ? 0 : 4)

            if agents.isEmpty {
                Text("No matching agents")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(agents) { agent in
                            Button {
                                onSelect(agent)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("@\(agent.name)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    if let description = agent.description, !description.isEmpty {
                                        Text(description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineLimit(1)
                                    } else {
                                        Spacer(minLength: 0)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(Color.primary.opacity(0.05))
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chat.agentMention.\(agent.name)")
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 220)
            }
        }
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct PinnedCommandStrip: View {
    let commands: [OpenCodeCommand]
    let onSelect: (OpenCodeCommand) -> Void
    let onUnpin: (OpenCodeCommand) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(commands) { command in
                    Button {
                        onSelect(command)
                    } label: {
                        HStack(spacing: 1) {
                            Text("/")
                                .foregroundStyle(.secondary.opacity(0.7))
                            Text(command.name)
                                .foregroundStyle(.primary)
                        }
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(.thinMaterial, in: Capsule())
                        .overlay {
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 1)
                        }
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        Button {
                            onUnpin(command)
                        } label: {
                            Label("Unpin", systemImage: "pin.slash")
                        }
                    }
                    .accessibilityIdentifier("chat.pinned-command.\(command.name)")
                }
            }
            .padding(.horizontal, 16)
        }
        .scrollClipDisabled()
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, -12)
    }
}

private struct AccessoryMenuAction: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    var accessibilityIdentifier = "chat.composer.commands"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccessoryMenuLabel(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint, isDisabled: isDisabled)
        }
        .accessoryOptionButtonStyle()
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct AccessorySectionTitle: View {
    let title: LocalizedStringResource

    init(_ title: LocalizedStringResource) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .tracking(0.6)
            .padding(.top, 6)
            .padding(.horizontal, 2)
    }
}

private struct AccessoryMenuLabel: View {
    let title: LocalizedStringResource
    let subtitle: LocalizedStringResource
    let systemImage: String
    let tint: Color
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isDisabled ? .secondary : tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(isDisabled ? .secondary : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(isDisabled ? 0.02 : 0.07), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ComposerForkListView: View {
    let messages: [OpenCodeForkableMessage]
    let onForkMessage: (String) -> Void

    @State private var searchText = ""

    private var filteredMessages: [OpenCodeForkableMessage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return messages }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if filteredMessages.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? LocalizedStringResource("No User Messages") : LocalizedStringResource("No Matches"),
                    systemImage: "arrow.triangle.branch",
                    description: Text(searchText.isEmpty ? LocalizedStringResource("Send a message before forking this session.") : LocalizedStringResource("Try a different search."))
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredMessages) { message in
                    Button {
                        onForkMessage(message.id)
                    } label: {
                        ComposerForkMessageRow(message: message)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.fork.message.\(message.id)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .opencodeSoftScrollEdgeEffect()
        .navigationTitle("Fork Session")
        .opencodeInlineNavigationTitle()
        .searchable(text: $searchText, prompt: "Search messages")
    }
}

private struct ComposerForkMessageRow: View {
    let message: OpenCodeForkableMessage

    private var timeLabel: String {
        guard let created = message.created else { return "" }
        let date = Date(timeIntervalSince1970: created > 100_000_000_000 ? created / 1000 : created)
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !timeLabel.isEmpty {
                    Text(timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.triangle.branch")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
}

private struct ComposerMCPListView: View {
    let servers: [OpenCodeMCPServer]
    let connectedCount: Int
    let isLoading: Bool
    let togglingServerNames: Set<String>
    let errorMessage: String?
    let onLoad: () -> Void
    let onToggle: (String) -> Void

    @State private var searchText = ""

    private var filteredServers: [OpenCodeMCPServer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return servers }
        return servers.filter { server in
            server.name.localizedCaseInsensitiveContains(query) || server.status.displayStatus.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MCP Servers")
                            .font(.headline)
                        Text("\(connectedCount) of \(servers.count) enabled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if isLoading {
                        ProgressView()
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Servers") {
                if isLoading && servers.isEmpty {
                    ProgressView("Loading MCP servers")
                } else if filteredServers.isEmpty {
                    Text(servers.isEmpty ? LocalizedStringResource("No configured MCP servers.") : LocalizedStringResource("No MCP servers match your search."))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredServers) { server in
                        ComposerMCPServerRow(
                            server: server,
                            isToggling: togglingServerNames.contains(server.name),
                            onToggle: { onToggle(server.name) }
                        )
                    }
                }
            }
        }
        .opencodeGroupedListStyle()
        .opencodeSoftScrollEdgeEffect()
        .searchable(text: $searchText, prompt: "Search MCP servers")
        .navigationTitle("MCP")
        .opencodeInlineNavigationTitle()
        .task {
            onLoad()
        }
        .animation(opencodeSelectionAnimation, value: servers.map(\.id).joined(separator: "|"))
        .animation(opencodeSelectionAnimation, value: togglingServerNames)
    }
}

private struct ComposerMCPServerRow: View {
    let server: OpenCodeMCPServer
    let isToggling: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Text(server.status.displayStatus)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                if let error = server.status.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if isToggling {
                ProgressView()
            }

            Toggle("Enabled", isOn: Binding(
                get: { server.status.isConnected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(isToggling)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isToggling else { return }
            onToggle()
        }
    }

    private var statusColor: Color {
        switch server.status.status {
        case "connected":
            return .green
        case "failed", "needs_client_registration":
            return .red
        case "needs_auth":
            return .orange
        default:
            return .secondary
        }
    }
}

private extension View {
    @ViewBuilder
    func composerPlusButtonStyle() -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.1, *) {
            buttonStyle(.glass(.regular))
                .buttonBorderShape(.circle)
        } else {
            buttonStyle(.plain)
                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        #else
        buttonStyle(.plain)
            .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        #endif
    }

    @ViewBuilder
    func accessoryOptionButtonStyle() -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.1, *) {
            buttonStyle(.glass(.regular))
                .buttonBorderShape(.roundedRectangle(radius: 18))
        } else {
            buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 18))
        }
        #else
        buttonStyle(.bordered)
        #endif
    }
}
