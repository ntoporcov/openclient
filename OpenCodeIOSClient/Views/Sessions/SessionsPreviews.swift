import SwiftUI

#Preview("Session List") {
    NavigationStack {
        SessionListView(
            viewModel: AppViewModel.preview(permissions: [OpenCodePreviewData.permission]),
            onSessionChosen: {}
        )
    }
}

#Preview("Session Create Sheet") {
    NavigationStack {
        SessionListView(
            viewModel: AppViewModel.preview(isShowingCreateSessionSheet: true, draftTitle: "UI polish"),
            onSessionChosen: {}
        )
    }
}

#Preview("Create Session Sheet") {
    CreateSessionSheet(viewModel: AppViewModel.preview(isShowingCreateSessionSheet: true, draftTitle: "UI polish"))
}

#Preview("Session Avatar") {
    SessionAvatar(title: "Preview polish pass")
        .padding()
}

#Preview("Session Row") {
    List {
        SessionRow(viewModel: AppViewModel.preview(permissions: [OpenCodePreviewData.permission]), session: OpenCodePreviewData.primarySession)
    }
    .listStyle(.plain)
}
