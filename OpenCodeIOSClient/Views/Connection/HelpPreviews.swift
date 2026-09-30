import SwiftUI

#if DEBUG
#Preview("Help Feed") {
    NavigationStack {
        HelpView(connection: AppViewModel.preview(isConnected: false).connectionFacade)
    }
}

#Preview("Expanded Article") {
    NavigationStack {
        HelpView(connection: AppViewModel.preview(isConnected: false).connectionFacade, initiallySelectedArticleID: "what-is-opencode")
    }
}
#endif
