import SwiftUI
import WidgetKit

struct OpenCodeActionShortcutWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: OpenCodeWidgetKind.actionShortcut,
            intent: OpenCodeActionWidgetConfiguration.self,
            provider: OpenCodeActionShortcutTimelineProvider()
        ) { entry in
            OpenCodeActionShortcutWidgetView(entry: entry)
        }
        .configurationDisplayName("Slash Command")
        .description("Open OpenClient, start a session, and send a slash command.")
        .supportedFamilies([.systemSmall])
    }
}

struct OpenCodeNewSessionShortcutWidget: Widget {
    var body: some WidgetConfiguration {
        AppIntentConfiguration(
            kind: OpenCodeWidgetKind.newSessionShortcut,
            intent: OpenCodeNewSessionWidgetConfiguration.self,
            provider: OpenCodeNewSessionShortcutTimelineProvider()
        ) { entry in
            OpenCodeNewSessionShortcutWidgetView(entry: entry)
        }
        .configurationDisplayName("New Session")
        .description("Open OpenClient and start a blank session in a project.")
        .supportedFamilies([.systemSmall, .systemMedium, .systemLarge])
    }
}

struct OpenCodeActionShortcutEntry: TimelineEntry {
    let date: Date
    let project: OpenCodeWidgetProjectEntity?
    let command: OpenCodeWidgetCommandEntity?
    let model: OpenCodeWidgetModelEntity?
    let reasoning: String?
    let url: URL?
}

struct OpenCodeNewSessionShortcutEntry: TimelineEntry {
    let date: Date
    let project: OpenCodeWidgetProjectEntity?
    let projectChoices: [OpenCodeWidgetProjectEntity]
    let model: OpenCodeWidgetModelEntity?
    let reasoning: String?
    let url: URL?
}

struct OpenCodeActionShortcutTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OpenCodeActionShortcutEntry {
        OpenCodeActionShortcutEntry.preview
    }

    func snapshot(for configuration: OpenCodeActionWidgetConfiguration, in context: Context) async -> OpenCodeActionShortcutEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: OpenCodeActionWidgetConfiguration, in context: Context) async -> Timeline<OpenCodeActionShortcutEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(for configuration: OpenCodeActionWidgetConfiguration) -> OpenCodeActionShortcutEntry {
        let server = resolvedServer(configuration.server, fallbackServerID: configuration.project?.serverID ?? configuration.command?.serverID ?? configuration.model?.serverID)
        let project = resolvedProject(configuration.project, server: server)
        let command = resolvedCommand(configuration.command, server: server, project: project)
        let model = resolvedModel(configuration.model, server: server)
        let reasoning = resolvedReasoning(configuration.reasoning, model: model)
        let serverID = server?.rawServerID ?? server?.id
        let directory = project?.directory ?? command?.directory
        let url = (configuration.model != nil && model == nil) || (configuration.reasoning != nil && reasoning == nil) ? nil : OpenCodeWidgetDeepLink.actionURL(
            serverID: serverID,
            projectID: project?.projectID ?? command?.projectID,
            directory: directory,
            commandName: command?.name,
            providerID: model?.providerID,
            modelID: model?.modelID,
            reasoningVariant: reasoning,
            profile: server?.profile ?? .legacy
        )
        return OpenCodeActionShortcutEntry(date: Date(), project: project, command: command, model: model, reasoning: reasoning, url: url)
    }
}

struct OpenCodeNewSessionShortcutTimelineProvider: AppIntentTimelineProvider {
    func placeholder(in context: Context) -> OpenCodeNewSessionShortcutEntry {
        OpenCodeNewSessionShortcutEntry.preview
    }

    func snapshot(for configuration: OpenCodeNewSessionWidgetConfiguration, in context: Context) async -> OpenCodeNewSessionShortcutEntry {
        entry(for: configuration)
    }

    func timeline(for configuration: OpenCodeNewSessionWidgetConfiguration, in context: Context) async -> Timeline<OpenCodeNewSessionShortcutEntry> {
        Timeline(entries: [entry(for: configuration)], policy: .after(Date().addingTimeInterval(15 * 60)))
    }

    private func entry(for configuration: OpenCodeNewSessionWidgetConfiguration) -> OpenCodeNewSessionShortcutEntry {
        let server = resolvedServer(configuration.server, fallbackServerID: configuration.project?.serverID ?? configuration.model?.serverID)
        let project = resolvedProject(configuration.project, server: server)
        let model = resolvedModel(configuration.model, server: server)
        let reasoning = resolvedReasoning(configuration.reasoning, model: model)
        let invalidSelection = (configuration.project != nil && project == nil)
            || (configuration.model != nil && model == nil) || (configuration.reasoning != nil && reasoning == nil)
        let projectChoices = invalidSelection ? [] : orderedProjects(selected: project, server: server)
        let serverID = server?.rawServerID ?? server?.id
        let url = (configuration.model != nil && model == nil) || (configuration.reasoning != nil && reasoning == nil) ? nil : OpenCodeWidgetDeepLink.newSessionURL(
            serverID: serverID,
            projectID: project?.projectID,
            directory: project?.directory,
            providerID: model?.providerID,
            modelID: model?.modelID,
            reasoningVariant: reasoning,
            profile: server?.profile ?? .legacy
        )
        return OpenCodeNewSessionShortcutEntry(date: Date(), project: project, projectChoices: projectChoices, model: model, reasoning: reasoning, url: url)
    }
}

private struct OpenCodeActionShortcutWidgetView: View {
    let entry: OpenCodeActionShortcutEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            shortcutHeader(title: "COMMAND", systemImage: "bolt.fill", tint: .orange)

            Spacer(minLength: 0)

            if let command = entry.command {
                Text(verbatim: "/\(command.name)")
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(entry.project?.title ?? "OpenClient")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Choose a command")
                    .font(.headline.weight(.semibold))
                    .lineLimit(2)
                Text("Edit widget settings after syncing a project in the app.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            Spacer(minLength: 0)

            shortcutLink(title: "Start", systemImage: "bolt.fill", url: entry.url, tint: .orange)
        }
        .padding(8)
        .containerBackground(for: .widget) {
            Color.clear
        }
    }
}

private struct OpenCodeNewSessionShortcutWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: OpenCodeNewSessionShortcutEntry

    var body: some View {
        Group {
            if family == .systemLarge {
                largeBody
            } else if family == .systemMedium {
                mediumBody
            } else {
                smallBody
            }
        }
        .containerBackground(for: .widget) {
            Color.clear
        }
    }

    private var smallBody: some View {
        VStack(alignment: .leading, spacing: 10) {
            shortcutHeader(title: "SESSION", systemImage: "plus.message.fill", tint: .blue)

            Spacer(minLength: 0)

            Text(entry.project?.title ?? String(localized: "Choose project"))
                .font(.headline.weight(.semibold))
                .lineLimit(2)

            modelLine(model: entry.model, reasoning: entry.reasoning)

            Spacer(minLength: 0)

            shortcutLink(title: "New", systemImage: "plus", url: entry.url, tint: .blue)
        }
        .padding(6)
    }

    private var mediumBody: some View {
        VStack(alignment: .leading, spacing: 9) {
            shortcutHeaderRow(title: "NEW SESSION")
            projectGrid(limit: 4, columnCount: 2, compact: true)
        }
        .padding(6)
    }

    private var largeBody: some View {
        VStack(alignment: .leading, spacing: 11) {
            shortcutHeaderRow(title: "NEW SESSION")
            Text("Pick a project")
                .font(.title3.weight(.semibold))
                .lineLimit(1)
            projectGrid(limit: 8, columnCount: 2, compact: false)
            Spacer(minLength: 0)
        }
        .padding(6)
    }

    private func shortcutHeaderRow(title: LocalizedStringResource) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            shortcutHeader(title: title, systemImage: "plus.message.fill", tint: .blue)
            Spacer(minLength: 0)
            Text(modelSummary)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    private var modelSummary: String {
        let modelTitle = entry.model?.modelName ?? String(localized: "Default")
        guard let reasoning = entry.reasoning else { return modelTitle }
        return String(localized: "\(modelTitle) · \(formattedReasoningTitle(reasoning))")
    }

    @ViewBuilder
    private func projectGrid(limit: Int, columnCount: Int, compact: Bool) -> some View {
        let projects = Array(entry.projectChoices.prefix(limit))
        if projects.isEmpty {
            shortcutEmptyState(title: "No Projects", subtitle: "Open the app to sync projects.")
        } else {
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: 8), count: columnCount),
                alignment: .leading,
                spacing: 8
            ) {
                ForEach(projects) { project in
                    projectLink(project: project, compact: compact)
                }
            }
        }
    }

    @ViewBuilder
    private func projectLink(project: OpenCodeWidgetProjectEntity, compact: Bool) -> some View {
        let url = OpenCodeWidgetDeepLink.newSessionURL(
            serverID: project.rawServerID ?? project.serverID,
            projectID: project.projectID,
            directory: project.directory,
            providerID: entry.model?.providerID,
            modelID: entry.model?.modelID,
            reasoningVariant: entry.reasoning,
            profile: project.profile
        )

        if let url {
            Link(destination: url) {
                projectButton(project: project, compact: compact)
            }
            .buttonStyle(.plain)
        } else {
            projectButton(project: project, compact: compact)
        }
    }

    private func projectButton(project: OpenCodeWidgetProjectEntity, compact: Bool) -> some View {
        HStack(spacing: compact ? 6 : 8) {
            Image(systemName: "plus.circle.fill")
                .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.blue)
            VStack(alignment: .leading, spacing: 2) {
                Text(project.title)
                    .font(compact ? .caption.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !compact, let subtitle = projectSubtitle(project) {
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, minHeight: compact ? 30 : 38, alignment: .leading)
        .padding(.horizontal, compact ? 8 : 10)
        .padding(.vertical, compact ? 5 : 6)
        .background(.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: compact ? 13 : 15, style: .continuous)
                .strokeBorder(.blue.opacity(0.18), lineWidth: 1)
        }
    }

    private func projectSubtitle(_ project: OpenCodeWidgetProjectEntity) -> String? {
        guard let directory = project.directory else { return nil }
        return directory.split(separator: "/").last.map(String.init)
    }
}

@MainActor
@ViewBuilder
private func shortcutHeader(title: LocalizedStringResource, systemImage: String, tint: Color) -> some View {
    HStack(spacing: 7) {
        Image(systemName: systemImage)
            .font(.caption.weight(.bold))
            .foregroundStyle(tint)
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

@MainActor
@ViewBuilder
private func modelLine(model: OpenCodeWidgetModelEntity?, reasoning: String?) -> some View {
    let title = model?.modelName ?? String(localized: "Default model")
    let subtitle = reasoning.map(formattedReasoningTitle)
    VStack(alignment: .leading, spacing: 2) {
        Text(title)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
        if let subtitle {
            Text("\(subtitle) reasoning")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

@MainActor
@ViewBuilder
private func shortcutLink(title: LocalizedStringResource, systemImage: String, url: URL?, tint: Color) -> some View {
    if let url {
        Link(destination: url) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage)
            }
                .font(.caption.weight(.bold))
                .labelStyle(.titleAndIcon)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 10)
                .padding(.vertical, 9)
                .background(tint.opacity(0.16), in: Capsule())
                .foregroundStyle(tint)
        }
        .buttonStyle(.plain)
    } else {
        Label {
            Text(title)
        } icon: {
            Image(systemName: systemImage)
        }
            .font(.caption.weight(.bold))
            .labelStyle(.titleAndIcon)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 10)
            .padding(.vertical, 9)
            .background(Color.secondary.opacity(0.12), in: Capsule())
            .foregroundStyle(.secondary)
    }
}

@MainActor
@ViewBuilder
private func shortcutEmptyState(title: LocalizedStringResource, subtitle: LocalizedStringResource) -> some View {
    VStack(spacing: 6) {
        Text(title)
            .font(.headline.weight(.semibold))
        Text(subtitle)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
}

func resolvedServer(_ selected: OpenCodeWidgetServerEntity?, fallbackServerID: String?) -> OpenCodeWidgetServerEntity? {
    let servers = OpenCodeWidgetOptions.servers()
    if let selected {
        return servers.first { $0.id == selected.id }
    }
    if let fallbackServerID {
        return servers.first { $0.id == fallbackServerID }
    }
    return OpenCodeWidgetOptions.defaultServer()
}

func resolvedProject(_ selected: OpenCodeWidgetProjectEntity?, server: OpenCodeWidgetServerEntity?) -> OpenCodeWidgetProjectEntity? {
    guard server != nil else { return nil }
    let projects = OpenCodeWidgetOptions.projects(server: server)
    guard let selected, selected.serverID == server?.id else { return nil }
    return projects.first { $0.id == selected.id }
}

func orderedProjects(selected: OpenCodeWidgetProjectEntity?, server: OpenCodeWidgetServerEntity?) -> [OpenCodeWidgetProjectEntity] {
    guard server != nil else { return [] }
    var projects = OpenCodeWidgetOptions.projects(server: server)
    guard let selected, let selectedIndex = projects.firstIndex(where: { $0.id == selected.id }) else {
        return projects
    }
    let selectedProject = projects.remove(at: selectedIndex)
    return [selectedProject] + projects
}

func resolvedCommand(_ selected: OpenCodeWidgetCommandEntity?, server: OpenCodeWidgetServerEntity?, project: OpenCodeWidgetProjectEntity?) -> OpenCodeWidgetCommandEntity? {
    let commands = OpenCodeWidgetOptions.commands(server: server, project: project)
    guard let selected, selected.serverID == server?.id, let project,
          selected.projectID == project.projectID else { return nil }
    return commands.first { $0.id == selected.id }
}

func resolvedModel(_ selected: OpenCodeWidgetModelEntity?, server: OpenCodeWidgetServerEntity?) -> OpenCodeWidgetModelEntity? {
    guard let selected else { return nil }
    guard selected.serverID == server?.id else { return nil }
    let models = OpenCodeWidgetOptions.models(server: server)
    return models.first { $0.id == selected.id }
}

func resolvedReasoning(_ selected: String?, model: OpenCodeWidgetModelEntity?) -> String? {
    guard let selected, let model, model.reasoningVariants.contains(selected) else { return nil }
    return selected
}

func formattedReasoningTitle(_ variant: String) -> String {
    variant.replacingOccurrences(of: "_", with: " ").capitalized
}

private extension OpenCodeActionShortcutEntry {
    static let previewProject = OpenCodeWidgetProjectEntity(
        id: "preview-server|preview-project",
        serverID: "preview-server",
        projectID: "preview-project",
        title: "OpenClient",
        directory: "/Users/nick/Code/openclient"
    )

    static let previewCommand = OpenCodeWidgetCommandEntity(
        id: "preview-server|preview-project|test",
        serverID: "preview-server",
        projectID: "preview-project",
        directory: "/Users/nick/Code/openclient",
        name: "test",
        summary: String(localized: "Run the project test suite")
    )

    static let previewModel = OpenCodeWidgetModelEntity(
        id: "preview-server|openai|gpt-5",
        serverID: "preview-server",
        providerID: "openai",
        providerName: "OpenAI",
        modelID: "gpt-5",
        modelName: "GPT-5",
        reasoningVariants: ["balanced", "deep_think"]
    )

    static let preview = OpenCodeActionShortcutEntry(
        date: Date(),
        project: previewProject,
        command: previewCommand,
        model: previewModel,
        reasoning: "balanced",
        url: OpenCodeWidgetDeepLink.actionURL(
            serverID: "preview-server",
            projectID: "preview-project",
            directory: "/Users/nick/Code/openclient",
            commandName: "test",
            providerID: "openai",
            modelID: "gpt-5",
            reasoningVariant: "balanced"
        )
    )
}

private extension OpenCodeNewSessionShortcutEntry {
    static let preview = OpenCodeNewSessionShortcutEntry(
        date: Date(),
        project: OpenCodeActionShortcutEntry.previewProject,
        projectChoices: [
            OpenCodeActionShortcutEntry.previewProject,
            OpenCodeWidgetProjectEntity(
                id: "preview-server|website",
                serverID: "preview-server",
                projectID: "website",
                title: String(localized: "Website"),
                directory: "/Users/nick/Code/website"
            ),
            OpenCodeWidgetProjectEntity(
                id: "preview-server|api",
                serverID: "preview-server",
                projectID: "api",
                title: String(localized: "API Server"),
                directory: "/Users/nick/Code/api"
            ),
            OpenCodeWidgetProjectEntity(
                id: "preview-server|notes",
                serverID: "preview-server",
                projectID: "notes",
                title: String(localized: "Notes"),
                directory: "/Users/nick/Code/notes"
            )
        ],
        model: OpenCodeActionShortcutEntry.previewModel,
        reasoning: "balanced",
        url: OpenCodeWidgetDeepLink.newSessionURL(
            serverID: "preview-server",
            projectID: "preview-project",
            directory: "/Users/nick/Code/openclient",
            providerID: "openai",
            modelID: "gpt-5",
            reasoningVariant: "balanced"
        )
    )
}
