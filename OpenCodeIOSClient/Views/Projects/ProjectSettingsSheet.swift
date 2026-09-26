import SwiftUI

struct ProjectSettingsSheet: View {
    @ObservedObject var facade: ProjectFacade
    let connection: ConnectionFacade
    let configurations: ConfigurationsFacade
    let bridge: OpenClientBridgeFacade?
    @State private var navigationPath = NavigationPath()
    @State private var selectedActionCommandName = ""
    @State private var selectedActionIconName = "bolt.fill"
    @State private var symbolPickerContext: ProjectActionSymbolPickerContext?

    var body: some View {
        let snapshot = facade.settingsSnapshot

        NavigationStack(path: $navigationPath) {
            Form {
                Section {
                    NavigationLink {
                        RootConfigurationsView(facade: connection)
                    } label: {
                        Label("Global Settings", systemImage: "gearshape")
                    }
                    .accessibilityIdentifier("project.settings.global-settings")

                    NavigationLink {
                        ConfigurationsView(viewModel: configurations, connection: connection, bridge: bridge, navigationPath: $navigationPath)
                    } label: {
                        Label("Connection Settings", systemImage: "slider.horizontal.3")
                    }
                    .accessibilityIdentifier("project.settings.configurations")
                }

                Section("Sessions") {
                    Picker("Card Style", selection: Binding(
                        get: { facade.settingsSnapshot.sessionCardStyle },
                        set: { facade.setSessionCardStyle($0) }
                    )) {
                        ForEach(SessionCardStyle.allCases) { style in
                            Text(sessionCardStyleTitle(style)).tag(style)
                        }
                    }
                    .pickerStyle(.segmented)
                    .accessibilityIdentifier("project.settings.sessionCardStyle")

                    if snapshot.sessionCardStyle == .activity {
                        Toggle("Show Last User Message", isOn: Binding(
                            get: { facade.settingsSnapshot.showsActivityLastUserMessage },
                            set: { facade.setShowsActivityLastUserMessage($0) }
                        ))
                        .accessibilityIdentifier("project.settings.showActivityLastUserMessage")
                    }

#if !targetEnvironment(macCatalyst)
                    if !connection.isV2Connection {
                    Toggle("Auto-start Live Activity", isOn: Binding(
                        get: { facade.settingsSnapshot.isLiveActivityAutoStartEnabled },
                        set: { facade.setLiveActivityAutoStartEnabled($0) }
                    ))

                    Text("Start a Live Activity automatically when a session begins working in this project.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    }
#endif
                }

                if facade.supportsProjectActions {
                    Section("Actions") {
                        if snapshot.hasProUnlock {
                            actionEditor(snapshot)
                        } else {
                            lockedActions
                        }
                        if !facade.actionRunHistory.isEmpty {
                            DisclosureGroup("Action Run History") {
                                ForEach(facade.actionRunHistory) { run in
                                    VStack(alignment: .leading, spacing: 4) {
                                        HStack {
                                            Text(verbatim: "/\(run.commandName)")
                                            Spacer()
                                            Text(run.createdAt, format: .dateTime.month().day().hour().minute())
                                                .foregroundStyle(.secondary)
                                        }
                                        Text(actionRunStatus(run))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                        if run.sessionID != nil {
                                            Button("Show Session") {
                                                Task { await facade.recoverActionRun(id: run.id) }
                                            }
                                        } else {
                                            Text("Session creation could not be confirmed. Check the server before running this action again.")
                                                .font(.caption)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }

                Section("Workspaces") {
                    if !facade.supportsWorkspaceManagement {
                        Text("Workspace management is unavailable on this server.")
                            .foregroundStyle(.secondary)
                    } else {
                    Toggle("Show Workspaces", isOn: Binding(
                        get: { facade.settingsSnapshot.isProjectWorkspacesEnabled },
                        set: { isEnabled in
                            Task { await facade.setWorkspacesEnabled(isEnabled) }
                        }
                    ))
                    .disabled(!snapshot.hasGitProject)

                    Text(workspacesDescription(snapshot))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                    if snapshot.hasGitProject && facade.requiresWorktreeDestinationParent {
                        TextField("Destination Parent Directory", text: Binding(
                            get: { facade.worktreeDestinationParent },
                            set: { facade.worktreeDestinationParent = $0 }
                        ))
                        .opencodeDisableTextAutocapitalization()
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("workspace.destinationParent")
                        Text("Choose an absolute path on the server. New worktrees are created inside this directory.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    }
                }
                if !facade.allowsProjectMetadataEditing {
                    Section("Project Appearance") {
                        Text("Project colors and images are read-only on this server.")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Project Settings")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Done") {
                        facade.dismissSettings()
                    }
                }
            }
        }
        .sheet(item: $symbolPickerContext) { context in
            ProjectActionSymbolPickerSheet(selectedSymbolName: context.selectedSymbolName) { symbolName in
                if let actionID = context.actionID {
                    facade.updateActionIcon(actionID: actionID, iconName: symbolName)
                } else {
                    selectedActionIconName = symbolName
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private func actionEditor(_ snapshot: ProjectFacade.SettingsSnapshot) -> some View {
        if snapshot.actions.isEmpty {
            Text("Configure commands as quick Actions. Sessions stay on the server. Successful runs are hidden locally and can be restored from Action Run History.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(snapshot.actions) { item in
                ProjectActionSettingsRow(
                    action: item.action,
                    command: item.command,
                    phase: item.phase,
                    onPickIcon: {
                        symbolPickerContext = ProjectActionSymbolPickerContext(actionID: item.action.id, selectedSymbolName: item.action.iconName)
                    },
                    onDelete: {
                        facade.removeAction(item.action)
                    }
                )
            }
            .onMove { offsets, destination in
                facade.moveActions(from: offsets, to: destination)
            }
        }

        if snapshot.addableCommands.isEmpty {
            Text(snapshot.eligibleCommands.isEmpty ? LocalizedStringResource("No project commands are available yet.") : LocalizedStringResource("All available commands are already configured as Actions."))
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Picker("Command", selection: $selectedActionCommandName) {
                Text("Choose Command").tag("")
                ForEach(snapshot.addableCommands) { command in
                    Text("/\(command.name)").tag(command.name)
                }
            }

            Button {
                symbolPickerContext = ProjectActionSymbolPickerContext(actionID: nil, selectedSymbolName: selectedActionIconName)
            } label: {
                HStack {
                    Text("Icon")
                    Spacer()
                    Image(systemName: selectedActionIconName)
                        .font(.headline)
                    Text(selectedActionIconName)
                        .foregroundStyle(.secondary)
                }
            }

            Button("Add Action") {
                facade.addAction(commandName: selectedActionCommandName, iconName: selectedActionIconName)
                selectedActionCommandName = ""
                selectedActionIconName = "bolt.fill"
            }
            .disabled(selectedActionCommandName.isEmpty)
        }
    }

    private func actionRunStatus(_ run: ProjectActionRun) -> LocalizedStringResource {
        if run.requiresAttention { return "Needs Attention" }
        switch run.state {
        case .creating: return "Creating Session"
        case .runningCommand: return "Running Command"
        case .checkingResult: return "Checking Result"
        case .succeeded: return run.isHidden ? "Succeeded, Hidden Locally" : "Succeeded"
        case .failed: return "Failed or Unconfirmed"
        case .interrupted: return "Interrupted or Unconfirmed"
        }
    }

    private var lockedActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Actions are a Pro feature", systemImage: "bolt.fill")
                .font(.headline)

            Text("Run project commands in dedicated sessions. Successful runs are hidden locally, never deleted, and remain recoverable.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Unlock Actions") {
                facade.presentActionsPaywall()
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    private func workspacesDescription(_ snapshot: ProjectFacade.SettingsSnapshot) -> LocalizedStringResource {
        if snapshot.hasGitProject {
            return "Group sessions by the main worktree and any OpenCode sandbox worktrees for this project."
        }

        return "Workspaces are available for git projects."
    }
}

private struct ProjectActionSettingsRow: View {
    let action: OpenCodeAction
    let command: OpenCodeCommand?
    let phase: OpenCodeActionRunPhase?
    let onPickIcon: () -> Void
    let onDelete: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Button(action: onPickIcon) {
                Image(systemName: action.iconName)
                    .font(.headline)
                    .frame(width: 34, height: 34)
                    .background(.tint.opacity(0.12), in: Circle())
            }
            .buttonStyle(.plain)

            VStack(alignment: .leading, spacing: 3) {
                Text("/\(action.commandName)")
                    .font(.subheadline.weight(.semibold))

                if let phase {
                    Text(actionSettingsPhaseTitle(phase))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if command == nil {
                    Text("Command unavailable")
                        .font(.caption)
                        .foregroundStyle(.red)
                } else if let description = command?.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 0)

            if phase != nil {
                ProgressView()
                    .controlSize(.small)
            }

            Button(role: .destructive, action: onDelete) {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }
}

private func sessionCardStyleTitle(_ style: SessionCardStyle) -> LocalizedStringResource {
    switch style {
    case .compact: "Compact"
    case .simple: "Default"
    case .activity: "Activity"
    }
}

private func actionSettingsPhaseTitle(_ phase: OpenCodeActionRunPhase) -> LocalizedStringResource {
    switch phase {
    case .runningCommand: "Running command"
    case .checkingResult: "Checking result"
    }
}

private struct ProjectActionSymbolPickerContext: Identifiable {
    let actionID: UUID?
    let selectedSymbolName: String

    var id: String { actionID?.uuidString ?? "new" }
}

private struct ProjectActionSymbolPickerSheet: View {
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    let selectedSymbolName: String
    let onSelect: (String) -> Void

    private let columns = [GridItem(.adaptive(minimum: 76), spacing: 12)]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(filteredSymbols, id: \.self) { symbolName in
                        Button {
                            onSelect(symbolName)
                            dismiss()
                        } label: {
                            VStack(spacing: 8) {
                                Image(systemName: symbolName)
                                    .font(.title3.weight(.semibold))
                                    .frame(width: 44, height: 44)
                                    .background(symbolName == selectedSymbolName ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06), in: Circle())

                                Text(symbolName)
                                    .font(.caption2)
                                    .lineLimit(1)
                                    .minimumScaleFactor(0.7)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(8)
                            .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .searchable(text: $query, prompt: "Search symbols")
            .navigationTitle("Action Icon")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var filteredSymbols: [String] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return projectActionSymbolNames }
        let lowercased = trimmed.lowercased()
        return projectActionSymbolNames.filter { $0.lowercased().contains(lowercased) }
    }
}

private let projectActionSymbolNames = [
    "bolt.fill", "play.fill", "hammer.fill", "wrench.and.screwdriver.fill", "checkmark.seal.fill", "exclamationmark.triangle.fill",
    "ladybug.fill", "testtube.2", "shippingbox.fill", "arrow.triangle.2.circlepath", "wand.and.sparkles", "sparkles",
    "doc.text.fill", "doc.badge.gearshape", "terminal.fill", "chevron.left.forwardslash.chevron.right", "curlybraces", "cpu.fill",
    "brain.head.profile", "magnifyingglass", "folder.fill", "tray.and.arrow.down.fill", "paperplane.fill", "flame.fill",
    "iphone", "iphone.gen3", "ipad", "macbook", "desktopcomputer", "macmini", "display", "applewatch", "appletv", "visionpro",
    "star.fill", "flag.fill", "bookmark.fill", "pin.fill", "clock.fill", "timer",
    "bell.fill", "shield.fill", "lock.fill", "key.fill", "network", "server.rack",
    "antenna.radiowaves.left.and.right", "icloud.fill", "externaldrive.fill", "memorychip.fill", "gearshape.fill", "slider.horizontal.3",
    "list.bullet.clipboard.fill", "text.badge.checkmark", "chart.bar.fill", "waveform", "camera.macro", "paintbrush.fill"
]
