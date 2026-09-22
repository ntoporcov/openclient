import SwiftUI
#if canImport(UIKit)
import UIKit

#if DEBUG
struct ScreenshotSceneView: View {
    let scene: OpenClientScreenshotScene
    @ObservedObject var viewModel: AppViewModel

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
        }
        .preferredColorScheme(
            ProcessInfo.processInfo.environment["OPENCLIENT_UI_TEST_DARK_MODE"] == "1" ? .dark : nil
        )
    }

    private func requestLandscapeForiPadScreenshots() {
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
                    providerUsage: viewModel.providerUsageFacade
                ) {}
            }
        case .chat:
            #if os(iOS) && !targetEnvironment(macCatalyst)
            if ProcessInfo.processInfo.environment["OPENCLIENT_HEADER_FIXTURE"] == "1" {
                ChatHeaderFixture()
            } else { rootView }
            #else
            rootView
            #endif
        case .ipadRoom:
            rootView
        case .projects, .newSession, .providerSetup, .funGames, .sessions, .terminal, .sessionActions, .sessionPinned, .permission, .question, .findPlaceGame, .findBugGame, .composerActions:
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
