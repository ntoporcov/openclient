import SwiftUI

struct MCPListView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var searchText = ""

    var body: some View {
        MCPListContent(
            snapshot: viewModel.mcpSnapshot,
            searchText: $searchText,
            onLoad: {
                await viewModel.loadMCPStatusIfNeeded()
            },
            onToggle: { name in
                await viewModel.toggleMCPServer(name: name)
            }
        )
    }
}

private struct MCPListContent: View {
    let snapshot: AppViewModel.MCPSnapshot
    @Binding var searchText: String
    let onLoad: () async -> Void
    let onToggle: (String) async -> Void

    private var filteredServers: [OpenCodeMCPServer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return snapshot.servers }
        return snapshot.servers.filter { server in
            server.name.localizedCaseInsensitiveContains(query) || server.status.displayStatus.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.blue, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MCP Servers")
                            .font(.headline)
                        Text("\(snapshot.connectedServerCount) of \(snapshot.servers.count) enabled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if snapshot.isLoading {
                        ProgressView()
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage = snapshot.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Servers") {
                if snapshot.isLoading && snapshot.servers.isEmpty {
                    ProgressView("Loading MCP servers")
                } else if filteredServers.isEmpty {
                    Text(snapshot.servers.isEmpty ? "No configured MCP servers." : "No MCP servers match your search.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredServers) { server in
                        MCPServerRow(
                            server: server,
                            isToggling: snapshot.togglingServerNames.contains(server.name),
                            onToggle: {
                                Task {
                                    await onToggle(server.name)
                                }
                            }
                        )
                    }
                }
            }
        }
        .opencodeGroupedListStyle()
        .searchable(text: $searchText, prompt: "Search MCP servers")
        .task {
            await onLoad()
        }
        .animation(opencodeSelectionAnimation, value: snapshot.servers.map(\.id).joined(separator: "|"))
        .animation(opencodeSelectionAnimation, value: snapshot.togglingServerNames)
    }
}

private struct MCPServerRow: View {
    let server: OpenCodeMCPServer
    let isToggling: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Text(server.status.displayStatus)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                if let error = server.status.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if isToggling {
                ProgressView()
            }

            Toggle("Enabled", isOn: Binding(
                get: { server.status.isConnected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(isToggling)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isToggling else { return }
            onToggle()
        }
    }

    private var statusColor: Color {
        switch server.status.status {
        case "connected":
            return .green
        case "failed", "needs_client_registration":
            return .red
        case "needs_auth":
            return .orange
        default:
            return .secondary
        }
    }
}

#if DEBUG
#Preview {
    MCPListView(viewModel: AppViewModel.preview())
}
#endif
