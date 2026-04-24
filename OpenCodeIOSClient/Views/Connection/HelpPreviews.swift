import SwiftUI

#Preview("Help Feed") {
    NavigationStack {
        HelpView()
    }
}

#Preview("Expanded Article") {
    NavigationStack {
        HelpView(initiallySelectedArticleID: "what-is-opencode")
    }
}
