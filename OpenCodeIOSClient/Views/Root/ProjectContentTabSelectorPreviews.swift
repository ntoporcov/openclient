import SwiftUI

#if DEBUG
private struct ProjectContentTabSelectorPreviewHost: View {
    @State private var selection: AppViewModel.ProjectContentTab = .sessions
    let width: CGFloat
    let title: String

    var body: some View {
        VStack(spacing: 0) {
            ProjectContentTabSelector(
                selection: $selection,
                tabs: AppViewModel.ProjectContentTab.allCases
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.headline)
                Text("Selected: \(selection.title)")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(20)

            Spacer()
        }
        .frame(width: width, height: 540)
        .background {
            LinearGradient(
                colors: [
                    Color.blue.opacity(0.18),
                    OpenCodePlatformColor.groupedBackground,
                    Color.purple.opacity(0.14)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }
}

#Preview("Tab Selector - Middle Column") {
    ProjectContentTabSelectorPreviewHost(width: 390, title: "Middle Column")
}

#Preview("Tab Selector - Narrow") {
    ProjectContentTabSelectorPreviewHost(width: 320, title: "Narrow Column")
}

#Preview("Tab Selector - Wide iPad") {
    ProjectContentTabSelectorPreviewHost(width: 520, title: "Wide Column")
}
#endif
