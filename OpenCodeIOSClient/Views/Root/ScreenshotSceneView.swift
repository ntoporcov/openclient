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
    }

    @ViewBuilder
    private var screenshotContent: some View {
        switch scene {
        case .connection, .recentServers:
            NavigationStack {
                ConnectionView(viewModel: viewModel)
            }
        case .projects:
            if isRunningOniPad {
                RootView(viewModel: viewModel)
            } else {
                NavigationStack {
                    ProjectListView(viewModel: viewModel) {}
                }
            }
        case .sessions:
            if isRunningOniPad {
                RootView(viewModel: viewModel)
            } else {
                NavigationStack {
                    SessionListView(viewModel: viewModel) {}
                        .navigationTitle("Sessions")
                }
            }
        case .chat, .permission, .question:
            if isRunningOniPad {
                RootView(viewModel: viewModel)
            } else {
                NavigationStack {
                    ChatView(viewModel: viewModel, sessionID: OpenClientScreenshotData.releaseSession.id)
                }
            }
        case .paywall:
            OpenClientPaywallView(
                viewModel: viewModel,
                purchaseManager: viewModel.purchaseManager,
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
        case .liveActivity:
            LiveActivityScreenshotView(
                session: OpenClientScreenshotData.releaseSession,
                project: OpenClientScreenshotData.repoProject,
                permission: OpenClientScreenshotData.permission,
                question: OpenClientScreenshotData.questionRequest
            )
        }
    }

    private var isRunningOniPad: Bool {
        UIDevice.current.userInterfaceIdiom == .pad
    }
}
#endif
#endif
