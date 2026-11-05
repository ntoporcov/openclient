import SwiftUI
#if canImport(UIKit)
import UIKit

#if DEBUG
struct ScreenshotSceneView: View {
    let scene: OpenClientScreenshotScene
    @ObservedObject var viewModel: AppViewModel
    @State private var showsActivityAnnouncement = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            screenshotContent

            Text(scene.rawValue)
                .font(.caption2)
                .foregroundStyle(.clear)
                .padding(1)
                .accessibilityIdentifier(scene.accessibilityIdentifier)
        }
        .onAppear {
            requestLandscapeForiPadScreenshots()
            showsActivityAnnouncement = ProcessInfo.processInfo.environment["OPENCLIENT_ACTIVITY_ANNOUNCEMENT"] == "1"
                || ProcessInfo.processInfo.environment["OPENCLIENT_CURRENT_ANNOUNCEMENT"] == "1"
        }
        .sheet(isPresented: $showsActivityAnnouncement) {
            if let release = ProcessInfo.processInfo.environment["OPENCLIENT_CURRENT_ANNOUNCEMENT"] == "1"
                ? OpenClientReleaseNotesCatalog.releases.last
                : OpenClientReleaseNotesCatalog.releases.first(where: { $0.hero == .activityWorkflow }) {
                OpenClientWhatsNewView(release: release,
                                      connection: viewModel.connectionFacade, bridge: nil) {
                    showsActivityAnnouncement = false
                }
            }
        }
        .preferredColorScheme(
            ProcessInfo.processInfo.environment["OPENCLIENT_UI_TEST_DARK_MODE"] == "1" ? .dark : nil
        )
    }

    private func requestLandscapeForiPadScreenshots() {
        guard ProcessInfo.processInfo.environment["OPENCLIENT_GALLERY"] != "1" else { return }
        guard UIDevice.current.userInterfaceIdiom == .pad else { return }

        if #available(iOS 16.0, *) {
            let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            for scene in scenes {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: .landscapeRight))
            }
        } else {
            UIDevice.current.setValue(UIInterfaceOrientation.landscapeRight.rawValue, forKey: "orientation")
        }
    }

    @ViewBuilder
    private var screenshotContent: some View {
        switch scene {
        case .connection, .recentServers:
            rootView
        case .browser:
            BrowserScreenshotSceneContent(browser: viewModel.appShellFacade.browser) {
                rootView
            }
        case .visualTools:
            OpenClientVisualToolsScreenshotView()
        case .submissionRecovery:
            #if canImport(UIKit)
            if TranscriptContinuityDiagnostics.enabled {
                TranscriptContinuityFixture()
            } else {
                recoveryScreenshotContent
            }
            #else
            recoveryScreenshotContent
            #endif
        case .terminalShowcase:
            NavigationStack {
                TerminalDetailView(
                    facade: viewModel.terminalFacade,
                    terminalID: OpenClientScreenshotData.terminal.id
                )
            }
        case .activity:
            NavigationStack {
                ActivityView(
                    facade: viewModel.activityFacade,
                    connection: viewModel.connectionFacade,
                    providerUsage: viewModel.providerUsageFacade,
                    configurations: viewModel.configurationsFacade,
                    bridge: nil
                ) {}
            }
        case .chat:
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if ProcessInfo.processInfo.environment["OPENCLIENT_DESKTOP_POINTER_TEST"] == "1" {
                DesktopPointerFixture()
            } else if ProcessInfo.processInfo.environment["OPENCLIENT_DESKTOP_CLIPBOARD_TEST"] == "1" {
                DesktopClipboardFixture()
            } else if let suite = ProcessInfo.processInfo.environment["OPENCLIENT_DESKTOP_GAME_TEST_SUITE"],
               let defaults = UserDefaults(suiteName: suite) {
                DesktopLandscapeContainer {
                    DesktopLoadingGame(defaults: defaults)
                        .background(.black)
                        .overlay(alignment: .topLeading) {
                            Color.clear.frame(width: 1, height: 1)
                                .accessibilityElement()
                                .accessibilityIdentifier("screenshot.scene.desktop-game")
                        }
                }
            } else if #available(iOS 18.0, *), ProcessInfo.processInfo.environment["OPENCLIENT_NATIVE_HARNESS_LOOP"] == "1" {
                NativeHarnessLoopFixture()
            } else if #available(iOS 18.0, *), ProcessInfo.processInfo.environment["OPENCLIENT_GLASS_PILL_PREVIEW"] == "1" {
                GlassThinkingPillPreview()
            } else if ProcessInfo.processInfo.environment["OPENCLIENT_CHAT_CONTROLS_PREVIEW"] == "1" {
                WhatsNewChatControlsFixture()
            } else if ProcessInfo.processInfo.environment["OPENCLIENT_TOOL_GROUPING_FIXTURE"] == "1" {
                ToolGroupingFixture()
            } else if ProcessInfo.processInfo.environment["OPENCLIENT_QUEUE_LIFECYCLE_FIXTURE"] == "1" {
                QueuedSubmissionLifecycleFixture()
            } else if ProcessInfo.processInfo.environment["OPENCLIENT_STREAMING_DELIVERY_FIXTURE"] == "1" {
                StreamingDeliveryFixture()
            } else if ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_FIXTURE"] == "1" {
                ChatHeaderFixture()
            } else { rootView }
            #else
            rootView
            #endif
        case .ipadRoom:
            rootView
        case .question:
            if ProcessInfo.processInfo.environment["OPENCLIENT_V2_QUESTION_FIXTURE"] == "1" {
                SessionFormVisualFixture()
            } else {
                rootView
            }
        case .projects, .newSession, .providerSetup, .funGames, .sessions, .terminal, .sessionActions, .sessionPinned, .permission, .findPlaceGame, .findBugGame, .composerActions, .composerMentions:
            rootView
        case .paywall:
            OpenClientPaywallView(
                commerce: viewModel.commerceFacade,
                reason: .manual
            )
        case .recentWidget:
            WidgetScreenshotDashboardView(
                title: "Recent Sessions",
                serverName: OpenClientScreenshotData.widgetServer.displayName,
                sessions: OpenClientScreenshotData.recentWidgetSessions
            )
        case .pinnedWidget:
            WidgetScreenshotDashboardView(
                title: "Pinned Sessions",
                serverName: OpenClientScreenshotData.widgetServer.displayName,
                sessions: OpenClientScreenshotData.pinnedWidgetSessions
            )
        case .quickStartWidgets:
            QuickStartWidgetScreenshotDashboardView(
                serverName: OpenClientScreenshotData.widgetServer.displayName,
                projects: OpenClientScreenshotData.projects.filter { $0.id != "global" },
                action: OpenClientScreenshotData.projectActions[0],
                model: OpenClientScreenshotData.openAIModel
            )
        case .liveActivity:
            LiveActivityScreenshotView(
                session: OpenClientScreenshotData.releaseSession,
                project: OpenClientScreenshotData.repoProject,
                permission: OpenClientScreenshotData.permission,
                question: OpenClientScreenshotData.questionRequest
            )
        }
    }

    private var recoveryScreenshotContent: some View {
        VStack(spacing: 0) {
            if ProcessInfo.processInfo.environment["OPENCLIENT_RECOVERY_WINDOW"] == "1" {
                V2RecoveryWindowScreenshot(viewModel: viewModel)
            } else {
                rootView
            }
            if ProcessInfo.processInfo.environment["OPENCLIENT_RECOVERY_ADMISSION_CONTROLS"] == "1" {
                Button {
                    viewModel.chatStore.confirmSubmissionAdmission(messageID: "recovery-local-input",
                        sessionID: OpenClientScreenshotData.releaseSession.id)
                } label: { Text(verbatim: "Admit fixture") }
                .accessibilityIdentifier("screenshot.recovery.admit")
            }
        }
    }

    private var rootView: some View {
        RootView(shell: viewModel.appShellFacade) { sessionID, presentationRequest in
            ChatView(
                chatFacade: viewModel.chatFacade,
                browser: viewModel.appShellFacade.browser,
                sessionID: sessionID,
                presentationRequest: presentationRequest
            )
        }
    }

}

/// Marketing capture fixture: production transcript and RealityKit views, native animations.
/// The tiny corner cue is outside the final center crop and synchronizes host video trimming.
@available(iOS 18.0, *)
private struct NativeHarnessLoopFixture: View {
    @State private var showsMessage = false
    @State private var scrollsMessage = false
    @State private var showsThinking = false
    @State private var cue = false
    @State private var cycle = 0
    @State private var statusIndex = 0
    private let headerOnly = ProcessInfo.processInfo.environment["OPENCLIENT_NATIVE_HARNESS_HEADER"] == "1"
    private let statuses: [ThinkingPillStatus] = [
        ThinkingPillStatus(title: "Thinking", tint: .cyan),
        ThinkingPillStatus(title: "Working", tint: .orange),
        ThinkingPillStatus(title: "Needs Input", tint: .orange),
        ThinkingPillStatus(title: "Ready", tint: .green)
    ]

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                ConnectionSheetBackdrop(motionDuration: 6)
                ZStack {
                    if showsMessage && !headerOnly {
                        NativeHarnessMovingMessage(scrollsAway: scrollsMessage)
                            .id(cycle)
                            .frame(width: 260)
                            // Move the complete rendered bubble, including its text and glass.
                            .geometryGroup()
                            .compositingGroup()
                            .scaleEffect(2.1)
                            .offset(x: -36)
                            .transition(.offset(y: 110).combined(with: .scale(scale: 0.86)).combined(with: .opacity))
                    }
                    // Keep RealityKit mounted and rendering before the reveal.
                    GlassThinkingPill(title: statuses[statusIndex].title, tint: statuses[statusIndex].tint, maximumDimension: 108)
                        .opacity(headerOnly || showsThinking ? 1 : 0)
                        .scaleEffect(headerOnly || showsThinking ? 1 : 0.86)
                        // The production camera is offset for the status text. Center
                        // the visible capsule in the header and clear the store controls.
                        .offset(x: headerOnly ? 22 : 0,
                                y: headerOnly ? 20 : (showsThinking ? 0 : 55))
                }
                .frame(width: 720, height: 310)
                .scaleEffect(geometry.size.width / 720)
                .frame(width: geometry.size.width, height: geometry.size.height)
            }
            .overlay(alignment: .topLeading) {
                (cue ? Color(red: 1, green: 0, blue: 1) : Color.black)
                    .frame(width: 16, height: 16)
                    .padding(40)
                    .accessibilityIdentifier(cue ? "harness.cycle.start" : "harness.cycle.wait")
            }
            .clipped()
        }
        .ignoresSafeArea()
        .statusBarHidden()
        .persistentSystemOverlays(.hidden)
        .preferredColorScheme(.dark)
        .environment(\.appAccentColor, .blue)
        .environment(\.appAccentForeground, .white)
        .environment(\.chatBubbleStyle, .glass)
        .task {
            do {
                try await Task.sleep(for: .seconds(5))
                while !Task.isCancelled {
                    cycle += 1
                    cue = true
                    if headerOnly {
                        statusIndex = 0
                        try await Task.sleep(for: .seconds(0.4))
                        cue = false
                        try await Task.sleep(for: .seconds(2.6))
                        for index in 1..<statuses.count {
                            statusIndex = index
                            try await Task.sleep(for: .seconds(3))
                        }
                        continue
                    }
                    try await Task.sleep(for: .seconds(0.4))
                    cue = false
                    withAnimation(.spring(response: 0.65, dampingFraction: 0.82)) { showsMessage = true }
                    try await Task.sleep(for: .seconds(3.6))
                    withAnimation(.easeInOut(duration: 1.2)) { scrollsMessage = true }
                    try await Task.sleep(for: .seconds(0.55))
                    withAnimation(.spring(response: 0.8, dampingFraction: 0.85)) { showsThinking = true }
                    try await Task.sleep(for: .seconds(5.0))
                    withAnimation(.easeInOut(duration: 1.0)) { showsThinking = false }
                    try await Task.sleep(for: .seconds(1.1))
                    showsMessage = false
                    scrollsMessage = false
                    try await Task.sleep(for: .seconds(1.35))
                }
            } catch { /* The capture scene was dismissed. */ }
        }
    }
}

/// Animate the hosting surface as one UIKit layer so native glass and text cannot
/// resolve the scrolling geometry independently.
private struct NativeHarnessMovingMessage: UIViewRepresentable {
    let scrollsAway: Bool

    @MainActor final class Coordinator {
        let host = UIHostingController(rootView: NativeHarnessMessage())
        var scrollsAway = false
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let hosted = context.coordinator.host.view!
        hosted.backgroundColor = .clear
        hosted.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosted)
        NSLayoutConstraint.activate([
            hosted.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosted.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosted.topAnchor.constraint(equalTo: container.topAnchor),
            hosted.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        return container
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UIView, context: Context) -> CGSize? {
        context.coordinator.host.sizeThatFits(in: CGSize(width: proposal.width ?? 260, height: 1000))
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        guard context.coordinator.scrollsAway != scrollsAway else { return }
        context.coordinator.scrollsAway = scrollsAway
        UIView.animate(withDuration: 1.2, delay: 0, options: [.curveEaseInOut, .beginFromCurrentState]) {
            context.coordinator.host.view.transform = self.scrollsAway
                ? CGAffineTransform(translationX: 0, y: -420 / 2.1) : .identity
        }
    }
}

private struct NativeHarnessMessage: View {
    @State private var images = OpenClientImageLoadingStore()
    @State private var videos = OpenClientVideoPlaybackStore()
    private let message = OpenCodeMessageEnvelope.local(
        role: "user", text: "What if iOS had an AI Harness?",
        messageID: "harness-prompt", sessionID: "harness-capture")

    var body: some View {
        MessageBubble(
            message: message, detailedMessage: nil, currentSessionID: "harness-capture",
            isStreamingMessage: false, animatesStreamingText: false, showsToolCalls: false,
            hidesReasoningBlocks: true, reserveEntryFromComposer: false, animateEntryFromComposer: false,
            expandedReasoningPartIDs: [], expandedContextGroupIDs: [], showsAllActivity: true,
            resolveTaskSessionID: { _, _ in nil }, onSelectPart: { _ in }, onOpenTaskSession: { _ in },
            onForkMessage: { _ in }, onInspectDebugMessage: { _ in }, onEntryAnimationStarted: { _ in },
            onToggleReasoningPart: { _ in }, onToggleContextGroup: { _ in }, onShowEarlierActivity: {},
            onOpenVisualHTML: { _ in }, imageContent: nil, imageLoadingStore: images,
            videoStreams: nil, videoPlaybackStore: videos
        )
    }
}

private struct V2RecoveryWindowScreenshot: View {
    @State private var facade: ChatFacade

    init(viewModel: AppViewModel) {
        let session = OpenClientScreenshotData.releaseSession
        let context = ChatWindowContext(model: viewModel, connection: viewModel.backendConnection!, session: session,
            owner: viewModel.directoryStore)
        _facade = State(initialValue: ChatFacade(viewModel: viewModel, windowContext: context))
    }

    var body: some View {
        NavigationStack {
            ChatView(chatFacade: facade, browser: facade.windowContext!.browser,
                sessionID: OpenClientScreenshotData.releaseSession.id)
        }
        .onDisappear { facade.windowContext?.close() }
    }
}

private struct BrowserScreenshotSceneContent<Content: View>: View {
    @ObservedObject var browser: BrowserStore
    @ViewBuilder let content: () -> Content
    @State private var isReady = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            content()

            if isReady {
                Text("Browser ready")
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("screenshot.browser.ready")
            }
        }
        .task {
            let webView = browser.webView
            webView.loadHTMLString(
                OpenClientScreenshotData.browserHTML,
                baseURL: OpenClientScreenshotData.browserURL
            )
            _ = try? browser.presentForAutomation(
                instruction: "Review the updated homepage and verify the new call to action."
            )

            for _ in 0 ..< 100 {
                guard !Task.isCancelled else { return }
                let state = try? await webView.evaluateJavaScript("document.readyState") as? String
                if state == "complete" {
                    isReady = true
                    return
                }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }
}

private struct OpenClientVisualToolsScreenshotView: View {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var isHTMLReady = false
    @State private var selectedHTML: OpenClientVisualHTMLPresentation?
    @StateObject private var videoPlayback: OpenClientVisualVideoPlaybackController

    private let videoActivity: OpenClientVisualVideoActivity

    init() {
        let videoActivity = OpenClientVisualVideoActivity(payload: OpenClientVisualMediaDemo.videoPayload)
        self.videoActivity = videoActivity
        _videoPlayback = StateObject(
            wrappedValue: OpenClientVisualVideoPlaybackController(
                id: videoActivity.id,
                payload: videoActivity.payload
            )
        )
    }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 18) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("OPENCLIENT PLUGIN")
                                .font(.caption.weight(.bold))
                                .tracking(0.8)
                                .foregroundStyle(.indigo)
                            Text("Answers you can see")
                                .font(.largeTitle.bold())
                            Text("Charts, safe previews, images, and video render natively inside your conversation.")
                                .font(.body)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        if horizontalSizeClass == .regular {
                            HStack(alignment: .top, spacing: 16) {
                                chartCard
                                htmlCard
                            }
                        } else {
                            VStack(spacing: 14) {
                                chartCard
                                htmlCard
                            }
                        }

                        OpenClientVisualToolsVideoCard(
                            videoActivity: videoActivity,
                            videoPlayback: videoPlayback
                        )
                    }
                    .frame(maxWidth: 1_080)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height, alignment: .center)
                }
            }
            .background(OpenCodePlatformColor.groupedBackground)
        }
        .overlay(alignment: .topLeading) {
            if isHTMLReady {
                Text("Visual tools ready")
                    .foregroundStyle(.clear)
                    .accessibilityIdentifier("screenshot.visual-tools.ready")
            }
        }
        .sheet(item: $selectedHTML) { presentation in
            OpenClientVisualHTMLDetailView(payload: presentation.payload)
        }
    }

    private var chartCard: some View {
        OpenClientVisualChartView(activity: Self.chartActivity, contentHeight: 140)
            .frame(maxWidth: .infinity, alignment: .top)
    }

    private var htmlCard: some View {
        OpenClientVisualHTMLView(
            activity: Self.htmlActivity,
            onOpen: { payload in
                selectedHTML = OpenClientVisualHTMLPresentation(payload: payload)
            },
            onLoad: { isHTMLReady = true }
        )
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private static let chartActivity = OpenClientVisualChartActivity(
        payload: OpenClientVisualChartPayload(
            chartType: .line,
            title: "Homepage load time",
            xAxis: OpenClientVisualChartXAxis(type: .category, title: "Build"),
            yAxis: OpenClientVisualChartYAxis(title: "Milliseconds"),
            series: [
                OpenClientVisualChartSeries(
                    id: "load-time",
                    name: "Load time",
                    points: [
                        OpenClientVisualChartPoint(id: "build-1", x: .string("1.0.9"), y: 920),
                        OpenClientVisualChartPoint(id: "build-2", x: .string("1.0.10"), y: 780),
                        OpenClientVisualChartPoint(id: "build-3", x: .string("1.0.11"), y: 690),
                        OpenClientVisualChartPoint(id: "build-4", x: .string("1.0.12"), y: 510),
                        OpenClientVisualChartPoint(id: "build-5", x: .string("1.0.13"), y: 430),
                    ]
                ),
            ]
        )
    )

    private static let htmlActivity = OpenClientVisualHTMLActivity(
        payload: OpenClientVisualHTMLPayload(
            schemaVersion: OpenClientVisualHTMLContract.schemaVersion,
            title: "Release readiness",
            accessibilityLabel: "Release readiness card showing all checks passed and ready to ship.",
            html: """
            <style>
            .card { padding: 16px; color: #172033; font-family: -apple-system; }
            .status { display: inline-block; padding: 6px 10px; border-radius: 999px; background: #d1fae5; color: #047857; font-weight: 700; font-size: 12px; }
            h2 { margin: 12px 0 5px; font-size: 21px; }
            p { margin: 0; color: #64748b; font-size: 13px; }
            .checks { display: flex; gap: 7px; margin-top: 13px; }
            .check { flex: 1; padding: 8px; border-radius: 9px; background: #eef2ff; color: #4338ca; text-align: center; font-size: 11px; font-weight: 650; }
            </style>
            <div class="card"><span class="status">ALL CHECKS PASSED</span><h2>Ready to ship</h2><p>The latest website changes are healthy.</p><div class="checks"><div class="check">Build</div><div class="check">Tests</div><div class="check">Preview</div></div></div>
            """,
            height: 130
        )
    )
}

private struct OpenClientVisualToolsVideoCard: View {
    let videoActivity: OpenClientVisualVideoActivity
    @ObservedObject var videoPlayback: OpenClientVisualVideoPlaybackController

    var body: some View {
        OpenClientVisualVideoView(
            activity: videoActivity,
            playback: videoPlayback,
            coordinator: nil
        )
        .frame(maxWidth: .infinity, alignment: .top)
        .allowsHitTesting(false)
    }
}
#endif
#endif
