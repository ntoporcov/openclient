import AppIntents
import Foundation

struct OpenCodeGetConnectionShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Get OpenClient Connection"
    static let description = IntentDescription("Returns a saved OpenClient server connection.")
    static let openAppWhenRun = false

    @Parameter(title: "Connection") var connection: OpenCodeShortcutConnectionEntity?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<OpenCodeShortcutConnectionEntity> & ProvidesDialog {
        let resolved = try await OpenCodeShortcutService().resolveConnection(connection)
        return .result(value: resolved.entity, dialog: IntentDialog("Using \(resolved.entity.displayName)."))
    }
}

struct OpenCodeGetProjectsShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Get OpenClient Projects"
    static let description = IntentDescription("Fetches projects from a saved OpenClient connection.")
    static let openAppWhenRun = false

    @Parameter(title: "Connection") var connection: OpenCodeShortcutConnectionEntity?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[OpenCodeShortcutProjectEntity]> & ProvidesDialog {
        let projects = try await OpenCodeShortcutService().projects(connection: connection)
        if projects.count == 1 {
            return .result(value: projects, dialog: IntentDialog("Found \(projects.count) project."))
        }
        return .result(value: projects, dialog: IntentDialog("Found \(projects.count) projects."))
    }
}

struct OpenCodeGetSessionsShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Get OpenClient Sessions"
    static let description = IntentDescription("Fetches root sessions for a selected OpenClient project.")
    static let openAppWhenRun = false

    @Parameter(title: "Connection") var connection: OpenCodeShortcutConnectionEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeGetSessionsProjectOptionsProvider()) var project: OpenCodeShortcutProjectEntity

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[OpenCodeShortcutSessionEntity]> & ProvidesDialog {
        let sessions = try await OpenCodeShortcutService().sessions(connection: connection, project: project)
        if sessions.count == 1 {
            return .result(value: sessions, dialog: IntentDialog("Found \(sessions.count) session."))
        }
        return .result(value: sessions, dialog: IntentDialog("Found \(sessions.count) sessions."))
    }
}

struct OpenCodeGetModelsShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Get OpenClient Models"
    static let description = IntentDescription("Fetches available models for a saved OpenClient connection.")
    static let openAppWhenRun = false

    @Parameter(title: "Connection") var connection: OpenCodeShortcutConnectionEntity?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<[OpenCodeShortcutModelEntity]> & ProvidesDialog {
        let models = try await OpenCodeShortcutService().models(connection: connection)
        if models.count == 1 {
            return .result(value: models, dialog: IntentDialog("Found \(models.count) model."))
        }
        return .result(value: models, dialog: IntentDialog("Found \(models.count) models."))
    }
}

struct OpenCodeStartSessionShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start OpenClient Session"
    static let description = IntentDescription("Creates a new OpenClient session in a selected project.")
    static let openAppWhenRun = false

    @Parameter(title: "Connection") var connection: OpenCodeShortcutConnectionEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeStartSessionProjectOptionsProvider()) var project: OpenCodeShortcutProjectEntity
    @Parameter(title: "Title") var titleText: String?
    @Parameter(title: "Model", optionsProvider: OpenCodeStartSessionModelOptionsProvider()) var model: OpenCodeShortcutModelEntity?
    @Parameter(title: "Reasoning", optionsProvider: OpenCodeStartSessionReasoningOptionsProvider()) var reasoning: String?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<OpenCodeShortcutSessionEntity> & ProvidesDialog {
        let session = try await OpenCodeShortcutService().createSession(
            connection: connection,
            project: project,
            title: titleText,
            model: model,
            reasoning: reasoning
        )
        return .result(value: session, dialog: IntentDialog("Started \(session.title)."))
    }
}

struct OpenCodeSendMessageShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Send OpenClient Message"
    static let description = IntentDescription("Sends a message to an existing OpenClient session.")
    static let openAppWhenRun = false

    @Parameter(title: "Connection") var connection: OpenCodeShortcutConnectionEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeSendMessageProjectOptionsProvider()) var project: OpenCodeShortcutProjectEntity
    @Parameter(title: "Session", optionsProvider: OpenCodeSendMessageSessionOptionsProvider()) var session: OpenCodeShortcutSessionEntity
    @Parameter(title: "Message") var message: String
    @Parameter(title: "Model", optionsProvider: OpenCodeSendMessageModelOptionsProvider()) var model: OpenCodeShortcutModelEntity?
    @Parameter(title: "Reasoning", optionsProvider: OpenCodeSendMessageReasoningOptionsProvider()) var reasoning: String?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<OpenCodeShortcutSessionEntity> & ProvidesDialog {
        let session = try await OpenCodeShortcutService().sendMessage(
            connection: connection,
            project: project,
            session: session,
            message: message,
            model: model,
            reasoning: reasoning
        )
        return .result(value: session, dialog: IntentDialog("Message sent to \(session.title)."))
    }
}

struct OpenCodeStartSessionAndSendMessageShortcutIntent: AppIntent {
    static let title: LocalizedStringResource = "Start OpenClient Session and Send Message"
    static let description = IntentDescription("Creates a new OpenClient session and sends the first message.")
    static let openAppWhenRun = false

    @Parameter(title: "Connection") var connection: OpenCodeShortcutConnectionEntity?
    @Parameter(title: "Project", optionsProvider: OpenCodeStartAndSendProjectOptionsProvider()) var project: OpenCodeShortcutProjectEntity
    @Parameter(title: "Message") var message: String
    @Parameter(title: "Title") var titleText: String?
    @Parameter(title: "Model", optionsProvider: OpenCodeStartAndSendModelOptionsProvider()) var model: OpenCodeShortcutModelEntity?
    @Parameter(title: "Reasoning", optionsProvider: OpenCodeStartAndSendReasoningOptionsProvider()) var reasoning: String?

    init() {}

    func perform() async throws -> some IntentResult & ReturnsValue<OpenCodeShortcutSessionEntity> & ProvidesDialog {
        let session = try await OpenCodeShortcutService().createSessionAndSendMessage(
            connection: connection,
            project: project,
            title: titleText,
            message: message,
            model: model,
            reasoning: reasoning
        )
        return .result(value: session, dialog: IntentDialog("Started \(session.title) and sent the message."))
    }
}

struct OpenCodeAppShortcutsProvider: AppShortcutsProvider {
    static let shortcutTileColor: ShortcutTileColor = .blue

    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: OpenCodeStartSessionAndSendMessageShortcutIntent(),
            phrases: [
                "Send an OpenClient message with \(.applicationName)",
                "Start an OpenClient session with \(.applicationName)",
            ],
            shortTitle: "Send Message",
            systemImageName: "paperplane.fill"
        )
        AppShortcut(
            intent: OpenCodeSendMessageShortcutIntent(),
            phrases: [
                "Send a message to OpenClient with \(.applicationName)",
            ],
            shortTitle: "Message Session",
            systemImageName: "message.fill"
        )
        AppShortcut(
            intent: OpenCodeStartSessionShortcutIntent(),
            phrases: [
                "Create an OpenClient session with \(.applicationName)",
            ],
            shortTitle: "Start Session",
            systemImageName: "plus.message.fill"
        )
        AppShortcut(
            intent: OpenCodeGetSessionsShortcutIntent(),
            phrases: [
                "Get OpenClient sessions with \(.applicationName)",
            ],
            shortTitle: "Get Sessions",
            systemImageName: "list.bullet.rectangle.fill"
        )
        AppShortcut(
            intent: OpenCodeGetProjectsShortcutIntent(),
            phrases: [
                "Get OpenClient projects with \(.applicationName)",
            ],
            shortTitle: "Get Projects",
            systemImageName: "folder.fill"
        )
        AppShortcut(
            intent: OpenCodeGetModelsShortcutIntent(),
            phrases: [
                "Get OpenClient models with \(.applicationName)",
            ],
            shortTitle: "Get Models",
            systemImageName: "cpu.fill"
        )
        AppShortcut(
            intent: OpenCodeGetConnectionShortcutIntent(),
            phrases: [
                "Get OpenClient connection with \(.applicationName)",
            ],
            shortTitle: "Get Connection",
            systemImageName: "server.rack"
        )
    }
}

struct OpenCodeGetSessionsProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeGetSessionsShortcutIntent>(\.$connection) var intent

    func results() async throws -> [OpenCodeShortcutProjectEntity] {
        try await OpenCodeShortcutService().projects(connection: intent?.connection)
    }
}

struct OpenCodeStartSessionProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeStartSessionShortcutIntent>(\.$connection) var intent

    func results() async throws -> [OpenCodeShortcutProjectEntity] {
        try await OpenCodeShortcutService().projects(connection: intent?.connection)
    }
}

struct OpenCodeStartSessionModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeStartSessionShortcutIntent>(\.$connection) var intent

    func results() async throws -> [OpenCodeShortcutModelEntity] {
        try await OpenCodeShortcutService().models(connection: intent?.connection)
    }
}

struct OpenCodeStartSessionReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeStartSessionShortcutIntent>(\.$model) var intent

    func results() async throws -> [String] {
        guard let model = intent?.model else { return [] }
        return model.reasoningVariants
    }
}

struct OpenCodeSendMessageProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeSendMessageShortcutIntent>(\.$connection) var intent

    func results() async throws -> [OpenCodeShortcutProjectEntity] {
        try await OpenCodeShortcutService().projects(connection: intent?.connection)
    }
}

struct OpenCodeSendMessageSessionOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeSendMessageShortcutIntent>(\.$project) var intent

    func results() async throws -> [OpenCodeShortcutSessionEntity] {
        guard let project = intent?.project else { return [] }
        return try await OpenCodeShortcutService().sessions(connection: intent?.connection, project: project)
    }
}

struct OpenCodeSendMessageModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeSendMessageShortcutIntent>(\.$connection) var intent

    func results() async throws -> [OpenCodeShortcutModelEntity] {
        try await OpenCodeShortcutService().models(connection: intent?.connection)
    }
}

struct OpenCodeSendMessageReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeSendMessageShortcutIntent>(\.$model) var intent

    func results() async throws -> [String] {
        guard let model = intent?.model else { return [] }
        return model.reasoningVariants
    }
}

struct OpenCodeStartAndSendProjectOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeStartSessionAndSendMessageShortcutIntent>(\.$connection) var intent

    func results() async throws -> [OpenCodeShortcutProjectEntity] {
        try await OpenCodeShortcutService().projects(connection: intent?.connection)
    }
}

struct OpenCodeStartAndSendModelOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeStartSessionAndSendMessageShortcutIntent>(\.$connection) var intent

    func results() async throws -> [OpenCodeShortcutModelEntity] {
        try await OpenCodeShortcutService().models(connection: intent?.connection)
    }
}

struct OpenCodeStartAndSendReasoningOptionsProvider: DynamicOptionsProvider {
    @IntentParameterDependency<OpenCodeStartSessionAndSendMessageShortcutIntent>(\.$model) var intent

    func results() async throws -> [String] {
        guard let model = intent?.model else { return [] }
        return model.reasoningVariants
    }
}
