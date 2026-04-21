import SwiftUI

#Preview("Connection Form") {
    NavigationStack {
        ConnectionView(viewModel: AppViewModel.preview(isConnected: false))
            .navigationTitle("OpenCode")
    }
}

#Preview("Reconnect Prompt") {
    NavigationStack {
        ConnectionView(
            viewModel: AppViewModel.preview(
                isConnected: false,
                errorMessage: "Authentication failed",
                showSavedServerPrompt: true,
                hasSavedServer: true
            )
        )
        .navigationTitle("OpenCode")
    }
}
