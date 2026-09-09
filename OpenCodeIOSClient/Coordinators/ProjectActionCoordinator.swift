import Foundation

@MainActor
final class ProjectActionCoordinator {
    private enum RunError: Error { case uncertainAdmission, failedCommand }
    private let store: ProjectActionStore
    private var tasks: [String: (connectionID: UUID, task: Task<Void, Never>)] = [:]
    private var wakeups: [String: AsyncStream<Void>.Continuation] = [:]

    init(store: ProjectActionStore) { self.store = store }

    func run(
        action: OpenCodeAction,
        scope: ProjectActionScope,
        connection: BackendConnection,
        commands: any BackendCommandsService,
        agent: String?,
        model: OpenCodeModelReference?,
        variant: String?,
        timeout: Duration = .seconds(300),
        isCurrent: @escaping @MainActor () -> Bool,
        sessionCreated: @escaping @MainActor (OpenCodeSession) -> Void = { _ in }
    ) async {
        guard !Task.isCancelled, !connection.isClosed, isCurrent(),
              scope.backendID == connection.descriptor.id, scope.contractID == commands.actionContractID,
              let run = store.begin(action: action, scope: scope) else { return }
        let signal = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        wakeups[run.id] = signal.continuation
        let task = Task { @MainActor [self] in
            @MainActor func check() throws {
                try Task.checkCancellation()
                guard !connection.isClosed, isCurrent() else { throw BackendError.disconnected }
            }
            do {
                try check()
                let session = try await connection.sessions.createSession(.init(
                    title: "/\(action.commandName) [\(run.id)]", scope: scope.backendScope, agent: agent, model: model, variant: variant
                ))
                // Journal even a late create receipt, but never send follow-ups after a switch.
                store.update(id: run.id) { $0.sessionID = session.id }
                try check()
                store.update(id: run.id) { $0.state = .runningCommand }
                sessionCreated(session)
                try check()
                let receipt = try await commands.submitCommand(.init(
                    sessionID: session.id, messageID: run.commandMessageID, command: action.commandName,
                    scope: scope.backendScope, agent: agent, model: model, variant: variant
                ))
                try check()
                guard case let .accepted(sessionID, messageID) = receipt,
                      sessionID == session.id, messageID == run.commandMessageID else { throw RunError.uncertainAdmission }

                var iterator = signal.stream.makeAsyncIterator()
                for inputID in [run.commandMessageID, run.evaluationMessageID] {
                    try check()
                    if try await commands.needsAttention(sessionID: session.id, scope: scope.backendScope) {
                        store.reveal(id: run.id, needsAttention: true)
                    }
                    try check()
                    try await commands.waitUntilIdle(sessionID: session.id, scope: scope.backendScope)
                    var turn: BackendActionTurn?
                    while turn == nil {
                        try check()
                        turn = try await commands.completedTurn(sessionID: session.id, userMessageID: inputID, scope: scope.backendScope)
                        try check()
                        if turn == nil {
                            guard await iterator.next() != nil else { throw CancellationError() }
                        }
                    }
                    guard let turn, turn.sessionID == session.id, turn.userMessageID == inputID else { throw RunError.uncertainAdmission }
                    if try await commands.needsAttention(sessionID: session.id, scope: scope.backendScope) {
                        store.reveal(id: run.id, needsAttention: true)
                    }
                    try check()
                    if inputID == run.commandMessageID {
                        guard !turn.failed else { throw RunError.failedCommand }
                        store.update(id: run.id) { $0.state = .checkingResult }
                        let evaluation = try await connection.chat.submit(.init(
                            sessionID: session.id, messageID: run.evaluationMessageID,
                            text: Self.resultPrompt(commandName: action.commandName, runID: run.id),
                            scope: scope.backendScope, agent: agent, model: model, variant: variant
                        ))
                        try check()
                        guard case let .accepted(sessionID, messageID) = evaluation,
                              sessionID == session.id, messageID == run.evaluationMessageID else { throw RunError.uncertainAdmission }
                    } else {
                        let success = store.run(id: run.id).map { Self.isSuccess(turn, run: $0) } ?? false
                        store.update(id: run.id) {
                            $0.state = success ? .succeeded : .failed
                            if !success { $0.revealed = true }
                        }
                    }
                }
            } catch {
                store.update(id: run.id) {
                    $0.state = Task.isCancelled || error is CancellationError || error is BackendError ? .interrupted : .failed
                    $0.revealed = true
                }
            }
        }
        tasks[run.id] = (connection.id, task)
        let deadline = Task {
            do {
                try await Task.sleep(for: timeout)
                guard store.run(id: run.id)?.state.isRunning == true else { return }
                task.cancel()
                store.update(id: run.id) { $0.state = .interrupted; $0.revealed = true }
                signal.continuation.finish()
            } catch { }
        }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        deadline.cancel()
        signal.continuation.finish()
        wakeups[run.id] = nil
        tasks[run.id] = nil
    }

    func cancel(connectionID: UUID) {
        for (id, entry) in tasks where entry.connectionID == connectionID {
            entry.task.cancel()
            wakeups[id]?.finish()
            store.update(id: id) {
                if $0.state.isRunning { $0.state = .interrupted; $0.revealed = true }
            }
        }
    }

    func receive(_ signal: BackendActionSignal, backendID: String, contractID: String) {
        let sessionID: String
        let attention: Bool
        switch signal {
        case let .needsAttention(id): sessionID = id; attention = true
        case let .sessionParent(_, parentID): sessionID = parentID; attention = true
        case let .execution(id): sessionID = id; attention = false
        }
        for run in store.runs where run.scope.backendID == backendID && run.scope.contractID == contractID && run.sessionID == sessionID {
            if attention { store.reveal(id: run.id, needsAttention: true) }
            wakeups[run.id]?.yield(())
        }
    }

    static func isSuccess(_ turn: BackendActionTurn, run: ProjectActionRun) -> Bool {
        !turn.failed && turn.sessionID == run.sessionID && turn.userMessageID == run.evaluationMessageID
            && turn.text.trimmingCharacters(in: .whitespacesAndNewlines) == "OPENCLIENT_ACTION_RESULT:\(run.id):SUCCESS"
    }

    static func resultPrompt(commandName: String, runID: String) -> String {
        """
        Evaluate the just-completed /\(commandName) action in this session.
        Reply with exactly one line and no other text:
        OPENCLIENT_ACTION_RESULT:\(runID):SUCCESS
        or
        OPENCLIENT_ACTION_RESULT:\(runID):FAILURE
        Use SUCCESS only if the action completed successfully and no user debugging is needed.
        Use FAILURE if anything failed, is ambiguous, or requires user attention.
        """
    }
}
