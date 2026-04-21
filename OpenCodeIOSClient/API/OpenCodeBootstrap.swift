import Foundation

struct OpenCodeGlobalBootstrap {
    let health: HealthResponse
    let projects: [OpenCodeProject]
    let currentProject: OpenCodeProject?
}

struct OpenCodeDirectoryBootstrap {
    let sessions: [OpenCodeSession]
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
        async let sessions = client.listSessions(directory: directory, roots: true)
        async let permissions = client.listPermissions()
        async let questions = client.listQuestions()

        return OpenCodeDirectoryBootstrap(
            sessions: try await sessions.filter { $0.isRootSession },
            permissions: try await permissions,
            questions: try await questions
        )
    }
}
