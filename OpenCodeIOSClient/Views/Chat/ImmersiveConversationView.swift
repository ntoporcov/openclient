import SwiftUI

struct ImmersiveConversationView: View {
    let state: ConversationModeController.State
    let inputMode: ConversationModeController.InputMode
    let inputLevel: CGFloat
    let inputPitch: CGFloat
    let isSpeakingFiller: Bool
    let isSendHeld: Bool
    let isMuted: Bool
    let transcript: String
    let showsBackdrop: Bool
    let onStop: () -> Void
    let onToggleHold: () -> Void
    let onToggleMute: () -> Void
    let onBeginHold: () -> Void
    let onEndHold: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPressingOrb = false
    @State private var hasActivatedMicrophone = false

    private var usesHoldToTalk: Bool {
        inputMode == .holdToTalk
    }

    private var canPressOrb: Bool {
        usesHoldToTalk && (state == .ready || state == .speakingResponse)
    }

    private var orbAccessibilityLabel: LocalizedStringResource {
        usesHoldToTalk ? "Hold to Talk" : "Voice Conversation"
    }

    private var orbAccessibilityHint: LocalizedStringResource {
        usesHoldToTalk
            ? "Press and hold while speaking. Release to send."
            : "The conversation listens and sends automatically."
    }

    private var holdAccessibilityValue: LocalizedStringResource {
        isSendHeld ? "On" : "Off"
    }

    private var muteAccessibilityValue: LocalizedStringResource {
        isMuted ? "On" : "Off"
    }

    var body: some View {
        GeometryReader { geometry in
            let orbSize = min(min(geometry.size.width * 0.78, geometry.size.height * 0.42), 320)

            ZStack {
                if showsBackdrop {
                    ConversationBackdropView()
                }

                VStack(spacing: min(geometry.size.height * 0.065, 52)) {
                    TimelineView(.animation(minimumInterval: 1 / 30, paused: reduceMotion)) { timeline in
                        let time = timeline.date.timeIntervalSinceReferenceDate
                        conversationOrb(
                            size: orbSize,
                            isAssistant: isAssistantTurn,
                            waveformLevel: activeWaveformLevel(at: time)
                        )
                    }
                    .frame(width: orbSize, height: orbSize)

                    VStack(spacing: 18) {
                        HStack(spacing: 24) {
                            stopButton
                            muteButton
                            holdButton
                        }
                        .allowsHitTesting(true)
                        .modifier(ConversationControlsEntranceModifier())

                        CapturedSpeechTranscriptView(transcript: transcript)
                            .frame(maxWidth: 430)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 24)
                .padding(.bottom, geometry.safeAreaInsets.bottom)
            }
        }
        .ignoresSafeArea()
        .onChange(of: usesHoldToTalk) { _, isEnabled in
            if !isEnabled {
                endOrbPress()
            }
        }
        .onChange(of: state) { _, newState in
            if newState == .listening {
                hasActivatedMicrophone = true
            }
            if isPressingOrb, newState != .starting, newState != .listening {
                isPressingOrb = false
            }
        }
        .onAppear {
            guard state == .listening else { return }
            hasActivatedMicrophone = false
            Task { @MainActor in
                await Task.yield()
                hasActivatedMicrophone = true
            }
        }
        .accessibilityIdentifier("chat.conversation.immersive")
    }

    @ViewBuilder
    private func conversationOrb(
        size: CGFloat,
        isAssistant: Bool,
        waveformLevel: CGFloat
    ) -> some View {
        let orb = conversationGlassGroup(
            size: size,
            isAssistant: isAssistant,
            waveformLevel: waveformLevel
        )
        .accessibilityElement()
        .accessibilityLabel(orbAccessibilityLabel)
        .accessibilityHint(orbAccessibilityHint)

        if usesHoldToTalk {
            orb
                .contentShape(Circle())
                .gesture(holdGesture)
        } else {
            orb.allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func conversationGlassGroup(
        size: CGFloat,
        isAssistant: Bool,
        waveformLevel: CGFloat
    ) -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            ZStack {
                GlassEffectContainer(spacing: 5) {
                    SilenceSendIndicator(
                        orbSize: size,
                        conversationState: state
                    )
                }

                conversationOrbVisual(
                    size: size,
                    isAssistant: isAssistant,
                    waveformLevel: waveformLevel
                )
            }
            .frame(width: size, height: size)
        } else {
            conversationGlassContent(
                size: size,
                isAssistant: isAssistant,
                waveformLevel: waveformLevel
            )
        }
        #else
        conversationGlassContent(
            size: size,
            isAssistant: isAssistant,
            waveformLevel: waveformLevel
        )
        #endif
    }

    private func conversationOrbVisual(
        size: CGFloat,
        isAssistant: Bool,
        waveformLevel: CGFloat
    ) -> some View {
        ConversationOrbView(
            waveformLevel: waveformLevel,
            isAssistant: isAssistant,
            isPressed: isPressingOrb,
            activationScale: hasActivatedMicrophone ? 1 : 0.24
        )
        .frame(width: size, height: size)
        .scaleEffect(isPressingOrb ? 0.95 : 1)
    }

    private func conversationGlassContent(
        size: CGFloat,
        isAssistant: Bool,
        waveformLevel: CGFloat
    ) -> some View {
        ZStack {
            conversationOrbVisual(
                size: size,
                isAssistant: isAssistant,
                waveformLevel: waveformLevel
            )

            SilenceSendIndicator(
                orbSize: size,
                conversationState: state
            )
        }
        .frame(width: size, height: size)
    }

    private var stopButton: some View {
        Button {
            endOrbPress()
            OpenCodeHaptics.impact(.soft)
            onStop()
        } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opencodeActionGlass(tint: Color.red.opacity(0.64), size: 64, in: Circle())
        .contentShape(Circle())
        .shadow(color: .red.opacity(0.18), radius: 16, y: 8)
        .accessibilityLabel("Stop Conversation")
        .accessibilityIdentifier("chat.conversation.immersive.stop")
    }

    private var holdButton: some View {
        Button {
            endOrbPress()
            OpenCodeHaptics.impact(.soft)
            onToggleHold()
        } label: {
            Text("Hold")
                .font(.caption.weight(.bold))
                .foregroundStyle(isSendHeld ? .white : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opencodeActionGlass(
            clear: true,
            tint: isSendHeld ? Color.accentColor.opacity(0.82) : OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.72),
            size: 64,
            in: Circle()
        )
        .contentShape(Circle())
        .accessibilityLabel("Hold Sending")
        .accessibilityValue(holdAccessibilityValue)
        .accessibilityHint("Prevents silence from sending the current message while continuing to listen.")
        .accessibilityIdentifier("chat.conversation.hold")
    }

    private var muteButton: some View {
        Button {
            endOrbPress()
            OpenCodeHaptics.impact(.soft)
            onToggleMute()
        } label: {
            Image(systemName: isMuted ? "mic.slash.fill" : "mic.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isMuted ? .white : .primary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .opencodeActionGlass(
            clear: true,
            tint: isMuted ? Color.orange.opacity(0.76) : OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.72),
            size: 64,
            in: Circle()
        )
        .contentShape(Circle())
        .accessibilityLabel("Mute Microphone")
        .accessibilityValue(muteAccessibilityValue)
        .accessibilityIdentifier("chat.conversation.mute")
    }

    private var holdGesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard canPressOrb, !isPressingOrb else { return }
                isPressingOrb = true
                OpenCodeHaptics.impact(.soft)
                onBeginHold()
            }
            .onEnded { _ in
                endOrbPress()
            }
    }

    private func endOrbPress() {
        guard isPressingOrb else { return }
        isPressingOrb = false
        onEndHold()
    }

    private var isAssistantTurn: Bool {
        isSpeakingFiller || state == .waitingForResponse || state == .speakingResponse
    }

    private func activeWaveformLevel(at time: TimeInterval) -> CGFloat {
        isAssistantTurn ? assistantWaveformLevel(at: time) : userWaveformLevel
    }

    private var userWaveformLevel: CGFloat {
        let loudness = min(1, sqrt(max(inputLevel, 0)) * 1.15)
        let pitch = min(max(inputPitch, 0), 1)
        return min(1, loudness * 0.52 + pitch * 0.48)
    }

    private func assistantWaveformLevel(at time: TimeInterval) -> CGFloat {
        if isSpeakingFiller || state == .speakingResponse {
            return CGFloat(0.22 + 0.78 * abs(sin(time * 3.1) * cos(time * 1.7)))
        }
        return state == .waitingForResponse ? 0.08 : 0.03
    }
}

struct TalkSessionOverlay: View {
    @ObservedObject var coordinator: TalkSessionCoordinator
    @ObservedObject private var conversationController: ConversationModeController

    init(coordinator: TalkSessionCoordinator) {
        self.coordinator = coordinator
        _conversationController = ObservedObject(wrappedValue: coordinator.conversationController)
    }

    var body: some View {
        ZStack {
            if coordinator.isChoosingProject || conversationController.state != .paused {
                ConversationBackdropView()
            }

            Group {
                if coordinator.isChoosingProject {
                    TalkProjectSelectionView(
                        projects: coordinator.projects,
                        title: coordinator.projectTitle,
                        onSelect: coordinator.selectProject,
                        onStop: coordinator.stop
                    )
                } else if conversationController.state != .paused {
                    ImmersiveConversationView(
                        state: conversationController.state,
                        inputMode: conversationController.inputMode,
                        inputLevel: conversationController.inputLevel,
                        inputPitch: conversationController.inputPitch,
                        isSpeakingFiller: conversationController.isSpeakingFiller,
                        isSendHeld: conversationController.isSendHeld,
                        isMuted: conversationController.isMuted,
                        transcript: conversationController.transcript,
                        showsBackdrop: false,
                        onStop: coordinator.stop,
                        onToggleHold: conversationController.toggleSendHold,
                        onToggleMute: conversationController.toggleMute,
                        onBeginHold: conversationController.beginHoldToTalk,
                        onEndHold: conversationController.endHoldToTalk
                    )
                } else {
                    Color.clear
                        .allowsHitTesting(false)
                }
            }
            .alert(
                "Dictation Unavailable",
                isPresented: Binding(
                    get: { conversationController.errorMessage != nil },
                    set: { isPresented in
                        if !isPresented {
                            conversationController.errorMessage = nil
                        }
                    }
                )
            ) {
                Button("OK", role: .cancel) {
                    conversationController.errorMessage = nil
                    coordinator.stop()
                }
            } message: {
                Text(conversationController.errorMessage ?? "")
            }
        }
    }
}

private struct TalkProjectSelectionView: View {
    let projects: [OpenCodeProject]
    let title: (OpenCodeProject) -> String
    let onSelect: (OpenCodeProject) -> Void
    let onStop: () -> Void

    private let columns = [GridItem(.adaptive(minimum: 132, maximum: 180), spacing: 12)]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                VStack(spacing: 18) {
                    ConversationOrbView(
                        waveformLevel: 0.05,
                        isAssistant: true,
                        isPressed: false,
                        activationScale: 1
                    )
                    .frame(width: 132, height: 132)
                    .accessibilityHidden(true)

                    VStack(spacing: 6) {
                        Text("Select a Project")
                            .font(.title2.weight(.semibold))
                        Text("Select where this voice conversation should begin.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }

                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(projects) { project in
                                Button {
                                    OpenCodeHaptics.impact(.soft)
                                    onSelect(project)
                                } label: {
                                    VStack(spacing: 10) {
                                        ProjectAvatar(
                                            title: title(project),
                                            systemImage: project.id == "global" ? "globe" : "folder.fill",
                                            icon: project.icon,
                                            usesSystemImageFallback: project.id == "global",
                                            isSelected: false,
                                            size: 48
                                        )
                                        Text(title(project))
                                            .font(.subheadline.weight(.semibold))
                                            .foregroundStyle(.primary)
                                            .lineLimit(2)
                                            .multilineTextAlignment(.center)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .frame(minHeight: 116)
                                    .padding(12)
                                    .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                                    .opencodeConcentricGlassSurface(
                                        isInteractive: true,
                                        minimumCornerRadius: 20,
                                        in: RoundedRectangle(cornerRadius: 20, style: .continuous)
                                    )
                                }
                                .buttonStyle(.plain)
                                .accessibilityIdentifier("talk.project.\(project.id)")
                            }
                        }
                        .padding(.horizontal, 24)
                        .padding(.vertical, 20)
                    }
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black, location: 0.08),
                                .init(color: .black, location: 0.92),
                                .init(color: .clear, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                    .frame(maxWidth: 640, maxHeight: min(geometry.size.height * 0.5, 440))

                    Button(action: onStop) {
                        Image(systemName: "xmark")
                            .font(.system(size: 17, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    .opencodeActionGlass(tint: Color.red.opacity(0.58), size: 56, in: Circle())
                    .contentShape(Circle())
                    .accessibilityLabel("Stop Conversation")
                    .modifier(ConversationControlsEntranceModifier())
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.top, geometry.safeAreaInsets.top + 12)
                .padding(.bottom, geometry.safeAreaInsets.bottom + 12)
            }
        }
        .ignoresSafeArea()
        .accessibilityIdentifier("talk.projectPicker")
    }
}

private struct SilenceSendIndicator: View {
    private enum Phase: Hashable {
        case idle
        case countdown
        case sending
    }

    let orbSize: CGFloat
    let conversationState: ConversationModeController.State

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealedDotCount = 0
    @State private var isAbsorbing = false
    @State private var isActive = false

    private static let dotCount = 4
    private let absorptionOrder = [0, 3, 1, 2]

    private var phase: Phase {
        switch conversationState {
        case .waitingToSend:
            .countdown
        case .finalizing, .submitting, .waitingForResponse:
            .sending
        default:
            .idle
        }
    }

    var body: some View {
        ZStack {
            ForEach(0 ..< Self.dotCount, id: \.self) { index in
                let horizontalOffset = (CGFloat(index) - CGFloat(Self.dotCount - 1) / 2) * 16
                let isRevealed = index < revealedDotCount
                let isAbsorbed = isAbsorbing && isRevealed
                glassDot
                    .frame(width: 9, height: 9)
                    .offset(
                        x: isAbsorbed ? 0 : horizontalOffset,
                        y: isAbsorbed ? 0 : orbSize * 0.58
                    )
                    .scaleEffect(isRevealed ? (isAbsorbed ? 0.08 : 1) : 0.45)
                    .opacity(isActive && isRevealed && !isAbsorbed ? 1 : 0)
                    .animation(
                        reduceMotion
                            ? nil
                            : .easeIn(duration: 0.46).delay(absorptionDelay(for: index)),
                        value: isAbsorbing
                    )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: phase) {
            switch phase {
            case .countdown:
                await revealDots()
            case .sending:
                await absorbDots()
            case .idle:
                dismissDots()
            }
        }
    }

    private func revealDots() async {
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            revealedDotCount = 0
            isAbsorbing = false
            isActive = true
        }

        for count in 1 ... Self.dotCount {
            try? await Task.sleep(
                for: .seconds(
                    ConversationModeController.automaticSendGracePeriod / Double(Self.dotCount + 1)
                )
            )
            guard !Task.isCancelled else { return }
            if reduceMotion {
                revealedDotCount = count
            } else {
                withAnimation(.spring(duration: 0.28, bounce: 0.2)) {
                    revealedDotCount = count
                }
            }
        }
    }

    private func absorbDots() async {
        guard isActive, revealedDotCount > 0 else { return }
        if reduceMotion {
            isAbsorbing = true
            isActive = false
            return
        }

        isAbsorbing = true
        try? await Task.sleep(for: .milliseconds(980))
        guard !Task.isCancelled else { return }
        isActive = false
    }

    private func absorptionDelay(for index: Int) -> TimeInterval {
        let position = absorptionOrder.firstIndex(of: index) ?? index
        return Double(position) * 0.105
    }

    private func dismissDots() {
        guard isActive else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
            isActive = false
        }
    }

    @ViewBuilder
    private var glassDot: some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            Circle()
                .fill(Color.clear)
                .glassEffect(.clear, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
        #else
        Circle().fill(.ultraThinMaterial)
        #endif
    }
}

private struct ConversationBackdropView: View {
    @State private var isVisible = false

    var body: some View {
        glassLayers
            .opacity(isVisible ? 1 : 0)
            .ignoresSafeArea()
            .task {
                await Task.yield()
                withAnimation(.easeOut(duration: 0.32)) {
                    isVisible = true
                }
            }
    }

    @ViewBuilder
    private var glassLayers: some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            ZStack {
                materialLayer(opacity: 0.6)

                Rectangle()
                    .fill(Color.clear)
                    .glassEffect(.regular, in: Rectangle())
                    .mask {
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.08),
                                .init(color: .black.opacity(0.18), location: 0.34),
                                .init(color: .black.opacity(0.68), location: 0.68),
                                .init(color: .black, location: 1),
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
            }
        } else {
            materialLayer(opacity: 0.8)
        }
        #else
        materialLayer(opacity: 0.8)
        #endif
    }

    private func materialLayer(opacity: Double) -> some View {
        Rectangle()
            .fill(.regularMaterial)
            .opacity(opacity)
            .mask {
                LinearGradient(
                    colors: [.black.opacity(0.6), .black],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
    }
}

private struct ConversationControlsEntranceModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    func body(content: Content) -> some View {
        content
            .opacity(isVisible ? 1 : 0)
            .offset(y: reduceMotion || isVisible ? 0 : 24)
            .allowsHitTesting(isVisible)
            .task {
                await Task.yield()
                if reduceMotion {
                    isVisible = true
                    return
                }

                try? await Task.sleep(for: .milliseconds(150))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.3)) {
                    isVisible = true
                }
            }
    }
}

private struct CapturedSpeechTranscriptView: View {
    private struct Word: Identifiable {
        let id = UUID()
        var text: String
        let revealDelay: TimeInterval
    }

    private static let bottomAnchorID = "captured-speech-bottom"

    let transcript: String

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var words: [Word] = []

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    TranscriptFlowLayout(itemSpacing: 5, lineSpacing: 7) {
                        ForEach(words) { word in
                            CapturedSpeechWordView(
                                text: word.text,
                                revealDelay: word.revealDelay
                            )
                            .id(word.id)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
                    .padding(.top, 22)
                    .padding(.bottom, 6)

                    Color.clear
                        .frame(height: 1)
                        .id(Self.bottomAnchorID)
                }
            }
            .scrollIndicators(.hidden)
            .mask {
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0),
                        .init(color: .black.opacity(0.42), location: 0.08),
                        .init(color: .black, location: 0.20),
                        .init(color: .black, location: 1),
                    ],
                    startPoint: .top,
                    endPoint: .bottom
                )
            }
            .task(id: words.last?.id) {
                await Task.yield()
                if reduceMotion {
                    proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.3)) {
                        proxy.scrollTo(Self.bottomAnchorID, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 176)
        .onAppear {
            reconcileWords(with: transcript)
        }
        .onChange(of: transcript) { _, newTranscript in
            reconcileWords(with: newTranscript)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(transcript)
        .accessibilityIdentifier("chat.conversation.transcript")
    }

    private func reconcileWords(with transcript: String) {
        let incoming = transcript.split(whereSeparator: \Character.isWhitespace).map(String.init)
        guard incoming != words.map(\.text) else { return }

        var commonPrefixCount = 0
        while commonPrefixCount < min(words.count, incoming.count),
              words[commonPrefixCount].text == incoming[commonPrefixCount] {
            commonPrefixCount += 1
        }

        if incoming.count == words.count,
           commonPrefixCount == incoming.count - 1,
           let finalWord = incoming.last {
            words[words.count - 1].text = finalWord
            return
        }

        var updatedWords = Array(words.prefix(commonPrefixCount))
        updatedWords.append(contentsOf: incoming.dropFirst(commonPrefixCount).enumerated().map { offset, text in
            Word(text: text, revealDelay: reduceMotion ? 0 : min(Double(offset) * 0.035, 0.18))
        })
        words = updatedWords
    }
}

private struct CapturedSpeechWordView: View {
    let text: String
    let revealDelay: TimeInterval

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isVisible = false

    var body: some View {
        Text(text)
            .font(.title2.weight(.medium))
            .foregroundStyle(.primary)
            .opacity(isVisible ? 1 : 0)
            .onAppear {
                if reduceMotion {
                    isVisible = true
                } else {
                    withAnimation(.easeOut(duration: 0.32).delay(revealDelay)) {
                        isVisible = true
                    }
                }
            }
    }
}

private struct TranscriptFlowLayout: Layout {
    let itemSpacing: CGFloat
    let lineSpacing: CGFloat

    func sizeThatFits(
        proposal: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) -> CGSize {
        let width = proposal.width ?? 0
        let rows = rows(for: subviews, width: width)
        let height = rows.reduce(CGFloat.zero) { $0 + $1.height } + CGFloat(max(rows.count - 1, 0)) * lineSpacing
        return CGSize(width: width, height: height)
    }

    func placeSubviews(
        in bounds: CGRect,
        proposal _: ProposedViewSize,
        subviews: Subviews,
        cache _: inout ()
    ) {
        var y = bounds.minY
        for row in rows(for: subviews, width: bounds.width) {
            var x = bounds.minX
            for item in row.items {
                item.subview.place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(item.size)
                )
                x += item.size.width + itemSpacing
            }
            y += row.height + lineSpacing
        }
    }

    private func rows(for subviews: Subviews, width: CGFloat) -> [Row] {
        var rows: [Row] = []
        var items: [Item] = []
        var rowWidth: CGFloat = 0
        var rowHeight: CGFloat = 0

        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            let proposedWidth = items.isEmpty ? size.width : rowWidth + itemSpacing + size.width
            if !items.isEmpty, proposedWidth > width {
                rows.append(Row(items: items, height: rowHeight))
                items = []
                rowWidth = 0
                rowHeight = 0
            }

            items.append(Item(subview: subview, size: size))
            rowWidth = items.count == 1 ? size.width : rowWidth + itemSpacing + size.width
            rowHeight = max(rowHeight, size.height)
        }

        if !items.isEmpty {
            rows.append(Row(items: items, height: rowHeight))
        }
        return rows
    }

    private struct Item {
        let subview: LayoutSubview
        let size: CGSize
    }

    private struct Row {
        let items: [Item]
        let height: CGFloat
    }
}

private struct ConversationOrbView: View {
    let waveformLevel: CGFloat
    let isAssistant: Bool
    let isPressed: Bool
    let activationScale: CGFloat

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hasAppeared = false

    private let conversationBlue = Color.blue

    var body: some View {
        ZStack {
            glassSphere

            Ellipse()
                .fill(
                    RadialGradient(
                        colors: [.white.opacity(0.58), .white.opacity(0.08), .clear],
                        center: .center,
                        startRadius: 0,
                        endRadius: 70
                    )
                )
                .frame(width: 96, height: 58)
                .blur(radius: 6)
                .offset(x: -42, y: -54)
                .allowsHitTesting(false)
        }
        // Keep the existing peak size, but give quiet input a smaller resting scale.
        .scaleEffect(hasAppeared ? activationScale * (0.82 + waveformLevel * 0.34) : 0)
        .animation(.spring(duration: 0.52, bounce: 0.18), value: activationScale)
        .animation(.easeOut(duration: 0.12), value: waveformLevel)
        .animation(.easeInOut(duration: 0.28), value: isAssistant)
        .animation(.snappy(duration: 0.18), value: isPressed)
        .task {
            await Task.yield()
            if reduceMotion {
                hasAppeared = true
            } else {
                withAnimation(.spring(duration: 0.58, bounce: 0.16)) {
                    hasAppeared = true
                }
            }
        }
    }

    @ViewBuilder
    private var glassSphere: some View {
#if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            let glass = isAssistant
                ? Glass.clear
                : Glass.clear.tint(conversationBlue.opacity(0.68))

            Circle()
                .fill(Color.clear)
                .glassEffect(glass, in: Circle())
        } else {
            Circle()
                .fill(isAssistant ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(conversationBlue))
                .overlay {
                    Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
                }
        }
#else
        Circle()
            .fill(isAssistant ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(conversationBlue))
            .overlay {
                Circle().strokeBorder(.white.opacity(0.18), lineWidth: 1)
            }
#endif
    }
}
