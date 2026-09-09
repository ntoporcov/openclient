import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

@main
struct OpenCodeIOSClientApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var composition: OpenClientComposition
#if DEBUG
    private let screenshotScene: OpenClientScreenshotScene?
    private let videoUITestPayload: OpenClientVisualVideoPayload?
#endif

    init() {
#if DEBUG
        let testEnvironment = ProcessInfo.processInfo.environment
        if testEnvironment["OPENCODE_UI_TEST_MODE"] == "1" {
            func isShareFixtureID(_ id: String) -> Bool {
                id.hasPrefix("pass5-ui-") && UUID(uuidString: String(id.dropFirst("pass5-ui-".count))) != nil
            }
            if let id = testEnvironment["OPENCODE_UI_TEST_SHARE_CLEANUP_ID"], isShareFixtureID(id) {
                _ = try? OpenClientSharePayloadStore.load(id: id, deletesAfterLoad: true)
            }
            if let json = testEnvironment["OPENCODE_UI_TEST_SHARE_PAYLOAD"], json.utf8.count < 1_000_000,
               let payload = try? JSONDecoder().decode(OpenClientSharePayload.self, from: Data(json.utf8)),
               isShareFixtureID(payload.id) {
                // Seed storage only; real URL delivery must still validate the destination.
                try? OpenClientSharePayloadStore.save(payload)
            }
        }
        let screenshotScene = OpenClientScreenshotScene.current
        self.screenshotScene = screenshotScene
        if let resourceID = ProcessInfo.processInfo.environment["OPENCODE_UI_TEST_VIDEO_RESOURCE_ID"],
           resourceID.isEmpty == false {
            let resourcePath = "/openclient/v1/video/resources/\(resourceID)/stream"
            videoUITestPayload = OpenClientVisualVideoPayload(
                schemaVersion: OpenClientVisualVideoContract.schemaVersion,
                title: "UI Test Earth Video",
                resourceID: resourceID,
                startPath: resourcePath,
                stopPath: resourcePath,
                expiresAt: "2100-01-01T00:00:00.000Z",
                file: OpenClientVisualVideoFile(
                    name: "file_example_MP4_1280_10MG.mp4",
                    sizeBytes: 9_840_497,
                    modifiedAt: "2026-07-27T19:43:25.291Z",
                    mimeType: "video/mp4"
                ),
                width: 1_280,
                height: 720,
                rotation: 0,
                duration: 30,
                cover: Self.videoUITestCover
            )
        } else {
            videoUITestPayload = nil
        }
        if let screenshotScene {
            _composition = StateObject(
                wrappedValue: OpenClientComposition(
                    viewModel: AppViewModel.screenshot(scene: screenshotScene),
                    whatsNew: OpenClientWhatsNewStore(checksForUpdates: false)
                )
            )
        } else {
            _composition = StateObject(wrappedValue: OpenClientComposition())
        }
#else
        _composition = StateObject(wrappedValue: OpenClientComposition())
#endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if let videoUITestPayload {
                    OpenClientVideoUITestView(
                        connection: composition.connection,
                        bridge: composition.bridge,
                        videoStreams: composition.videoStreams,
                        payload: videoUITestPayload
                    )
                } else if let screenshotScene {
                    ScreenshotSceneView(scene: screenshotScene, viewModel: composition.viewModel)
                } else {
                    rootView
                }
#else
                rootView
#endif
            }
            .opencodeSoftScrollEdgeEffect()
            .opencodeDismissesSheetsOnBackgroundTap()
            .onOpenURL { url in
                composition.appShell.prepareOpenURLPresentation(url)
                Task { await composition.appShell.handleOpenURL(url) }
            }
            .onChange(of: scenePhase) { _, phase in
                composition.appShell.applicationActivityChanged(isActive: phase == .active)
                guard phase == .active else { return }
                composition.appShell.scheduleForegroundChatCatchUp(reason: "app scene active")
            }
#if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                composition.appShell.applicationActivityChanged(isActive: true)
                composition.appShell.scheduleForegroundChatCatchUp(reason: "application did become active")
            }
#endif
        }
        .commands {
            OpenClientFocusedChatCommands()
        }

        WindowGroup(id: OpenClientChatWindowRoute.sceneID, for: OpenClientChatWindowRoute.self) { $route in
            Group {
#if DEBUG
                if let screenshotScene, screenshotScene != .chat {
                    ScreenshotSceneView(scene: screenshotScene, viewModel: composition.viewModel)
                } else {
                    dedicatedChatWindow(route: route)
                }
#else
                dedicatedChatWindow(route: route)
#endif
            }
        }
    }

    private var rootView: some View {
        RootView(
            shell: composition.appShell,
            bridge: composition.bridge,
            whatsNew: composition.whatsNew
        ) { sessionID, presentationRequest in
            ChatView(
                chatFacade: composition.chat,
                browser: composition.appShell.browser,
                imageContent: composition.imageContent,
                videoStreams: composition.videoStreams,
                sessionID: sessionID,
                presentationRequest: presentationRequest
            )
        }
    }

    @ViewBuilder
    private func dedicatedChatWindow(route: OpenClientChatWindowRoute?) -> some View {
        ChatWindowRestorationGate(viewModel: composition.viewModel, route: route) { route in
            if let connection = composition.viewModel.backendConnection,
               let owner = composition.viewModel.directoryStoreRegistry.existingStore(for: DirectoryStoreRegistry.directory(forKey: route.directoryKey)),
               let session = owner.sessions.first(where: { $0.id == route.sessionID }) {
                IsolatedChatWindow(composition: composition, connection: connection, session: session, owner: owner)
                    .accessibilityIdentifier("chat.dedicatedWindow")
                    .overlay(alignment: .topLeading) {
#if DEBUG
                        if screenshotScene == .chat {
                            Text(OpenClientScreenshotScene.chat.rawValue)
                                .font(.caption2)
                                .foregroundStyle(.clear)
                                .padding(1)
                                .accessibilityIdentifier(OpenClientScreenshotScene.chat.accessibilityIdentifier)
                        }
#endif
                    }
                    .opencodeSoftScrollEdgeEffect()
                    .opencodeDismissesSheetsOnBackgroundTap()
            }
        }
    }
}

private struct IsolatedChatWindow: View {
    let composition: OpenClientComposition
    @StateObject private var facade: ChatFacade

    init(composition: OpenClientComposition, connection: BackendConnection, session: OpenCodeSession, owner: DirectoryStore) {
        self.composition = composition
        _facade = StateObject(wrappedValue: Self.makeFacade(composition: composition, connection: connection, session: session, owner: owner))
    }

    private static func makeFacade(composition: OpenClientComposition, connection: BackendConnection, session: OpenCodeSession, owner: DirectoryStore) -> ChatFacade {
        let model = composition.viewModel
        let context = ChatWindowContext(model: model, connection: connection, session: session, owner: owner)
        return ChatFacade(viewModel: model, windowContext: context)
    }

    var body: some View {
        if let context = facade.windowContext {
            NavigationStack {
                ChatView(chatFacade: facade, browser: context.browser, imageContent: composition.imageContent,
                    videoStreams: composition.videoStreams, sessionID: context.session.id, isDedicatedWindow: true)
                    .id(context.session.id)
            }
            .onDisappear { context.close() }
        }
    }
}

private struct ChatWindowRestorationGate<Content: View>: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject private var connectionStore: ConnectionStore
    @State private var restoration: ChatWindowRestorationCoordinator
    let route: OpenClientChatWindowRoute?
    let content: (OpenClientChatWindowRoute) -> Content

    init(viewModel: AppViewModel, route: OpenClientChatWindowRoute?, @ViewBuilder content: @escaping (OpenClientChatWindowRoute) -> Content) {
        self.viewModel = viewModel
        _connectionStore = ObservedObject(wrappedValue: viewModel.connectionStore)
        _restoration = State(initialValue: ChatWindowRestorationCoordinator(viewModel: viewModel))
        self.route = route
        self.content = content
    }

    var body: some View {
        Group {
            if let route, restoration.isApproved(route) {
                content(route)
                    .id(viewModel.backendConnection?.id)
            } else {
                ContentUnavailableView("Unavailable", systemImage: "bubble.left.and.bubble.right")
                    .accessibilityIdentifier("chat.dedicatedWindow.unavailable")
            }
        }
        .task(id: ValidationKey(route: route, revision: restoration.revision)) {
            await restoration.validate(route)
        }
    }

    private struct ValidationKey: Equatable {
        let route: OpenClientChatWindowRoute?
        let revision: Int
    }
}

private struct StopCurrentChatFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

private struct SwitchToRecentlyOpenedSessionFocusedValueKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var stopCurrentChat: (() -> Void)? {
        get { self[StopCurrentChatFocusedValueKey.self] }
        set { self[StopCurrentChatFocusedValueKey.self] = newValue }
    }

    var switchToRecentlyOpenedSession: (() -> Void)? {
        get { self[SwitchToRecentlyOpenedSessionFocusedValueKey.self] }
        set { self[SwitchToRecentlyOpenedSessionFocusedValueKey.self] = newValue }
    }
}

private struct OpenClientFocusedChatCommands: Commands {
    @FocusedValue(\.stopCurrentChat) private var stopCurrentChat
    @FocusedValue(\.switchToRecentlyOpenedSession) private var switchToRecentlyOpenedSession

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Stop Stream") {
                stopCurrentChat?()
            }
            .keyboardShortcut(.escape, modifiers: [])
            .disabled(stopCurrentChat == nil)

            Button("Previous Session") {
                switchToRecentlyOpenedSession?()
            }
            .keyboardShortcut("`", modifiers: .command)
            .disabled(switchToRecentlyOpenedSession == nil)
        }
    }
}

#if DEBUG && canImport(UIKit)
private extension OpenCodeIOSClientApp {
    static let videoUITestCover: OpenClientVisualPreview = {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let data = UIGraphicsImageRenderer(
            size: CGSize(width: 16, height: 9),
            format: format
        ).jpegData(withCompressionQuality: 0.8) { context in
            UIColor.systemPink.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 16, height: 9))
        }
        return try! OpenClientVisualPreview(jpegData: data, width: 16, height: 9)
    }()
}
#endif

#if DEBUG
private struct OpenClientVideoUITestView: View {
    @ObservedObject var connection: ConnectionFacade
    @ObservedObject var bridge: OpenClientBridgeFacade
    let videoStreams: OpenClientVideoStreamCoordinator
    let payload: OpenClientVisualVideoPayload
    @StateObject private var playback: OpenClientVisualVideoPlaybackController

    init(
        connection: ConnectionFacade,
        bridge: OpenClientBridgeFacade,
        videoStreams: OpenClientVideoStreamCoordinator,
        payload: OpenClientVisualVideoPayload
    ) {
        self.connection = connection
        self.bridge = bridge
        self.videoStreams = videoStreams
        self.payload = payload
        let activity = OpenClientVisualVideoActivity(payload: payload)
        _playback = StateObject(wrappedValue: OpenClientVisualVideoPlaybackController(id: activity.id, payload: payload))
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if bridge.snapshot.isConnected {
                    OpenClientVisualVideoView(
                        activity: OpenClientVisualVideoActivity(payload: payload),
                        playback: playback,
                        coordinator: videoStreams
                    )
                    Text("Video bridge ready")
                        .accessibilityIdentifier("video.ui-test.ready")
                } else {
                    ProgressView("Connecting video bridge...")
                }
            }
            .padding()
            .navigationTitle("Video Test")
        }
        .task {
            if !connection.isConnected {
                connection.startConnection()
            }
        }
    }
}
#endif
