import SwiftUI

struct RootView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var preferredCompactColumn: NavigationSplitViewColumn = .sidebar

    var body: some View {
        Group {
            if viewModel.isConnected {
                NavigationSplitView(preferredCompactColumn: $preferredCompactColumn) {
                    ProjectListView(viewModel: viewModel) {
                        preferredCompactColumn = .content
                    }
                } content: {
                    SessionListView(viewModel: viewModel) {
                        preferredCompactColumn = .detail
                    }
                } detail: {
                    if let session = viewModel.selectedSession {
                        ChatView(viewModel: viewModel, session: session)
                    } else {
                        ContentUnavailableView("Select a Session", systemImage: "bubble.left.and.bubble.right")
                    }
                }
                .onChange(of: viewModel.selectedSession?.id) { _, sessionID in
                    if sessionID == nil {
                        preferredCompactColumn = .content
                    }
                }
            } else {
                NavigationStack {
                    ConnectionView(viewModel: viewModel)
                        .navigationTitle("OpenCode")
                        .navigationBarTitleDisplayMode(.large)
                }
            }
        }
    }
}
