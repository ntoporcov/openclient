import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct OpenCodeChatActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OpenCodeChatActivityAttributes.self) { context in
            OpenCodeChatActivityView(context: context)
                .widgetURL(
                    OpenCodeChatActivityDeepLink.openAppURL(
                        sessionID: context.attributes.sessionID,
                        directory: context.attributes.directory,
                        workspaceID: context.attributes.workspaceID
                    )
                )
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    HStack(spacing: 10) {
                        OpenCodeChatActivityAvatar(title: context.attributes.sessionTitle, size: 28)

                        Text(context.attributes.sessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                    }
                }

                DynamicIslandExpandedRegion(.trailing) {
                    statusBadge(for: displayStatus(for: context))
                }

                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(context.state.latestSnippet)
                            .font(.subheadline)
                            .lineLimit(3)

                        OpenCodeChatActivityActions(context: context)
                    }
                }
            } compactLeading: {
                OpenCodeChatActivityAvatar(title: context.attributes.sessionTitle, size: 20)
            } compactTrailing: {
                Circle()
                    .fill(OpenCodeChatActivityDisplayStatus(rawValue: context.state.status).color)
                    .frame(width: 10, height: 10)
            } minimal: {
                Image(systemName: "bubble.left.fill")
            }
            .widgetURL(
                OpenCodeChatActivityDeepLink.openAppURL(
                    sessionID: context.attributes.sessionID,
                    directory: context.attributes.directory,
                    workspaceID: context.attributes.workspaceID
                )
            )
            .keylineTint(displayStatus(for: context).color)
        }
    }

    @ViewBuilder
    private func statusBadge(for status: OpenCodeChatActivityDisplayStatus) -> some View {
        openCodeStatusText(status)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 9)
            .padding(.vertical, 5)
            .background(status.color.opacity(0.3), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(.white.opacity(0.12), lineWidth: 1)
            }
    }

    private func displayStatus(for context: ActivityViewContext<OpenCodeChatActivityAttributes>) -> OpenCodeChatActivityDisplayStatus {
        if context.state.pendingInteractionKind != nil {
            return OpenCodeChatActivityDisplayStatus(rawValue: "action")
        }
        return OpenCodeChatActivityDisplayStatus(rawValue: context.isStale ? "paused" : context.state.status)
    }
}

struct OpenCodeTalkActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: OpenCodeTalkActivityAttributes.self) { context in
            OpenCodeTalkActivityView(context: context)
                .widgetURL(destination(for: context))
                .activityBackgroundTint(.clear)
                .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            let status = OpenCodeTalkActivityDisplayStatus(phase: context.state.phase)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    OpenCodeTalkAppIcon(size: 30)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(status.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(status.color)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Text(context.attributes.title)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: status.symbol)
                            .foregroundStyle(status.color)
                    }
                }
            } compactLeading: {
                Image(systemName: "waveform")
                    .foregroundStyle(.blue)
            } compactTrailing: {
                Circle()
                    .fill(status.color)
                    .frame(width: 9, height: 9)
            } minimal: {
                Image(systemName: "waveform")
                    .foregroundStyle(.blue)
            }
            .widgetURL(destination(for: context))
            .keylineTint(status.color)
        }
    }

    private func destination(for context: ActivityViewContext<OpenCodeTalkActivityAttributes>) -> URL? {
        guard let sessionID = context.state.sessionID else { return nil }
        return OpenCodeChatActivityDeepLink.openAppURL(
            sessionID: sessionID,
            directory: context.attributes.directory,
            workspaceID: context.attributes.workspaceID
        )
    }

}

private struct OpenCodeTalkActivityView: View {
    let context: ActivityViewContext<OpenCodeTalkActivityAttributes>

    var body: some View {
        let status = OpenCodeTalkActivityDisplayStatus(phase: context.state.phase)
        HStack(spacing: 14) {
            OpenCodeTalkAppIcon(size: 48)

            VStack(alignment: .leading, spacing: 5) {
                Text(context.attributes.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Text(status.title)
                    .font(.subheadline)
                    .foregroundStyle(status.color)
            }

            Spacer(minLength: 0)

            Image(systemName: status.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(status.color)
                .symbolEffect(.variableColor.iterative, options: .repeating, isActive: context.state.phase != .paused)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 16)
    }
}

private struct OpenCodeTalkAppIcon: View {
    let size: CGFloat

    var body: some View {
        Image("ios-120")
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

private struct OpenCodeTalkActivityDisplayStatus {
    let phase: OpenCodeTalkActivityPhase

    var title: LocalizedStringResource {
        switch phase {
        case .listening:
            return "Listening"
        case .working:
            return "Working"
        case .speaking:
            return "Speaking"
        case .paused:
            return "Paused"
        }
    }

    var symbol: String {
        switch phase {
        case .listening:
            return "waveform"
        case .working:
            return "ellipsis"
        case .speaking:
            return "speaker.wave.2.fill"
        case .paused:
            return "pause.fill"
        }
    }

    var color: Color {
        switch phase {
        case .listening, .speaking:
            return .blue
        case .working:
            return .orange
        case .paused:
            return .gray
        }
    }
}

private struct OpenCodeChatActivityView: View {
    let context: ActivityViewContext<OpenCodeChatActivityAttributes>

    var body: some View {
        ZStack {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center, spacing: 10) {
                    OpenCodeChatActivityAvatar(title: context.attributes.sessionTitle, size: 38)

                    VStack(alignment: .leading, spacing: 4) {
                        Text(context.attributes.sessionTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)

                        Text(context.state.updatedAt, style: .relative)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.62))
                    }

                    Spacer(minLength: 0)

                    openCodeStatusText(displayStatus)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 5)
                        .background(statusColor.opacity(0.22), in: Capsule())
                }

                primaryContent
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 16)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 8)
    }

    private var statusColor: Color {
        displayStatus.color
    }

    private var displayStatus: OpenCodeChatActivityDisplayStatus {
        if context.state.pendingInteractionKind != nil {
            return OpenCodeChatActivityDisplayStatus(rawValue: "action")
        }
        return OpenCodeChatActivityDisplayStatus(rawValue: context.isStale ? "paused" : context.state.status)
    }

    @ViewBuilder
    private var primaryContent: some View {
        if context.state.pendingInteractionKind == "permission" {
            OpenCodeChatActivityPermissionContent(context: context)
        } else if context.state.pendingInteractionKind == "question" {
            OpenCodeChatActivityQuestionContent(context: context)
        } else {
            OpenCodeChatActivityTranscriptContent(context: context)
        }
    }
}

private struct OpenCodeChatActivityTranscriptContent: View {
    let context: ActivityViewContext<OpenCodeChatActivityAttributes>

    var body: some View {
        if context.state.transcriptLines.isEmpty {
            Text(context.state.latestSnippet)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.96))
                .lineSpacing(3)
                .lineLimit(5)
                .padding(.horizontal, 2)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            VStack(alignment: .leading, spacing: 7) {
                ForEach(context.state.transcriptLines) { line in
                    Text(line.text)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.96))
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct OpenCodeChatActivityPermissionContent: View {
    let context: ActivityViewContext<OpenCodeChatActivityAttributes>

    var body: some View {
        if let summary = context.state.interactionSummary {
            VStack(alignment: .leading, spacing: 10) {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)

                OpenCodeChatActivityActions(context: context)
            }
        }
    }
}

private struct OpenCodeChatActivityQuestionContent: View {
    let context: ActivityViewContext<OpenCodeChatActivityAttributes>

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let summary = context.state.interactionSummary {
                Text(summary)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            OpenCodeChatActivityActions(context: context)
        }
    }
}

private struct OpenCodeChatActivityActions: View {
    let context: ActivityViewContext<OpenCodeChatActivityAttributes>

    var body: some View {
        if context.state.pendingInteractionKind == "permission",
           let requestID = context.state.interactionID {
            HStack(spacing: 8) {
                permissionButton(
                    title: "Allow Once",
                    requestID: requestID,
                    reply: "once",
                    tint: .green
                )
                .frame(maxWidth: .infinity)

                permissionButton(
                    title: "Deny",
                    requestID: requestID,
                    reply: "reject",
                    tint: .red
                )
                .frame(maxWidth: .infinity)
            }
        } else if context.state.pendingInteractionKind == "question",
                  let requestID = context.state.interactionID,
                  context.state.canReplyToQuestionInline {
            HStack(spacing: 8) {
                ForEach(context.state.questionOptionLabels, id: \.self) { option in
                    questionButton(
                        title: option,
                        requestID: requestID,
                        answer: option,
                        tint: .blue
                    )
                    .frame(maxWidth: .infinity)
                }
            }
        } else if context.state.pendingInteractionKind == "question" {
            actionLink(
                title: "Open App",
                destination: OpenCodeChatActivityDeepLink.openAppURL(
                    sessionID: context.attributes.sessionID,
                    directory: context.attributes.directory,
                    workspaceID: context.attributes.workspaceID
                ),
                tint: .white.opacity(0.16)
            )
        }
    }

    private func actionLink(title: LocalizedStringResource, destination: URL?, tint: Color) -> some View {
        Group {
            if let destination {
                Link(destination: destination) {
                    Text(title)
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                        .frame(maxWidth: .infinity)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(tint, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func permissionButton(title: LocalizedStringResource, requestID: String, reply: String, tint: Color) -> some View {
        Button(intent: OpenCodeReplyPermissionIntent(
            sessionID: context.attributes.sessionID,
            requestID: requestID,
            reply: reply,
            credentialID: context.attributes.credentialID,
            baseURL: context.attributes.serverBaseURL,
            username: context.attributes.serverUsername,
            directory: context.attributes.directory,
            workspaceID: context.attributes.workspaceID
        )) {
            actionLabel(title: title, tint: tint)
        }
        .buttonStyle(.plain)
    }

    private func questionButton(title: String, requestID: String, answer: String, tint: Color) -> some View {
        Button(intent: OpenCodeReplyQuestionIntent(
            sessionID: context.attributes.sessionID,
            requestID: requestID,
            answer: answer,
            credentialID: context.attributes.credentialID,
            baseURL: context.attributes.serverBaseURL,
            username: context.attributes.serverUsername,
            directory: context.attributes.directory,
            workspaceID: context.attributes.workspaceID
        )) {
            Text(title)
                .font(.caption.weight(.semibold))
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(tint, in: Capsule())
                .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
    }

    private func actionLabel(title: LocalizedStringResource, tint: Color) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .lineLimit(1)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(tint, in: Capsule())
            .foregroundStyle(.white)
    }

}

private struct OpenCodeChatActivityDisplayStatus {
    let rawValue: String

    var localizedTitle: LocalizedStringResource? {
        switch rawValue.lowercased() {
        case "action":
            return "Action"
        case "working":
            return "Working"
        case "live":
            return "Live"
        case "ready":
            return "Ready"
        case "paused":
            return "Paused"
        default:
            return nil
        }
    }

    var color: Color {
        switch rawValue.lowercased() {
        case "action":
            return .orange
        case "working", "live":
            return .green
        case "ready":
            return .blue
        case "paused":
            return .gray
        default:
            return .white
        }
    }
}

@MainActor
@ViewBuilder
private func openCodeStatusText(_ status: OpenCodeChatActivityDisplayStatus) -> some View {
    if let localizedTitle = status.localizedTitle {
        Text(localizedTitle)
    } else {
        Text(status.rawValue)
    }
}

private struct OpenCodeChatActivityAvatar: View {
    let title: String
    let size: CGFloat

    var body: some View {
        Text(initials)
            .font(.system(size: size * 0.36, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .background(
                LinearGradient(
                    colors: [gradientColors.0, gradientColors.1],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: Circle()
            )
            .overlay {
                Circle()
                    .strokeBorder(.white.opacity(0.14), lineWidth: 1)
            }
    }

    private var initials: String {
        let words = title
            .split(whereSeparator: { $0.isWhitespace || $0 == "-" || $0 == "_" })
            .prefix(2)
        let letters = words.compactMap { $0.first }.map { String($0).uppercased() }
        return letters.isEmpty ? "OC" : letters.joined()
    }

    private var gradientColors: (Color, Color) {
        palette(for: title)
    }
}

private func palette(for title: String) -> (Color, Color) {
    let palettes: [(Color, Color)] = [
        (.blue, .purple),
        (.pink, .orange),
        (.teal, .blue),
        (.indigo, .mint),
        (.orange, .red),
        (.green, .teal),
    ]
    let paletteIndex = Int(opencodeStableHash(title) % UInt64(palettes.count))
    return palettes[paletteIndex]
}
