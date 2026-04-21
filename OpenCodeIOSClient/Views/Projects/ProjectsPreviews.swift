import SwiftUI

#Preview("Project List") {
    NavigationStack {
        ProjectListView(viewModel: AppViewModel.preview()) {}
    }
}

#Preview("Project Row") {
    List {
        ProjectRow(
            title: "opencode-ios-client",
            subtitle: "/Users/mininic/XCodeProjects/opencode-ios-client",
            systemImage: "folder.fill",
            isSelected: true
        )
    }
    .listStyle(.plain)
}
