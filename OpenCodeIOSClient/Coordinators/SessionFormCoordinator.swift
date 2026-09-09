import Foundation

@MainActor
struct SessionFormContext {
    let connectionID: UUID
    let service: any BackendSessionFormsService
    let reference: BackendFormReference
    /// Captures connection lifetime, registry generation, owner scope and session lifecycle.
    let isCurrent: @MainActor () -> Bool
    var didSettle: @MainActor (BackendFormKey) -> Void = { _ in }
}

@MainActor
struct SessionFormCoordinator {
    let store: SessionFormStore

    func submit(_ context: SessionFormContext) async {
        guard !Task.isCancelled, context.isCurrent(), let form = store.forms[context.reference.key],
              store.state(for: form.key).phase == .ready else { return }
        do {
            let answer = try form.contract.answer(values: store.state(for: form.key).draft)
            await perform(context, answer: answer, cancel: false)
        } catch BackendFormError.invalidField(let title) {
            store.showValidationError(String(localized: "Check the value for \(String(title.prefix(100)))."), key: form.key)
        } catch {
            store.showValidationError(String(localized: "This form contains unsupported fields. You can cancel the request."), key: form.key)
        }
    }

    func cancel(_ context: SessionFormContext) async {
        await perform(context, answer: nil, cancel: true)
    }

    func refresh(_ context: SessionFormContext) async {
        guard !Task.isCancelled, context.isCurrent() else { return }
        let key = context.reference.key
        let generation = store.generation
        guard let token = store.begin(.checking, reference: context.reference, connectionID: context.connectionID) else { return }
        defer { store.finish(token, key: key, phase: .uncertain) }
        await reconcile(context, token: token, generation: generation)
    }

    private func perform(_ context: SessionFormContext, answer: BackendFormAnswer?, cancel: Bool) async {
        guard !Task.isCancelled, context.isCurrent() else { return }
        let key = context.reference.key
        let generation = store.generation
        guard let token = store.begin(cancel ? .cancelling : .submitting, reference: context.reference, connectionID: context.connectionID) else { return }
        // Cancellation cannot prove an in-flight mutation did not reach the server.
        defer { store.finish(token, key: key, phase: .uncertain) }
        do {
            guard valid(context, token: token, generation: generation) else { return }
            if cancel { try await context.service.cancel(context.reference) }
            else if let answer { try await context.service.reply(context.reference, answer: answer) }
            guard valid(context, token: token, generation: generation) else { return }
            settle(context)
        } catch {
            guard valid(context, token: token, generation: generation) else { return }
            switch error as? BackendSessionFormsError {
            case .invalidAnswer(let message):
                store.finish(token, key: key, phase: .ready, message: Self.validationMessage(message))
            case .unavailable:
                store.finish(token, key: key, phase: .unavailable,
                    message: String(localized: "This form is no longer available. Refresh its status."))
            default:
                // Conflicts and ambiguous failures are reads only; never replay a mutation.
                await reconcile(context, token: token, generation: generation, afterMutationFailure: true)
            }
        }
    }

    private func reconcile(_ context: SessionFormContext, token: UUID, generation: UUID, afterMutationFailure: Bool = false) async {
        guard valid(context, token: token, generation: generation) else { return }
        let key = context.reference.key
        do {
            let state = try await context.service.readState(context.reference)
            guard valid(context, token: token, generation: generation) else { return }
            switch state {
            case .pending:
                store.finish(token, key: key, phase: .ready, message: afterMutationFailure
                    ? String(localized: "The form is still pending. Review your answers before trying again.") : nil)
            case .answered, .cancelled: settle(context)
            }
        } catch {
            guard valid(context, token: token, generation: generation) else { return }
            let unavailable = (error as? BackendSessionFormsError) == .unavailable
            store.finish(token, key: key, phase: unavailable ? .unavailable : .uncertain,
                message: unavailable
                    ? String(localized: "This form is no longer available. Refresh its status.")
                    : String(localized: "The form status is unknown. Check status before trying again."))
        }
    }

    private func valid(_ context: SessionFormContext, token: UUID, generation: UUID) -> Bool {
        !Task.isCancelled && context.isCurrent() && store.owns(token, reference: context.reference,
            connectionID: context.connectionID, generation: generation)
    }

    private func settle(_ context: SessionFormContext) {
        store.settle(context.reference.key)
        context.didSettle(context.reference.key)
    }

    private static func validationMessage(_ message: String) -> String {
        // Never display arbitrary server text: even validation errors can echo submitted secrets.
        let reason = String(message.prefix(256)).components(separatedBy: ":").first ?? ""
        switch reason {
        case "Form field does not match pattern", "Form field has invalid pattern", "Expected email for form field",
             "Expected URI for form field", "Expected date for form field", "Expected date-time for form field":
            return String(localized: "The server rejected the answer format or pattern. Check the field values.")
        case "Missing required form field", "External form field must be acknowledged":
            return String(localized: "The server requires an answer or acknowledgment for every required field.")
        default:
            return String(localized: "The server rejected this answer. Check the field values and try again.")
        }
    }
}
