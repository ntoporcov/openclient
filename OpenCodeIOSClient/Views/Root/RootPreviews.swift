import SwiftUI

#Preview("Disconnected") {
    RootView(viewModel: AppViewModel.preview(isConnected: false))
}

#Preview("Connected") {
    RootView(viewModel: AppViewModel.preview())
}
