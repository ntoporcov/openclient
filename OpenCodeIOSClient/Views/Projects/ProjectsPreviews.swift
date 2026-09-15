import SwiftUI

#if DEBUG
#Preview("Project List") {
    NavigationStack {
        ProjectListPreview(viewModel: AppViewModel.preview())
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

private struct ProjectListPreview: View {
    @StateObject private var viewModel: AppViewModel

    init(viewModel: AppViewModel) {
        _viewModel = StateObject(wrappedValue: viewModel)
    }

    var body: some View {
        ProjectListView(
            facade: viewModel.projectFacade,
            connection: viewModel.connectionFacade,
            configurations: viewModel.configurationsFacade,
            games: viewModel.funAndGamesFacade,
            providerUsage: viewModel.providerUsageFacade,
            onProjectChosen: {}
        )
    }
}
#endif
