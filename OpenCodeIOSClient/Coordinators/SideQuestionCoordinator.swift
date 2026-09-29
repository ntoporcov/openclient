import Foundation

@MainActor
struct SideQuestionPresentation: Identifiable {
    let id = UUID()
    let store: SideQuestionStore
    let coordinator: SideQuestionCoordinator
}

@MainActor
struct SideQuestionCoordinator {
    let generate: (String) async throws -> String

    func answer(store: SideQuestionStore) async {
        guard let request = store.request else { return }
        do {
            try Task.checkCancellation()
            let answer = try await generate(request.prompt)
            try Task.checkCancellation()
            store.complete(answer, requestID: request.id)
        } catch {
            if Task.isCancelled || error is CancellationError {
                store.cancel(requestID: request.id)
            } else {
                store.fail(error.localizedDescription, requestID: request.id)
            }
        }
    }
}
