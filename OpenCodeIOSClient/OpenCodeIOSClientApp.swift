import SwiftUI

@main
struct OpenCodeIOSClientApp: App {
    @StateObject private var viewModel = AppViewModel()

    var body: some Scene {
        WindowGroup {
            RootView(viewModel: viewModel)
        }
    }
}
