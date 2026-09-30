import SwiftUI

struct OpenClientAnnouncementsView: View {
    let connection: ConnectionFacade
    let bridge: OpenClientBridgeFacade?
    @State private var selectedRelease: OpenClientReleaseNotes?

    var body: some View {
        List(OpenClientReleaseNotesCatalog.releases.reversed()) { release in
            Button {
                selectedRelease = release
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Version \(release.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(release.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text(release.summary)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("announcements.release.\(release.id)")
        }
        .navigationTitle("Announcements")
        .sheet(item: $selectedRelease) { release in
            OpenClientWhatsNewView(release: release, connection: connection, bridge: bridge) {
                selectedRelease = nil
            }
        }
    }
}
