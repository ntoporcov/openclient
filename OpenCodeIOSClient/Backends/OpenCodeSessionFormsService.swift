import Foundation

@MainActor
struct OpenCodeSessionFormsService: BackendGlobalFormsService {
    let client: OpenCodeAPIClient

    func pendingGlobalForms(scope: BackendScope) async throws -> BackendGlobalFormInventory {
        try await client.listV2GlobalForms(directory: scope.directory, workspaceID: scope.workspaceID)
    }

    func pendingForms(sessionID: String, scope: BackendScope) async throws -> [BackendForm] {
        do {
            return try await client.listV2SessionForms(sessionID: sessionID, directory: scope.directory,
                workspaceID: scope.workspaceID).map(\.backendForm)
        } catch { throw Self.translate(error) }
    }

    func readForm(_ reference: BackendFormReference) async throws -> BackendForm {
        do {
            return try await client.getV2Form(sessionID: reference.key.sessionID, formID: reference.key.formID,
                directory: reference.directory, workspaceID: reference.workspaceID).backendForm
        } catch { throw Self.translate(error) }
    }

    func readState(_ reference: BackendFormReference) async throws -> BackendFormState {
        do {
            return try await client.getV2FormState(sessionID: reference.key.sessionID, formID: reference.key.formID,
                directory: reference.directory, workspaceID: reference.workspaceID).backendState
        } catch { throw Self.translate(error) }
    }

    func reply(_ reference: BackendFormReference, answer: BackendFormAnswer) async throws {
        do {
            try await client.replyToV2Form(sessionID: reference.key.sessionID, formID: reference.key.formID,
                answer: answer.mapValues(\.jsonValue), directory: reference.directory, workspaceID: reference.workspaceID)
        } catch { throw Self.translate(error) }
    }

    func cancel(_ reference: BackendFormReference) async throws {
        do {
            try await client.cancelV2Form(sessionID: reference.key.sessionID, formID: reference.key.formID,
                directory: reference.directory, workspaceID: reference.workspaceID)
        } catch { throw Self.translate(error) }
    }

    private static func translate(_ error: Error) -> Error {
        if error is CancellationError { return error }
        guard case OpenCodeAPIError.httpError(let status, let body) = error else { return BackendSessionFormsError.uncertain }
        struct Failure: Decodable { let _tag: String; let message: String }
        let failure = try? JSONDecoder().decode(Failure.self, from: Data(body.utf8))
        switch (status, failure?._tag) {
        case (400, "FormInvalidAnswerError"):
            return BackendSessionFormsError.invalidAnswer(message: failure?.message ?? "")
        case (400, "InvalidRequestError"):
            return BackendSessionFormsError.invalidAnswer(message: "")
        case (409, "FormAlreadySettledError"): return BackendSessionFormsError.alreadySettled
        case (404, "FormNotFoundError"), (404, "SessionNotFoundError"): return BackendSessionFormsError.unavailable
        case (401, _), (403, _): return BackendSessionFormsError.unauthorized
        default: return BackendSessionFormsError.uncertain
        }
    }
}
