import Foundation
import WidgetKit

struct OpenCodeSessionsWidgetEntry: TimelineEntry {
    let date: Date
    let title: LocalizedStringResource
    let serverName: String?
    let mediumSession: OpenCodeWidgetSessionSnapshot?
    let largeSessions: [OpenCodeWidgetSessionSnapshot]
}

struct OpenCodeSessionsTimelineProvider: TimelineProvider {
    enum Source {
        case recent
        case pinned
    }

    let source: Source

    func placeholder(in context: Context) -> OpenCodeSessionsWidgetEntry {
        OpenCodeSessionsWidgetEntry(
            date: Date(),
            title: source.title,
            serverName: "OpenClient",
            mediumSession: OpenCodeWidgetSessionSnapshot.preview,
            largeSessions: OpenCodeWidgetSessionSnapshot.previewRows
        )
    }

    func getSnapshot(in context: Context, completion: @escaping (OpenCodeSessionsWidgetEntry) -> Void) {
        completion(entry())
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<OpenCodeSessionsWidgetEntry>) -> Void) {
        let current = entry()
        completion(Timeline(entries: [current], policy: .after(Date().addingTimeInterval(15 * 60))))
    }

    private func entry() -> OpenCodeSessionsWidgetEntry {
        let payload = OpenCodeWidgetStore().load()
        let server = payload.lastConnectedServer()
        let sessions = payload.sessions.filter { session in
            guard let server else { return false }
            return session.owner == server.owner
        }

        switch source {
        case .recent:
            let sorted = sessions.sorted { $0.lastActiveAt > $1.lastActiveAt }
            return OpenCodeSessionsWidgetEntry(
                date: Date(),
                title: source.title,
                serverName: server?.displayName,
                mediumSession: sorted.first,
                largeSessions: Array(sorted.prefix(4))
            )
        case .pinned:
            let pinned = sessions.filter(\.isPinned)
            let large = pinned.sorted { lhs, rhs in
                let lhsOrder = lhs.pinOrder ?? Int.max
                let rhsOrder = rhs.pinOrder ?? Int.max
                if lhsOrder != rhsOrder {
                    return lhsOrder < rhsOrder
                }
                return lhs.lastActiveAt > rhs.lastActiveAt
            }
            let medium = pinned.sorted { $0.lastActiveAt > $1.lastActiveAt }.first
                ?? sessions.filter { !$0.isPinned }.sorted { $0.lastActiveAt > $1.lastActiveAt }.first
            return OpenCodeSessionsWidgetEntry(
                date: Date(),
                title: source.title,
                serverName: server?.displayName,
                mediumSession: medium,
                largeSessions: Array(large.prefix(4))
            )
        }
    }
}

private extension OpenCodeSessionsTimelineProvider.Source {
    var title: LocalizedStringResource {
        switch self {
        case .recent:
            return "Recent Sessions"
        case .pinned:
            return "Pinned Sessions"
        }
    }
}

private extension OpenCodeWidgetSessionSnapshot {
    static let preview = OpenCodeWidgetSessionSnapshot(
        id: "preview-session",
        serverID: "preview-server",
        projectID: "preview-project",
        title: String(localized: "Widget dashboard polish"),
        projectLabel: "openclient",
        directory: "/Users/nick/Code/openclient",
        workspaceID: nil,
        status: .working,
        summaryKind: .snippet,
        summaryText: String(localized: "Tighten the session dashboard rows and line wrapping for the large widget."),
        updatedAt: Date().addingTimeInterval(-420),
        lastActiveAt: Date().addingTimeInterval(-420),
        isPinned: true,
        pinOrder: 0
    )

    static let previewRows: [OpenCodeWidgetSessionSnapshot] = [
        preview,
        OpenCodeWidgetSessionSnapshot(
            id: "preview-permission",
            serverID: "preview-server",
            projectID: "preview-project",
            title: String(localized: "Release prep"),
            projectLabel: "opencode",
            directory: "/Users/nick/Code/opencode",
            workspaceID: nil,
            status: .needsAction,
            summaryKind: .permission,
            summaryText: "xcodebuild -project OpenCodeIOSClient.xcodeproj build",
            updatedAt: Date().addingTimeInterval(-120),
            lastActiveAt: Date().addingTimeInterval(-120),
            isPinned: true,
            pinOrder: 1
        ),
        OpenCodeWidgetSessionSnapshot(
            id: "preview-question",
            serverID: "preview-server",
            projectID: "preview-project",
            title: String(localized: "Widget copy"),
            projectLabel: "docs",
            directory: "/Users/nick/Code/docs",
            workspaceID: nil,
            status: .needsAction,
            summaryKind: .question,
            summaryText: String(localized: "Which session summary should be highlighted first?"),
            updatedAt: Date().addingTimeInterval(-900),
            lastActiveAt: Date().addingTimeInterval(-900),
            isPinned: false,
            pinOrder: nil
        )
    ]
}
