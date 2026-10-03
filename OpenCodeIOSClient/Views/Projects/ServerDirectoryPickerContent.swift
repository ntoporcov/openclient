import SwiftUI

struct ServerDirectoryPickerContent: View {
    @Binding var query: String
    let searchRoot: String
    let directories: [String]
    let selectedDirectory: String?
    let isLoading: Bool
    let errorMessage: String?
    var selectionEnabled = true
    var actionTitle: LocalizedStringResource = "Select"
    var systemImage = "folder.badge.plus"
    let displayPath: (String) -> String
    let onBrowse: (String) -> Void
    let onSelect: (String) -> Void

    var body: some View {
        List {
            Section("Directory") {
                TextField("Search under \(searchRoot)", text: $query)
                    .opencodeDisableTextAutocapitalization()
                    .autocorrectionDisabled()
                    .disabled(isLoading)
                Text("Select an existing directory on the server.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let errorMessage {
                Section { Text(verbatim: errorMessage).foregroundStyle(.red) }
            }
            if let selectedDirectory {
                Section("Selected Directory") {
                    VStack(alignment: .leading, spacing: 12) {
                        Button { onSelect(selectedDirectory) } label: {
                            ProjectRow(title: displayPath(selectedDirectory).split(separator: "/").last.map(String.init) ?? selectedDirectory,
                                subtitle: displayPath(selectedDirectory), systemImage: systemImage, isSelected: true)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading || !selectionEnabled)
                        Button { onSelect(selectedDirectory) } label: { Text(actionTitle) }
                            .buttonStyle(.borderedProminent)
                            .modifier(AppAccentActionModifier())
                            .disabled(isLoading || !selectionEnabled)
                            .accessibilityIdentifier("directory.select")
                    }
                    .padding(.vertical, 4)
                }
            }
            Section("Directories") {
                if directories.isEmpty {
                    if isLoading { ProgressView() }
                    else { Text("No directories found").foregroundStyle(.secondary) }
                } else {
                    ForEach(directories, id: \.self) { directory in
                        Button { onBrowse(directory) } label: {
                            let path = displayPath(directory)
                            ProjectRow(title: path.split(separator: "/").last.map(String.init) ?? path,
                                subtitle: path, systemImage: systemImage, isSelected: selectedDirectory == directory)
                        }
                        .buttonStyle(.plain)
                        .disabled(isLoading)
                    }
                }
            }
        }
    }
}
