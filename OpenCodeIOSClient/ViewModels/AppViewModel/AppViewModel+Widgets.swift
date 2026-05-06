import Foundation

#if canImport(WidgetKit)
import WidgetKit
#endif

extension AppViewModel {
    func publishWidgetSnapshots() {
        guard backendMode == .server, config.hasCredentials else { return }

        let server = buildWidgetServerSnapshot()
        let projects = buildWidgetProjectSnapshots(serverID: server.id)
        let sessions = buildWidgetSessionSnapshots(serverID: server.id)
        let replacingSessionIDs = Set(allSessions.filter(\.isRootSession).map(\.id))

        OpenCodeWidgetStore().updatingServer(
            server,
            projects: projects,
            sessions: sessions,
            replacingSessionIDs: replacingSessionIDs
        )

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: OpenCodeWidgetKind.recentSessions)
        WidgetCenter.shared.reloadTimelines(ofKind: OpenCodeWidgetKind.pinnedSessions)
        #endif
    }

    func removeWidgetSessionSnapshot(for sessionID: String) {
        guard config.hasCredentials else { return }
        OpenCodeWidgetStore().removeSession(serverID: config.recentServerID, sessionID: sessionID)

        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadTimelines(ofKind: OpenCodeWidgetKind.recentSessions)
        WidgetCenter.shared.reloadTimelines(ofKind: OpenCodeWidgetKind.pinnedSessions)
        #endif
    }

    private func buildWidgetServerSnapshot() -> OpenCodeWidgetServerSnapshot {
        OpenCodeWidgetServerSnapshot(
            id: config.recentServerID,
            displayName: config.displayName,
            baseURL: config.trimmedBaseURL,
            username: config.trimmedUsername,
            generatedAt: Date(),
            isLastConnected: true
        )
    }

    private func buildWidgetProjectSnapshots(serverID: String) -> [OpenCodeWidgetProjectSnapshot] {
        projects.map { project in
            let title = widgetProjectTitle(for: project)
            return OpenCodeWidgetProjectSnapshot(
                id: project.id,
                serverID: serverID,
                title: title,
                worktree: project.worktree,
                sortTitle: title.localizedLowercase
            )
        }
    }

    private func buildWidgetSessionSnapshots(serverID: String) -> [OpenCodeWidgetSessionSnapshot] {
        let pinnedOrder = Dictionary(uniqueKeysWithValues: pinnedSessionIDs.enumerated().map { ($0.element, $0.offset) })
        return allSessions.filter(\.isRootSession).map { session in
            let summary = widgetSummary(for: session)
            let lastActiveAt = widgetLastActiveDate(for: session, summaryUpdatedAt: summary.updatedAt)
            return OpenCodeWidgetSessionSnapshot(
                id: session.id,
                serverID: serverID,
                projectID: widgetProjectID(for: session),
                title: widgetSessionTitle(for: session),
                projectLabel: widgetProjectLabel(for: session),
                directory: session.directory,
                workspaceID: session.workspaceID,
                status: widgetStatus(for: session, summaryKind: summary.kind),
                summaryKind: summary.kind,
                summaryText: summary.text,
                updatedAt: summary.updatedAt,
                lastActiveAt: lastActiveAt,
                isPinned: pinnedOrder[session.id] != nil,
                pinOrder: pinnedOrder[session.id]
            )
        }
    }

    private func widgetProjectID(for session: OpenCodeSession) -> String {
        if let projectID = session.projectID, !projectID.isEmpty {
            return projectID
        }
        if let directory = session.directory,
           let project = projects.first(where: { $0.worktree == directory }) {
            return project.id
        }
        return currentProject?.id ?? "global"
    }

    private func widgetProjectLabel(for session: OpenCodeSession) -> String {
        let project = projects.first { project in
            if let projectID = session.projectID, project.id == projectID {
                return true
            }
            return session.directory == project.worktree
        }

        if let project {
            return widgetProjectTitle(for: project)
        }

        if let directory = session.directory,
           let component = directoryLastPathComponent(directory),
           !component.isEmpty {
            return component
        }

        return "Global"
    }

    private func widgetProjectTitle(for project: OpenCodeProject) -> String {
        if let name = project.name?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if let component = directoryLastPathComponent(project.worktree), !component.isEmpty {
            return component
        }
        return project.id == "global" ? "Global" : project.id
    }

    private func widgetSessionTitle(for session: OpenCodeSession) -> String {
        let title = childSessionTitle(for: session).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Session" : title
    }

    private func widgetStatus(for session: OpenCodeSession, summaryKind: OpenCodeWidgetSummaryKind) -> OpenCodeWidgetSessionStatus {
        if summaryKind == .permission || summaryKind == .question {
            return .needsAction
        }

        switch sessionStatuses[session.id] {
        case "busy":
            return .working
        case "idle":
            return .ready
        default:
            return .watching
        }
    }

    private func widgetSummary(for session: OpenCodeSession) -> (kind: OpenCodeWidgetSummaryKind, text: String, updatedAt: Date?) {
        if let permission = permissions(for: session.id).first {
            return (.permission, permission.summary, Date())
        }

        if let question = questions(for: session.id).first,
           let firstQuestion = question.questions.first {
            return (.question, firstQuestion.question, Date())
        }

        if let preview = sessionPreviews[session.id] {
            return (.snippet, preview.text, preview.date)
        }

        return (.snippet, "No messages yet", nil)
    }

    private func widgetLastActiveDate(for session: OpenCodeSession, summaryUpdatedAt: Date?) -> Date {
        summaryUpdatedAt ?? sessionPreviews[session.id]?.date ?? .distantPast
    }

    private func directoryLastPathComponent(_ path: String) -> String? {
        let trimmed = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return trimmed.split(separator: "/").last.map(String.init)
    }
}
