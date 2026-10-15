import SwiftUI

/// Profile management presentation, shared by project and chat surfaces.
/// Lifecycle is intentionally not presented as MCP connectivity/health.
/// Scope, outcome, and restriction text stays primary for contrast in glass chat panels.
struct ManagedMCPListView: View {
    @ObservedObject var facade: MCPFacade
    @State private var pendingChange: MCPFacade.ManagedToggleRequest?

    private var state: BackendMCPState { facade.snapshot.managed ?? .init() }

    var body: some View {
        List {
            Section {
                Text("Server Profile MCP")
                    .font(.headline)
                Text("Changes affect all projects, chats, and users on this DSH server profile.")
                    .foregroundStyle(.primary)
                    .accessibilityIdentifier("mcp.managed.scope")
                Text("Enabled is the effective plugin setting, including parent configuration. Plugin lifecycle does not indicate MCP connection health.")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                Text("This lists stock MCP plugin declarations exposed by the profile, not the effective tool list for this chat.")
                    .font(.footnote)
                    .foregroundStyle(.primary)
                if state.isLoading { ProgressView("Loading MCP settings") }
            }
            if let error = state.errorMessage {
                Section("Error") { Text(verbatim: error).foregroundStyle(.red) }
            }
            if let notice = state.notice {
                Section("Notice") { Text(verbatim: notice).foregroundStyle(.primary) }
            }
            if !state.isCurrent {
                Section {
                    Text("MCP settings unavailable. Refresh to load this server profile.")
                        .accessibilityIdentifier("mcp.managed.unavailable")
                }
            } else {
                Section("Profile Plugins") {
                    let rows = state.servers.filter { $0.scope == .profile }
                    if rows.isEmpty {
                        Text("No MCP plugin declarations exposed by this profile")
                            .foregroundStyle(.primary)
                            .accessibilityIdentifier("mcp.managed.empty")
                    }
                    ForEach(rows) { server in row(server) }
                }
                let presets = state.servers.filter { if case .agentPreset = $0.scope { return true }; return false }
                if !presets.isEmpty {
                    Section {
                        ForEach(presets) { server in row(server) }
                    } header: {
                        Text("Agent Preset Declarations")
                    } footer: {
                        Text("Preset declarations are read-only here and may depend on runtime conditions. They do not describe a running MCP connection in this chat.")
                    }
                }
            }
        }
        .opencodeGroupedListStyle()
        .navigationTitle("Server Profile MCP")
        .accessibilityIdentifier("mcp.managed.list")
        .toolbar {
            ToolbarItem(placement: .opencodeTrailing) {
                Button {
                    Task { await facade.reload() }
                } label: { Label("Refresh MCP Settings", systemImage: "arrow.clockwise") }
                .disabled(!facade.isAvailable || state.isLoading)
                .accessibilityIdentifier("mcp.managed.refresh")
            }
        }
        .refreshable { await facade.reload() }
        .task(id: facade.managedContextIdentity) { await facade.reload() }
        .onChange(of: facade.managedContextIdentity) { _, _ in pendingChange = nil }
        .confirmationDialog("Change server-profile MCP setting?", isPresented: Binding(
            get: { pendingChange != nil }, set: { if !$0 { pendingChange = nil } }
        ), titleVisibility: .visible, presenting: pendingChange) { request in
            Button(request.enabled ? LocalizedStringKey("Enable for Entire Profile") : LocalizedStringKey("Disable for Entire Profile")) {
                pendingChange = nil
                Task { await facade.confirmManagedToggle(request) }
            }
            .accessibilityIdentifier("mcp.managed.confirm.apply")
            Button("Cancel", role: .cancel) { pendingChange = nil }
                .accessibilityIdentifier("mcp.managed.confirm.cancel")
        } message: { request in
            Text(request.confirmationMessage)
        }
    }

    private func row(_ server: BackendMCPServer) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: server.name).font(.headline)
            if case .agentPreset(_, let name) = server.scope {
                LabeledContent("Agent Preset") { Text(verbatim: name) }
                LabeledContent("Enabled") {
                    if let enabled = server.enabled {
                        if enabled { Text("Yes") } else { Text("No") }
                    } else { Text("Conditional") }
                }
            } else if let enabled = server.enabled {
                Toggle("Enabled", isOn: Binding(get: { enabled }, set: { desired in
                    pendingChange = facade.captureManagedToggle(id: server.id, enabled: desired)
                }))
                .disabled(!facade.isAvailable || !state.isCurrent || state.isLoading || !server.canToggle || server.restriction != nil || state.togglingIDs.contains(server.id))
                .accessibilityIdentifier("mcp.managed.toggle.\(server.id)")
            } else {
                LabeledContent("Enabled") { Text("Unavailable") }
            }
            LabeledContent("Plugin Lifecycle") { phaseLabel(server.phase) }
                .font(.subheadline)
            if state.togglingIDs.contains(server.id) { ProgressView("Updating MCP setting") }
            if let restriction = server.restriction {
                restrictionLabel(restriction).font(.footnote).foregroundStyle(.primary)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("mcp.managed.row.\(server.id)")
    }

    private func phaseLabel(_ phase: BackendMCPPluginPhase?) -> Text {
        switch phase {
        case .pending: Text("Pending")
        case .loading: Text("Loading")
        case .active: Text("Active")
        case .failed: Text("Failed")
        case .unloading: Text("Unloading")
        case nil: Text("Unavailable")
        }
    }

    private func restrictionLabel(_ restriction: BackendMCPRestriction) -> Text {
        switch restriction {
        case .managementUnavailable: Text("Plugin management is unavailable on this server.")
        case .unaddressable: Text("This declaration cannot be changed through the management API.")
        case .preset: Text("Agent preset declarations are read-only.")
        }
    }
}
