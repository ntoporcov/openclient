import XCTest
@testable import OpenClient

@MainActor
final class WidgetSnapshotBuilderTests: XCTestCase {
    func testBuilderProducesScopedSessionSnapshotWithoutCredentials() throws {
        let now = Date(timeIntervalSince1970: 1_234)
        let project = OpenCodeProject(
            id: "project",
            worktree: "/tmp/project",
            vcs: "git",
            name: "Project",
            sandboxes: nil,
            icon: nil,
            time: nil
        )
        let session = OpenCodeSession(
            id: "ses_1",
            title: "Session",
            workspaceID: nil,
            directory: project.worktree,
            projectID: project.id,
            parentID: nil
        )
        let preview = SessionPreview(text: "Latest answer", date: now.addingTimeInterval(-10))
        let config = OpenCodeServerConfig(
            name: "Studio",
            baseURL: "https://example.com",
            username: "nick",
            password: "secret"
        )

        let publication = try XCTUnwrap(WidgetSnapshotBuilder.build(
            from: WidgetSnapshotInput(
                backendMode: .server,
                config: config,
                projects: [project],
                currentProject: project,
                effectiveDirectory: project.worktree,
                sessions: [session],
                sessionTitlesByID: [session.id: "Session"],
                statuses: [session.id: "busy"],
                previews: [session.id: preview],
                pinnedSessionIDs: [session.id],
                permissionsBySessionID: [:],
                questionsBySessionID: [:],
                commands: [],
                providers: [],
                visibleModelsByProviderID: [:]
            ),
            includeModelOptions: false,
            now: now
        ))

        XCTAssertEqual(publication.server.baseURL, "https://example.com")
        XCTAssertEqual(publication.server.username, "nick")
        XCTAssertFalse(String(describing: publication.server).contains("secret"))
        XCTAssertEqual(publication.sessions.first?.projectID, project.id)
        XCTAssertEqual(publication.sessions.first?.status, .working)
        XCTAssertEqual(publication.sessions.first?.summaryText, preview.text)
        XCTAssertEqual(publication.sessions.first?.pinOrder, 0)
    }

    func testBuilderPrioritizesPermissionAndNormalizesGlobalCommandDirectory() throws {
        let session = OpenCodeSession(
            id: "ses_global",
            title: "Global",
            workspaceID: nil,
            directory: nil,
            projectID: "global",
            parentID: nil
        )
        let permission = OpenCodePermission(
            id: "perm_1",
            sessionID: session.id,
            permission: "bash",
            patterns: ["git status"],
            always: nil,
            metadata: nil,
            tool: nil
        )
        let global = OpenCodeProject(id: "global", worktree: "", vcs: nil, name: "Global", sandboxes: nil, icon: nil, time: nil)
        let command = OpenCodeCommand(
            name: "review",
            description: "Review",
            agent: nil,
            model: nil,
            source: "project",
            template: "review",
            subtask: false,
            hints: []
        )
        let publication = try XCTUnwrap(WidgetSnapshotBuilder.build(
            from: WidgetSnapshotInput(
                backendMode: .server,
                config: OpenCodeServerConfig(baseURL: "https://example.com", username: "nick", password: "secret"),
                projects: [global],
                currentProject: global,
                effectiveDirectory: nil,
                sessions: [session],
                sessionTitlesByID: [:],
                statuses: [session.id: "idle"],
                previews: [session.id: SessionPreview(text: "Stale", date: nil)],
                pinnedSessionIDs: [],
                permissionsBySessionID: [session.id: [permission]],
                questionsBySessionID: [:],
                commands: [command],
                providers: [],
                visibleModelsByProviderID: [:]
            ),
            includeModelOptions: false
        ))

        XCTAssertEqual(publication.sessions.first?.summaryKind, .permission)
        XCTAssertEqual(publication.sessions.first?.status, .needsAction)
        XCTAssertNil(publication.commands.first?.directory)
    }

    func testViewModelInputSkipsChildSessionsThatWidgetsDoNotPublish() {
        let root = OpenCodeSession(
            id: "ses_root",
            title: "Root",
            workspaceID: nil,
            directory: "/tmp/project",
            projectID: "project",
            parentID: nil
        )
        let child = OpenCodeSession(
            id: "ses_child",
            title: "Child",
            workspaceID: nil,
            directory: root.directory,
            projectID: root.projectID,
            parentID: root.id
        )
        let viewModel = AppViewModel()
        viewModel.config = OpenCodeServerConfig(
            baseURL: "https://example.com",
            username: "nick",
            password: "secret"
        )
        viewModel.allSessions = [root, child]

        let input = viewModel.widgetSnapshotInput()

        XCTAssertEqual(input.sessions.map(\.id), [root.id])
    }

    func testViewModelInputStopsPreparingModelsAtWidgetLimit() {
        let providers = (0 ..< 5).map { providerIndex in
            let providerID = "provider-\(providerIndex)"
            let models = Dictionary(uniqueKeysWithValues: (0 ..< 50).map { modelIndex in
                let modelID = "model-\(modelIndex)"
                return (
                    modelID,
                    OpenCodeModel(
                        id: modelID,
                        providerID: providerID,
                        name: modelID,
                        capabilities: OpenCodeModelCapabilities(reasoning: false)
                    )
                )
            })
            return OpenCodeProvider(id: providerID, name: providerID, models: models)
        }
        let viewModel = AppViewModel()
        viewModel.modelConfigurationStore.applyProviderState(
            OpenCodeProviderListResponse(
                all: providers,
                connected: providers.map(\.id),
                default: [:]
            )
        )

        let input = viewModel.widgetSnapshotInput(includeModelOptions: true)

        XCTAssertEqual(input.providers.count, 3)
        XCTAssertEqual(input.visibleModelsByProviderID.values.reduce(0) { $0 + $1.count }, 120)
    }

    func testPublisherRefreshesShortcutDestinationsEvenWithoutModelOptions() async {
        let writer = WidgetWriterSpy()
        let reloader = WidgetTimelineReloaderSpy()
        let publisher = WidgetSnapshotPublisher(
            inputProvider: { _ in self.emptyInput() },
            writer: writer,
            timelineReloader: reloader
        )

        await publisher.publishNow()
        XCTAssertEqual(writer.updateCount, 1)
        XCTAssertEqual(reloader.contentReloadCount, 1)
        XCTAssertEqual(reloader.shortcutReloadCount, 1)

        await publisher.publishNow(includeModelOptions: true)
        XCTAssertEqual(writer.updateCount, 2)
        XCTAssertEqual(reloader.contentReloadCount, 2)
        XCTAssertEqual(reloader.shortcutReloadCount, 2)
    }

    func testV2BuilderPublishesReadOnlySnapshotsWithFixedOwner() throws {
        let model = AppViewModel()
        model.config = .init(baseURL: "https://v2.invalid", password: "test", apiPreference: .automatic)
        model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        let project = OpenCodeProject(id: "project", worktree: "/project", vcs: nil, name: "Project", sandboxes: nil, icon: nil, time: nil)
        model.projects = [project]
        model.currentProject = project
        model.allSessions = [.init(id: "session", title: "Canonical", workspaceID: "workspace", directory: "/project",
            projectID: "project", parentID: nil)]
        model.directoryCommands = [.init(name: "test", description: nil, agent: nil, model: nil, source: "project",
            template: "test", subtask: nil, hints: [])]
        let input = model.widgetSnapshotInput(includeModelOptions: true)
        let publication = try XCTUnwrap(WidgetSnapshotBuilder.build(from: input, includeModelOptions: true))
        XCTAssertEqual(publication.server.owner.profile, .v2)
        XCTAssertEqual(publication.server.id, model.config.recentServerID)
        XCTAssertEqual(publication.projects.first?.owner, publication.server.owner)
        XCTAssertEqual(publication.sessions.first?.owner, publication.server.owner)
        XCTAssertEqual(publication.sessions.first?.workspaceID, "workspace")
        XCTAssertTrue(publication.commands.isEmpty)
        XCTAssertTrue(publication.models.isEmpty)
        XCTAssertEqual(model.config.apiPreference, .automatic)
    }

    func testUnresolvedOrDisconnectedProfileCannotPublishAsLegacy() {
        let model = AppViewModel()
        model.config = .init(baseURL: "https://v2.invalid", password: "test", apiPreference: .automatic)
        XCTAssertNil(WidgetSnapshotBuilder.build(from: model.widgetSnapshotInput(), includeModelOptions: false))
        var input = emptyInput()
        input.profile = nil
        XCTAssertNil(WidgetSnapshotBuilder.build(from: input, includeModelOptions: false))
    }

    func testV2ActionMenusRequireTypedServicesAndExplicitGlobalExecutionDirectory() throws {
        let model = AppViewModel()
        model.config = .init(baseURL: "https://widget.invalid", password: "test", apiPreference: .v2)
        model.connectionStore.applySuccessfulV2Connection(version: "2", healthy: true)
        model.projects = [.init(id: "global", worktree: "/", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)]
        model.currentProject = model.projects.first
        model.directoryCommands = [.init(name: "test", description: nil, agent: nil, model: nil, source: "project",
            template: "test", subtask: nil, hints: [])]
        var input = model.widgetSnapshotInput()
        let unsupported = try XCTUnwrap(WidgetSnapshotBuilder.build(from: input, includeModelOptions: false))
        XCTAssertFalse(unsupported.server.offersNewSession)
        XCTAssertFalse(unsupported.server.offersCommands)
        XCTAssertEqual(unsupported.projects.first?.offersNewSession, false)
        input.supportsNewSession = true
        input.supportsCommands = true
        let unresolved = try XCTUnwrap(WidgetSnapshotBuilder.build(from: input, includeModelOptions: false))
        XCTAssertEqual(unresolved.projects.first?.offersNewSession, false)
        XCTAssertTrue(unresolved.commands.isEmpty)
        input.defaultDirectory = "/"
        input.commandsAreAuthoritative = true
        let supported = try XCTUnwrap(WidgetSnapshotBuilder.build(from: input, includeModelOptions: false))
        XCTAssertTrue(supported.server.offersNewSession)
        XCTAssertTrue(supported.server.offersCommands)
        XCTAssertEqual(supported.projects.first?.offersNewSession, true)
        XCTAssertEqual(supported.projects.first?.executionDirectory, "/")
        XCTAssertEqual(supported.commands.first?.directory, "/")
        XCTAssertEqual(supported.commands.first?.owner, supported.server.owner)
        XCTAssertEqual(supported.replacingCommandProjectIDs, ["global"])
        model.directoryCommands = []
        input = model.widgetSnapshotInput()
        input.supportsNewSession = true
        input.supportsCommands = true
        input.defaultDirectory = "/"
        input.commandsAreAuthoritative = true
        let empty = try XCTUnwrap(WidgetSnapshotBuilder.build(from: input, includeModelOptions: false))
        XCTAssertTrue(empty.commands.isEmpty)
        XCTAssertEqual(empty.replacingCommandProjectIDs, ["global"])
    }

    func testEmptyCatalogPublicationDistinguishesNotRefreshedFromAuthoritative() throws {
        var input = emptyInput()
        input.projectsAreAuthoritative = false
        let stale = try XCTUnwrap(WidgetSnapshotBuilder.build(from: input, includeModelOptions: true))
        XCTAssertFalse(stale.projectsAreAuthoritative)
        XCTAssertFalse(stale.modelsAreAuthoritative)
        XCTAssertTrue(stale.replacingCommandProjectIDs.isEmpty)
        input.projectsAreAuthoritative = true
        input.modelsAreAuthoritative = true
        let fresh = try XCTUnwrap(WidgetSnapshotBuilder.build(from: input, includeModelOptions: true))
        XCTAssertTrue(fresh.projectsAreAuthoritative)
        XCTAssertTrue(fresh.modelsAreAuthoritative)
    }

    private func emptyInput() -> WidgetSnapshotInput {
        WidgetSnapshotInput(
            backendMode: .server,
            config: OpenCodeServerConfig(baseURL: "https://example.com", username: "nick", password: "secret"),
            projects: [],
            currentProject: nil,
            effectiveDirectory: nil,
            sessions: [],
            sessionTitlesByID: [:],
            statuses: [:],
            previews: [:],
            pinnedSessionIDs: [],
            permissionsBySessionID: [:],
            questionsBySessionID: [:],
            commands: [],
            providers: [],
            visibleModelsByProviderID: [:]
        )
    }
}

private final class WidgetWriterSpy: WidgetSnapshotWriting {
    var updateCount = 0
    var removedSessions: [(String, String)] = []

    func update(_ publication: WidgetServerPublication) {
        updateCount += 1
    }

    func removeSession(serverID: String, sessionID: String) {
        removedSessions.append((serverID, sessionID))
    }

    func removeSession(owner: OpenCodeWidgetOwner, sessionID: String) {
        removedSessions.append((owner.entityID(), sessionID))
    }
}

private final class WidgetTimelineReloaderSpy: WidgetTimelineReloading {
    var contentReloadCount = 0
    var shortcutReloadCount = 0

    func reloadContentTimelines() { contentReloadCount += 1 }
    func reloadShortcutTimelines() { shortcutReloadCount += 1 }
    func reloadAllTimelines() {
        contentReloadCount += 1
        shortcutReloadCount += 1
    }
}
