import Foundation

struct BackendFormLocation: Hashable, Sendable {
    let directory: String
    var workspaceID: String? = nil
    var scope: BackendScope { .init(directory: directory, workspaceID: workspaceID) }
}

struct BackendGlobalFormInventory: Sendable {
    let location: BackendFormLocation
    let forms: [BackendForm]
}

@MainActor
protocol BackendGlobalFormsService: BackendSessionFormsService {
    func pendingGlobalForms(scope: BackendScope) async throws -> BackendGlobalFormInventory
}

struct BackendFormReference: Hashable, Sendable {
    let key: BackendFormKey
    var directory: String? = nil
    var workspaceID: String? = nil
    var projectID: String? = nil

    var scope: BackendScope { .init(projectID: projectID, directory: directory, workspaceID: workspaceID) }
}

/// Optional capability: injected backends need not expose an OpenCode compatibility client.
@MainActor
protocol BackendSessionFormsService: Sendable {
    func pendingForms(sessionID: String, scope: BackendScope) async throws -> [BackendForm]
    func readForm(_ reference: BackendFormReference) async throws -> BackendForm
    func readState(_ reference: BackendFormReference) async throws -> BackendFormState
    func reply(_ reference: BackendFormReference, answer: BackendFormAnswer) async throws
    func cancel(_ reference: BackendFormReference) async throws
}

enum BackendSessionFormsEvent: Sendable {
    case created(BackendForm)
    case answered(BackendFormKey, BackendFormAnswer)
    case cancelled(BackendFormKey)

    var sessionID: String {
        switch self {
        case .created(let form): return form.sessionID
        case .answered(let key, _), .cancelled(let key): return key.sessionID
        }
    }
}

enum BackendSessionFormsError: Error, Equatable {
    case invalidAnswer(message: String)
    case alreadySettled
    case unavailable
    case unauthorized
    case uncertain
}
