import AVFoundation
import AVKit
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct OpenClientVisualVideoPlaybackID: Hashable, Sendable {
    let sessionID: String
    let messageID: String
    let partID: String
}

struct OpenClientVisualVideoActivity: Equatable {
    let id: OpenClientVisualVideoPlaybackID
    let payload: OpenClientVisualVideoPayload

    init(payload: OpenClientVisualVideoPayload) {
        id = OpenClientVisualVideoPlaybackID(
            sessionID: "preview",
            messageID: "preview",
            partID: payload.resourceID
        )
        self.payload = payload
    }

    init?(part: OpenCodePart, sessionID: String? = nil, messageID: String? = nil) {
        guard part.type == "tool",
              part.tool == "openclient_execute_tool",
              let state = part.state,
              state.input?.toolID == OpenClientVisualVideoContract.toolID,
              state.metadata?.renderer == OpenClientVisualVideoContract.rendererID,
              let payloadValue = state.metadata?.payload,
              let data = try? JSONEncoder().encode(payloadValue),
              let decoded = try? JSONDecoder().decode(OpenClientVisualVideoPayload.self, from: data),
              let payload = try? decoded.validated() else {
            return nil
        }
        let resolvedSessionID = part.sessionID ?? sessionID ?? "unknown-session"
        let resolvedMessageID = part.messageID ?? messageID ?? "unknown-message"
        let resolvedPartID = part.id?.nilIfBlank ?? part.callID?.nilIfBlank ?? payload.resourceID
        id = OpenClientVisualVideoPlaybackID(
            sessionID: resolvedSessionID,
            messageID: resolvedMessageID,
            partID: resolvedPartID
        )
        self.payload = payload
    }
}

struct OpenClientVisualVideoView: View {
    let activity: OpenClientVisualVideoActivity
    @ObservedObject var playback: OpenClientVisualVideoPlaybackController
    let coordinator: OpenClientVideoStreamCoordinator?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OpenClientVisualVideoHeader(payload: activity.payload)
                .padding(12)
            Divider()

            switch playback.phase {
            case .idle:
                Button {
                    playback.start(activity: activity, coordinator: coordinator)
                } label: {
                    OpenClientVisualVideoPreview(
                        payload: activity.payload,
                        mode: .idle,
                        onRetry: {}
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Play \(activity.payload.displayTitle)")
            case .preparing:
                OpenClientVisualVideoPreview(
                    payload: activity.payload,
                    mode: .preparing,
                    onRetry: {}
                )
            case .playing:
                if let player = playback.player {
                    OpenClientInlineVideoPlayer(
                        player: player,
                        payload: activity.payload,
                        playback: playback
                    )
                        .frame(maxWidth: .infinity)
                        .accessibilityIdentifier("chat.tool.visual-video.player")
                        .accessibilityValue(playback.playbackAccessibilityValue)
                }
            case .failed(let message):
                OpenClientVisualVideoPreview(
                    payload: activity.payload,
                    mode: .failed(message),
                    onRetry: {
                        playback.start(activity: activity, coordinator: coordinator)
                    }
                )
            }
        }
        .background(OpenCodePlatformColor.secondaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .onAppear { playback.setInlineVisible(true) }
        .onDisappear { playback.setInlineVisible(false) }
        .accessibilityIdentifier("chat.tool.visual-video")
    }
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}

@MainActor
final class OpenClientVideoPlaybackStore {
    private var controllers: [OpenClientVisualVideoPlaybackID: OpenClientVisualVideoPlaybackController] = [:]
    private weak var activeController: OpenClientVisualVideoPlaybackController?

    func controller(for activity: OpenClientVisualVideoActivity) -> OpenClientVisualVideoPlaybackController {
        if let controller = controllers[activity.id] {
            controller.adopt(payload: activity.payload)
            return controller
        }
        let controller = OpenClientVisualVideoPlaybackController(id: activity.id, payload: activity.payload)
        controller.onWillStart = { [weak self, weak controller] in
            guard let self, let controller else { return }
            if let activeController, activeController !== controller {
                activeController.stop()
            }
            activeController = controller
        }
        controllers[activity.id] = controller
        return controller
    }

    func stopAll() {
        controllers.values.forEach { $0.stop() }
        activeController = nil
    }
}

@MainActor
final class OpenClientVisualVideoPlaybackController: NSObject, ObservableObject {
    enum Phase: Equatable {
        case idle
        case preparing
        case playing
        case failed(String)
    }

    let id: OpenClientVisualVideoPlaybackID
    @Published private(set) var phase: Phase = .idle
    @Published private(set) var player: AVPlayer?
    @Published private(set) var playbackAccessibilityValue = String(localized: "Loading")
    @Published private(set) var isPaused = false

    var onWillStart: (() -> Void)?

    private var payload: OpenClientVisualVideoPayload
    private var coordinator: OpenClientVideoStreamCoordinator?
    private var activeStream: OpenClientVideoStream?
    private var startTask: Task<Void, Never>?
    private var playbackMonitorTask: Task<Void, Never>?
    private var visibilityTask: Task<Void, Never>?
    private var endBoundaryObserver: Any?
    private weak var endBoundaryObserverPlayer: AVPlayer?
    private var isInlineVisible = false
    private var userStartedPlayback = false

    #if canImport(UIKit)
    private var playerLayer: AVPlayerLayer?
    private var pendingPlayerLayer: AVPlayerLayer?
    private weak var presentationWindow: UIWindow?
    private var pictureInPictureController: AVPictureInPictureController?
    private var fullscreenController: OpenClientFullscreenVideoController?
    private(set) var isPictureInPictureActive = false
    #endif

    init(id: OpenClientVisualVideoPlaybackID, payload: OpenClientVisualVideoPayload) {
        self.id = id
        self.payload = payload
        super.init()
    }

    func adopt(payload: OpenClientVisualVideoPayload) {
        guard self.payload.resourceID != payload.resourceID else {
            self.payload = payload
            return
        }
        stop()
        self.payload = payload
    }

    func start(activity: OpenClientVisualVideoActivity, coordinator: OpenClientVideoStreamCoordinator?) {
        adopt(payload: activity.payload)
        self.coordinator = coordinator
        onWillStart?()
        userStartedPlayback = true
        startTask?.cancel()
        playbackMonitorTask?.cancel()
        phase = .preparing
        playbackAccessibilityValue = String(localized: "Loading")
        startTask = Task { @MainActor [weak self] in
            await self?.preparePlayback()
        }
    }

    func togglePlayback() {
        guard let player else { return }
        if player.timeControlStatus == .playing || player.timeControlStatus == .waitingToPlayAtSpecifiedRate {
            player.pause()
            isPaused = true
            return
        }
        let duration = player.currentItem?.duration.seconds ?? payload.duration ?? 0
        if duration.isFinite, duration > 0, player.currentTime().seconds >= duration - 0.4 {
            player.seek(to: .zero)
        }
        player.play()
        isPaused = false
    }

    func setInlineVisible(_ visible: Bool) {
        isInlineVisible = visible
        visibilityTask?.cancel()
        if visible {
            #if canImport(UIKit)
            if isPictureInPictureActive {
                pictureInPictureController?.stopPictureInPicture()
            }
            #endif
            return
        }
        visibilityTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            for _ in 0 ..< 8 {
                guard let self, !Task.isCancelled, !self.isInlineVisible,
                      self.userStartedPlayback, self.phase == .playing,
                      self.player?.timeControlStatus == .playing else { return }
                if self.tryStartPictureInPicture() { return }
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    func stop() {
        startTask?.cancel()
        startTask = nil
        playbackMonitorTask?.cancel()
        playbackMonitorTask = nil
        visibilityTask?.cancel()
        visibilityTask = nil
        removeEndBoundaryObserver()
        player?.pause()
        player = nil
        phase = .idle
        isPaused = false
        playbackAccessibilityValue = String(localized: "Loading")
        userStartedPlayback = false
        let coordinator = coordinator
        let stream = activeStream
        activeStream = nil
        Task {
            if let stream { await coordinator?.stop(stream: stream) }
        }
    }

    private func preparePlayback() async {
        if let activeStream, let coordinator {
            self.activeStream = nil
            await coordinator.stop(stream: activeStream)
        }
        removeEndBoundaryObserver()
        player?.pause()
        player = nil
        guard let coordinator else {
            phase = .failed(OpenClientVideoStreamError.unavailable.localizedDescription)
            return
        }
        var startedStream: OpenClientVideoStream?
        do {
            let stream = try await coordinator.start(payload: payload)
            startedStream = stream
            try Task.checkCancellation()
            activeStream = stream
            try Self.configureAudioSession()
            let asset = AVURLAsset(url: stream.playlistURL)
            guard try await asset.load(.isPlayable) else {
                throw OpenClientVideoStreamError.server(String(localized: "The video format is not playable on this device."))
            }
            let duration = try? await asset.load(.duration)
            try Task.checkCancellation()
            let item = AVPlayerItem(asset: asset)
            let player = AVPlayer(playerItem: item)
            player.actionAtItemEnd = .pause
            self.player = player
            let assetDuration = duration?.seconds
            let playbackDuration = if let assetDuration, assetDuration.isFinite, assetDuration > 0 {
                assetDuration
            } else {
                payload.duration
            }
            installEndBoundaryObserver(player: player, duration: playbackDuration)
            phase = .playing
            isPaused = false
            player.play()
            playbackMonitorTask = Task { @MainActor [weak self] in
                await self?.monitorPlayback(player: player, item: item)
            }
        } catch is CancellationError {
            if let startedStream { await coordinator.stop(stream: startedStream) }
        } catch {
            if let startedStream { await coordinator.stop(stream: startedStream) }
            if activeStream?.id == startedStream?.id { activeStream = nil }
            phase = .failed(error.localizedDescription)
        }
    }

    private func installEndBoundaryObserver(player: AVPlayer, duration: Double?) {
        removeEndBoundaryObserver()
        guard let duration, duration.isFinite, duration > 0.35 else { return }
        let holdTime = CMTime(seconds: duration - 0.2, preferredTimescale: 600)
        endBoundaryObserver = player.addBoundaryTimeObserver(forTimes: [NSValue(time: holdTime)], queue: .main) { [weak self, weak player] in
            Task { @MainActor in
                guard let self, let player else { return }
                player.pause()
                player.seek(to: holdTime, toleranceBefore: .zero, toleranceAfter: .zero)
                self.isPaused = true
            }
        }
        endBoundaryObserverPlayer = player
    }

    private func removeEndBoundaryObserver() {
        guard let endBoundaryObserver, let player = endBoundaryObserverPlayer else { return }
        player.removeTimeObserver(endBoundaryObserver)
        self.endBoundaryObserver = nil
        endBoundaryObserverPlayer = nil
    }

    private func monitorPlayback(player: AVPlayer, item: AVPlayerItem) async {
        for _ in 0 ..< 150 {
            guard !Task.isCancelled else { return }
            if item.status == .failed {
                phase = .failed(item.error?.localizedDescription ?? playbackErrorMessage(for: item))
                playbackAccessibilityValue = String(localized: "Failed")
                return
            }
            if player.timeControlStatus == .playing, player.currentTime().seconds > 0.05 {
                playbackAccessibilityValue = String(localized: "Playing")
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard !Task.isCancelled else { return }
        phase = .failed(playbackErrorMessage(for: item))
        playbackAccessibilityValue = String(localized: "Failed")
    }

    private func playbackErrorMessage(for item: AVPlayerItem) -> String {
        item.errorLog()?.events.last?.errorComment ?? String(localized: "The video stream did not begin playback.")
    }

    private static func configureAudioSession() throws {
        #if canImport(UIKit)
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .moviePlayback)
        try session.setActive(true)
        #endif
    }
}

private struct OpenClientVisualVideoHeader: View {
    let payload: OpenClientVisualVideoPayload

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "play.rectangle.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.pink)
                .frame(width: 38, height: 38)
                .background(.pink.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(payload.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(payload.file.name) · \(payload.file.sizeBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }
}

private struct OpenClientVisualVideoPreview: View {
    enum Mode {
        case idle
        case preparing
        case failed(String)
    }

    let payload: OpenClientVisualVideoPayload
    let mode: Mode
    let onRetry: () -> Void

    var body: some View {
        OpenClientAdaptiveMediaLayout(aspectRatio: payload.displayAspectRatio) {
            ZStack {
                Color.black

                if let cover = payload.cover {
                    openClientPlatformImage(cover.platformImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .blur(radius: 7)
                        .scaleEffect(1.04)
                        .clipped()
                }

                Color.black.opacity(overlayOpacity)

                OpenClientVisualVideoPreviewOverlay(mode: mode, onRetry: onRetry)
                    .padding(16)
            }
            .clipped()
        }
    }

    private var overlayOpacity: Double {
        switch mode {
        case .idle:
            0.16
        case .preparing:
            0.36
        case .failed:
            0.5
        }
    }
}

private struct OpenClientVisualVideoPreviewOverlay: View {
    let mode: OpenClientVisualVideoPreview.Mode
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        switch mode {
        case .idle:
            Image(systemName: "play.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 58, height: 58)
                .background(.pink, in: Circle())
                .shadow(color: .black.opacity(0.24), radius: 12, y: 5)
                .accessibilityLabel("Play")
        case .preparing:
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("Preparing Video")
                    .font(.subheadline.weight(.semibold))
                Text("Starting HLS on the OpenCode host")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 10) {
                Label("Video Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .modifier(AppAccentActionModifier())
                    .controlSize(.small)
            }
            .foregroundStyle(.white)
        }
    }
}

#if canImport(UIKit)
private struct OpenClientInlineVideoPlayer: View {
    let player: AVPlayer
    let payload: OpenClientVisualVideoPayload
    @ObservedObject var playback: OpenClientVisualVideoPlaybackController

    @State private var showsControls = true

    var body: some View {
        OpenClientAdaptiveMediaLayout(aspectRatio: payload.displayAspectRatio) {
            ZStack(alignment: .bottom) {
                Color.black

                OpenClientPlayerLayerView(player: player, playback: playback)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .allowsHitTesting(false)

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeInOut(duration: 0.18)) {
                            showsControls.toggle()
                        }
                    }

                if showsControls {
                    HStack(spacing: 18) {
                        Button {
                            playback.togglePlayback()
                        } label: {
                            Image(systemName: playback.isPaused ? "play.fill" : "pause.fill")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .opencodeActionGlass(clear: true, size: 44, in: Circle())
                        .accessibilityLabel(playback.isPaused ? LocalizedStringResource("Play") : LocalizedStringResource("Pause"))

                        Spacer()

                        Button {
                            playback.startPictureInPicture()
                        } label: {
                            Image(systemName: "pip.enter")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .opencodeActionGlass(clear: true, size: 44, in: Circle())
                        .disabled(!AVPictureInPictureController.isPictureInPictureSupported())
                        .accessibilityLabel("Picture in Picture")

                        Button {
                            playback.presentFullscreen()
                        } label: {
                            Image(systemName: "arrow.up.left.and.arrow.down.right")
                                .frame(width: 44, height: 44)
                                .contentShape(Circle())
                        }
                        .opencodeActionGlass(clear: true, size: 44, in: Circle())
                        .accessibilityLabel("Enter Full Screen")
                    }
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
                    .zIndex(1)
                    .transition(.opacity)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .clipped()
    }
}

private struct OpenClientPlayerLayerView: UIViewRepresentable {
    let player: AVPlayer
    let playback: OpenClientVisualVideoPlaybackController

    func makeUIView(context: Context) -> OpenClientPlayerLayerHostView {
        let view = OpenClientPlayerLayerHostView()
        view.playback = playback
        view.playerLayer.player = player
        playback.attach(playerLayer: view.playerLayer, window: view.window)
        return view
    }

    func updateUIView(_ view: OpenClientPlayerLayerHostView, context: Context) {
        view.playback = playback
        if view.playerLayer.player !== player {
            view.playerLayer.player = player
        }
        playback.attach(playerLayer: view.playerLayer, window: view.window)
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        uiView: OpenClientPlayerLayerHostView,
        context: Context
    ) -> CGSize? {
        guard let width = proposal.width else { return nil }
        return CGSize(width: width, height: width * 9 / 16)
    }

    static func dismantleUIView(_ view: OpenClientPlayerLayerHostView, coordinator: Void) {
        guard let playback = view.playback else {
            view.playerLayer.player = nil
            return
        }
        playback.detach(playerLayer: view.playerLayer)
    }
}

extension OpenClientVisualVideoPlaybackController: @preconcurrency AVPictureInPictureControllerDelegate, UIAdaptivePresentationControllerDelegate {
    func attach(playerLayer: AVPlayerLayer, window: UIWindow?) {
        updatePresentationWindow(window)
        playerLayer.player = player
        if isPictureInPictureActive, self.playerLayer !== playerLayer {
            pendingPlayerLayer = playerLayer
            return
        }
        activate(playerLayer: playerLayer)
    }

    func detach(playerLayer: AVPlayerLayer) {
        guard self.playerLayer === playerLayer else {
            playerLayer.player = nil
            return
        }
        setInlineVisible(false)
        // Retain the layer as the PiP content source after its collection cell is recycled.
    }

    func startPictureInPicture() {
        _ = tryStartPictureInPicture()
    }

    private func tryStartPictureInPicture() -> Bool {
        guard AVPictureInPictureController.isPictureInPictureSupported(),
              pictureInPictureController?.isPictureInPicturePossible == true,
              pictureInPictureController?.isPictureInPictureActive != true else { return false }
        pictureInPictureController?.startPictureInPicture()
        return true
    }

    func presentFullscreen() {
        guard fullscreenController == nil, let player,
              let presenter = Self.topViewController(from: presentationRootViewController()) else { return }
        let controller = OpenClientFullscreenVideoController()
        controller.player = player
        controller.showsPlaybackControls = true
        controller.allowsPictureInPicturePlayback = true
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.modalPresentationStyle = .fullScreen
        controller.onDisappear = { [weak self] in
            self?.fullscreenController = nil
        }
        controller.presentationController?.delegate = self
        fullscreenController = controller
        presenter.present(controller, animated: true) {
            player.play()
        }
    }

    func pictureInPictureControllerWillStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = true
    }

    func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        isPictureInPictureActive = false
        if let pendingPlayerLayer {
            self.pendingPlayerLayer = nil
            activate(playerLayer: pendingPlayerLayer)
        }
    }

    func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        fullscreenController = nil
    }

    func updatePresentationWindow(_ window: UIWindow?) {
        if let window { presentationWindow = window }
    }

    private func presentationRootViewController() -> UIViewController? {
        if let rootViewController = presentationWindow?.rootViewController {
            return rootViewController
        }
        return UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    private static func topViewController(from controller: UIViewController?) -> UIViewController? {
        if let presented = controller?.presentedViewController {
            return topViewController(from: presented)
        }
        if let navigation = controller as? UINavigationController {
            return topViewController(from: navigation.visibleViewController)
        }
        if let tab = controller as? UITabBarController {
            return topViewController(from: tab.selectedViewController)
        }
        return controller
    }

    private func activate(playerLayer: AVPlayerLayer) {
        guard self.playerLayer !== playerLayer else { return }
        self.playerLayer = playerLayer
        pictureInPictureController = AVPictureInPictureController(playerLayer: playerLayer)
        pictureInPictureController?.delegate = self
        pictureInPictureController?.canStartPictureInPictureAutomaticallyFromInline = true
    }
}

private final class OpenClientFullscreenVideoController: AVPlayerViewController {
    var onDisappear: (() -> Void)?

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        onDisappear?()
    }
}

private final class OpenClientPlayerLayerHostView: UIView {
    weak var playback: OpenClientVisualVideoPlaybackController?
    override class var layerClass: AnyClass { AVPlayerLayer.self }

    var playerLayer: AVPlayerLayer {
        layer as! AVPlayerLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        playerLayer.videoGravity = .resizeAspect
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        playback?.updatePresentationWindow(window)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
#else
private struct OpenClientInlineVideoPlayer: View {
    let player: AVPlayer
    let payload: OpenClientVisualVideoPayload
    @ObservedObject var playback: OpenClientVisualVideoPlaybackController

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(payload.displayAspectRatio, contentMode: .fit)
    }
}
#endif
