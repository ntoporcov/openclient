import SwiftUI

struct ProjectSettingsSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var selectedActionCommandName = ""
    @State private var selectedActionIconName = "bolt.fill"
    @State private var symbolPickerContext: ProjectActionSymbolPickerContext?

    var body: some View {
        NavigationStack {
            Form {
                Section("Sessions") {
                    Toggle("Auto-start Live Activity", isOn: Binding(
                        get: { viewModel.isLiveActivityAutoStartEnabled },
                        set: { viewModel.setLiveActivityAutoStartEnabled($0) }
                    ))

                    Text("Start a Live Activity automatically when a session begins working in this project.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                Section("Actions") {
                    if viewModel.hasProUnlock {
                        actionEditor
                    } else {
                        lockedActions
                    }
                }

                Section("Workspaces") {
                    Toggle("Show Workspaces", isOn: Binding(
                        get: { viewModel.isProjectWorkspacesEnabled },
                        set: { isEnabled in
                            viewModel.setProjectWorkspacesEnabled(isEnabled)
                            if isEnabled {
                                Task { await viewModel.loadWorkspaceSessionsIfNeeded() }
                            }
                        }
                    ))
                    .disabled(!viewModel.hasGitProject)

                    Text(workspacesDescription)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Project Settings")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Done") {
                        viewModel.isShowingProjectSettingsSheet = false
                    }
                }
            }
        }
        .sheet(item: $symbolPickerContext) { context in
            ProjectActionSymbolPickerSheet(selectedSymbolName: context.selectedSymbolName) { symbolName in
                if let actionID = context.actionID {
                    viewModel.updateProjectActionIcon(actionID: actionID, iconName: symbolName)
                } else {
                    selectedActionIconName = symbolName
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var actionEditor: some View {
        if viewModel.currentProjectActions.isEmpty {
            Text("Configure commands as quick Actions. They run in temporary sessions and only appear if they need debugging.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            ForEach(viewModel.currentProjectActions) { action in
                ProjectActionSettingsRow(
                    action: action,
                    command: viewModel.actionCommand(for: action),
                    phase: viewModel.actionRunPhase(for: action),
                    onPickIcon: {
                        symbolPickerContext = ProjectActionSymbolPickerContext(actionID: action.id, selectedSymbolName: action.iconName)
                    },
                    onDelete: {
                        viewModel.removeProjectAction(action)
                    }
                )
            }
            .onMove { offsets, destination in
                viewModel.moveProjectActions(fromOffsets: offsets, toOffset: destination)
            }
        }

        if addableActionCommands.isEmpty {
            Text(viewModel.actionEligibleCommands.isEmpty ? "No project commands are available yet." : "All available commands are already configured as Actions.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        } else {
            Picker("Command", selection: $selectedActionCommandName) {
                Text("Choose Command").tag("")
                ForEach(addableActionCommands) { command in
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
                viewModel.addProjectAction(commandName: selectedActionCommandName, iconName: selectedActionIconName)
                selectedActionCommandName = ""
                selectedActionIconName = "bolt.fill"
            }
            .disabled(selectedActionCommandName.isEmpty)
        }
    }

    private var lockedActions: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Actions are a Pro feature", systemImage: "bolt.fill")
                .font(.headline)

            Text("Run project commands in temporary sessions, then only keep the session when the action needs debugging.")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Button("Unlock Actions") {
                viewModel.presentPaywall(reason: .actions)
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding(.vertical, 4)
    }

    private var addableActionCommands: [OpenCodeCommand] {
        let configuredNames = Set(viewModel.currentProjectActions.map(\.commandName))
        return viewModel.actionEligibleCommands.filter { !configuredNames.contains($0.name) }
    }

    private var workspacesDescription: String {
        if viewModel.hasGitProject {
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
                    Text(phase.title)
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
