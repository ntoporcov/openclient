import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

@main
struct OpenCodeIOSClientApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var viewModel: AppViewModel
#if DEBUG
    private let screenshotScene: OpenClientScreenshotScene?
#endif

    init() {
#if DEBUG
        let screenshotScene = OpenClientScreenshotScene.current
        self.screenshotScene = screenshotScene
        if let screenshotScene {
            _viewModel = StateObject(wrappedValue: AppViewModel.screenshot(scene: screenshotScene))
        } else {
            _viewModel = StateObject(wrappedValue: AppViewModel())
        }
#else
        _viewModel = StateObject(wrappedValue: AppViewModel())
#endif
    }

    var body: some Scene {
        WindowGroup {
            Group {
#if DEBUG
                if let screenshotScene {
                    ScreenshotSceneView(scene: screenshotScene, viewModel: viewModel)
                } else {
                    RootView(viewModel: viewModel)
                }
#else
                RootView(viewModel: viewModel)
#endif
            }
            .onOpenURL { url in
                Task { await viewModel.handleLiveActivityURL(url) }
            }
            .onChange(of: scenePhase) { _, phase in
                guard phase == .active else { return }
                viewModel.scheduleForegroundChatCatchUp(reason: "app scene active")
            }
#if canImport(UIKit)
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
                viewModel.scheduleForegroundChatCatchUp(reason: "application did become active")
            }
#endif
        }
    }
}
