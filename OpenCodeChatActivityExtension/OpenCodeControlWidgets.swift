import AppIntents
import SwiftUI
import WidgetKit

@available(iOS 18.0, *)
struct OpenCodeNewSessionControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: OpenCodeWidgetKind.newSessionControl,
            intent: OpenCodeNewSessionControlConfiguration.self
        ) { configuration in
            let payload = OpenCodeControlPayload.newSession(configuration)
            ControlWidgetButton(action: OpenURLIntent(payload.url ?? OpenCodeControlPayload.fallbackURL)) {
                Label(payload.title, systemImage: "plus.message.fill")
                    .controlWidgetStatus(Text(payload.status))
                    .controlWidgetActionHint(Text("Open OpenClient"))
            }
            .tint(.blue)
            .disabled(payload.url == nil)
        }
        .displayName("New Session")
        .description("Open OpenClient and start a new session in a project.")
        .promptsForUserConfiguration()
    }
}

@available(iOS 18.0, *)
struct OpenCodeActionControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        AppIntentControlConfiguration(
            kind: OpenCodeWidgetKind.actionControl,
            intent: OpenCodeActionControlConfiguration.self
        ) { configuration in
            let payload = OpenCodeControlPayload.action(configuration)
            ControlWidgetButton(action: OpenURLIntent(payload.url ?? OpenCodeControlPayload.fallbackURL)) {
                Label(payload.title, systemImage: "bolt.fill")
                    .controlWidgetStatus(Text(payload.status))
                    .controlWidgetActionHint(Text("Run command"))
            }
            .tint(.orange)
            .disabled(payload.url == nil)
        }
        .displayName("Slash Command")
        .description("Open OpenClient, start a session, and send a slash command.")
        .promptsForUserConfiguration()
    }
}

private struct OpenCodeControlPayload {
    let title: String
    let status: String
    let url: URL?

    static let fallbackURL = URL(string: "openclient://widget")!

    @available(iOS 18.0, *)
    static func newSession(_ configuration: OpenCodeNewSessionControlConfiguration) -> OpenCodeControlPayload {
        let server = resolvedServer(configuration.server, fallbackServerID: configuration.project?.serverID ?? configuration.model?.serverID)
        let project = resolvedProject(configuration.project, server: server)
        let model = resolvedModel(configuration.model, server: server)
        let reasoning = resolvedReasoning(configuration.reasoning, model: model)
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

        return OpenCodeControlPayload(
            title: String(localized: "New Session"),
            status: project?.title ?? String(localized: "Choose project"),
            url: url
        )
    }

    @available(iOS 18.0, *)
    static func action(_ configuration: OpenCodeActionControlConfiguration) -> OpenCodeControlPayload {
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

        let title = command.map { "/\($0.name)" } ?? String(localized: "Slash Command")
        return OpenCodeControlPayload(
            title: title,
            status: project?.title ?? String(localized: "Choose command"),
            url: url
        )
    }
}
