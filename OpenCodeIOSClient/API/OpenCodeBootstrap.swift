import Foundation

struct OpenCodeGlobalBootstrap {
    let health: HealthResponse
    let projects: [OpenCodeProject]
    let currentProject: OpenCodeProject?
}

struct OpenCodeDirectoryBootstrap {
    let sessions: [OpenCodeSession]
    let commands: [OpenCodeCommand]
    let permissions: [OpenCodePermission]
    let questions: [OpenCodeQuestionRequest]
}

enum OpenCodeBootstrap {
    static func bootstrapGlobal(client: OpenCodeAPIClient) async throws -> OpenCodeGlobalBootstrap {
        async let health = client.health()
        async let projects = client.listProjects()
        async let currentProject = try? client.currentProject()

        return try await OpenCodeGlobalBootstrap(
            health: health,
            projects: projects,
            currentProject: currentProject
        )
    }

    static func bootstrapDirectory(client: OpenCodeAPIClient, directory: String?) async throws -> OpenCodeDirectoryBootstrap {
        async let sessions = client.listSessions(directory: directory, roots: directory == nil ? nil : true)
        async let commands = client.listCommands(directory: directory)
        async let permissions = client.listPermissions(directory: directory)
        async let questions = client.listQuestions(directory: directory)

        return OpenCodeDirectoryBootstrap(
            sessions: try await sessions.filter { $0.isRootSession },
            commands: try await commands,
            permissions: try await permissions,
            questions: try await questions
        )
    }
}
