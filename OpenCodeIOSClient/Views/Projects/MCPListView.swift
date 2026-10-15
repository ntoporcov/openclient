import SwiftUI

struct MCPListView: View {
    @ObservedObject var facade: MCPFacade

    var body: some View {
        if facade.snapshot.managed != nil {
            ManagedMCPListView(facade: facade)
        } else {
        MCPListContent(
            snapshot: facade.snapshot,
            onLoad: {
                await facade.loadIfNeeded()
            },
            onToggle: { name in
                await facade.toggleServer(name: name)
            }
        )
        }
    }
}

private struct MCPListContent: View {
    let snapshot: MCPFacade.Snapshot
    let onLoad: () async -> Void
    let onToggle: (String) async -> Void

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
                        Text(
                            "\(snapshot.connectedServerCount) of \(snapshot.servers.count) enabled",
                            comment: "MCP server summary. The first value is the enabled count and the second is the total server count."
                        )
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
                } else if snapshot.servers.isEmpty {
                    Text("No configured MCP servers.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(snapshot.servers) { server in
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

                    statusText
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

    private var statusText: Text {
        switch server.status.status {
        case "connected": Text("Connected")
        case "disabled": Text("Disabled")
        case "failed": Text("Failed")
        case "needs_auth": Text("Needs Auth")
        case "needs_client_registration": Text("Needs Registration")
        default: Text(server.status.displayStatus)
        }
    }
}

#if DEBUG
#Preview {
    MCPListView(
        facade: MCPFacade(
            store: MCPStore(isReady: true),
            clientProvider: { OpenCodeAPIClient(config: OpenCodeServerConfig()) },
            directoryProvider: { nil }
        )
    )
}
#endif
