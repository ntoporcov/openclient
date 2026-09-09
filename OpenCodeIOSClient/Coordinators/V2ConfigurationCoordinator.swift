import Foundation

@MainActor
struct V2ConfigurationContext {
    let client: OpenCodeAPIClient
    let directory: String?
    let isCurrent: @MainActor () -> Bool
    let refreshModels: @MainActor () async -> Void
}

@MainActor
struct V2ConfigurationCoordinator {
    let store: V2ProviderStore

    @discardableResult
    func load(_ context: V2ConfigurationContext) async -> Bool {
        guard !Task.isCancelled, context.isCurrent() else { return false }
        if let previous = store.context, !previous.isCurrent() || previous.directory != context.directory
            || previous.client.config != context.client.config || previous.client.session !== context.client.session {
            store.reset()
        }
        let generation = store.generation
        let requestID = UUID()
        store.discoveryRequestID = requestID
        store.context = context
        store.isLoading = true
        store.discoveryErrorMessage = nil
        defer {
            if store.generation == generation, store.discoveryRequestID == requestID, context.isCurrent() {
                store.isLoading = false
            }
        }
        do {
            let integrations = try await context.client.v2Integrations(directory: context.directory)
            guard valid(context, generation), store.discoveryRequestID == requestID else { return false }
            store.integrations = integrations
            store.isReady = true
            return true
        } catch {
            guard valid(context, generation), store.discoveryRequestID == requestID else { return false }
            store.discoveryErrorMessage = OpenCodeV2ConfigurationError.requestFailed.localizedDescription
            return false
        }
    }

    func connect(integrationID: String, method: OpenCodeV2IntegrationMethod, key: String, values: [String: OpenCodeJSONValue]) {
        guard let context = store.context, context.isCurrent(), !store.isBusy, store.attempt == nil,
              store.integrations.contains(where: { $0.id == integrationID && $0.methods.contains(method) }) else { return }
        store.stopAttempt()
        let generation = store.generation
        store.isBusy = true
        store.operationTask = Task {
            defer { if store.generation == generation, context.isCurrent() { store.isBusy = false } }
            do {
                let answer = try method.answer(values: values)
                guard valid(context, generation) else { return }
                switch method {
                case .key:
                    let key = key.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !key.isEmpty else { throw OpenCodeV2ConfigurationError.invalidField(String(localized: "API Key")) }
                    try await context.client.v2ConnectKey(integrationID: integrationID, key: key, answer: answer, directory: context.directory)
                    guard valid(context, generation) else { return }
                    await finish(context, generation)
                case .oauth(let methodID, _, _):
                    let attempt = try await context.client.v2BeginOAuth(integrationID: integrationID, methodID: methodID, answer: answer, directory: context.directory)
                    guard valid(context, generation) else { return }
                    store.attempt = attempt
                    store.attemptIntegrationID = integrationID
                    store.attemptStatus = .pending
                    startPolling(context, generation, integrationID: integrationID, attempt: attempt)
                default: throw OpenCodeV2ConfigurationError.unsupportedForm
                }
            } catch {
                fail(error, context, generation)
            }
        }
    }

    func complete(code: String) {
        guard let context = store.context, context.isCurrent(), let attempt = store.attempt,
              let integrationID = store.attemptIntegrationID, attempt.mode == .code,
              store.attemptStatus == .pending, !store.isBusy else { return }
        let generation = store.generation
        store.isBusy = true
        store.operationTask = Task {
            defer { if store.generation == generation, context.isCurrent() { store.isBusy = false } }
            do {
                guard attempt.time.expiration > Date() else { throw OpenCodeV2ConfigurationError.expired }
                guard valid(context, generation) else { return }
                try await context.client.v2CompleteOAuth(integrationID: integrationID, attemptID: attempt.attemptID,
                                                         code: code, directory: context.directory)
                guard valid(context, generation) else { return }
                await finish(context, generation)
            } catch { fail(error, context, generation) }
        }
    }

    func removeCredential(integrationID: String, credentialID: String) {
        guard let context = store.context, context.isCurrent(), !store.isBusy, store.attempt == nil,
              store.integrations.contains(where: { integration in
                  integration.id == integrationID && integration.connections.contains {
                      if case .credential(let id, _) = $0 { return id == credentialID }
                      return false
                  }
              }) else { return }
        store.stopAttempt()
        let generation = store.generation
        store.isBusy = true
        store.operationTask = Task {
            defer { if store.generation == generation, context.isCurrent() { store.isBusy = false } }
            do {
                guard valid(context, generation) else { return }
                try await context.client.v2RemoveCredential(credentialID: credentialID, directory: context.directory)
                guard valid(context, generation) else { return }
                await finish(context, generation, connected: false)
            } catch { fail(error, context, generation) }
        }
    }

    func cancelAttempt() {
        let context = store.context
        let attempt = store.attempt
        let integrationID = store.attemptIntegrationID
        store.stopAttempt()
        guard let context, context.isCurrent(), let attempt, let integrationID else { return }
        let generation = store.generation
        store.isBusy = true
        store.operationTask = Task {
            defer { if store.generation == generation, context.isCurrent() { store.isBusy = false } }
            do {
                guard valid(context, generation) else { return }
                try await context.client.v2CancelOAuth(integrationID: integrationID, attemptID: attempt.attemptID, directory: context.directory)
                guard valid(context, generation) else { return }
            } catch { fail(error, context, generation) }
        }
    }

    private func startPolling(_ context: V2ConfigurationContext, _ generation: UUID, integrationID: String, attempt: OpenCodeV2OAuthAttempt) {
        store.pollingTask?.cancel()
        store.pollingTask = Task {
            // OAuth status polling is the protocol, not a fallback refresh. Also watch code-attempt expiry.
            let deadline = min(attempt.time.expiration, Date().addingTimeInterval(600))
            do {
                for _ in 0..<600 {
                    guard valid(context, generation) else { return }
                    guard store.attempt?.attemptID == attempt.attemptID, store.attemptStatus == .pending else { return }
                    guard Date() < deadline else { throw OpenCodeV2ConfigurationError.expired }
                    if attempt.mode == .auto {
                        let status = try await context.client.v2OAuthStatus(integrationID: integrationID, attemptID: attempt.attemptID, directory: context.directory)
                        guard valid(context, generation) else { return }
                        store.attemptStatus = status.status
                        switch status.status {
                        case .complete: await finish(context, generation); return
                        case .failed: throw OpenCodeV2ConfigurationError.requestFailed
                        case .expired: throw OpenCodeV2ConfigurationError.expired
                        case .pending: break
                        }
                    }
                    try await Task.sleep(for: .seconds(1))
                }
                throw OpenCodeV2ConfigurationError.expired
            } catch { fail(error, context, generation) }
        }
    }

    private func finish(_ context: V2ConfigurationContext, _ generation: UUID, connected: Bool = true) async {
        guard valid(context, generation) else { return }
        store.attemptStatus = connected ? .complete : nil
        store.attempt = nil
        store.attemptIntegrationID = nil
        store.didConnect = connected
        // Canonical discovery after a successful mutation; never dispose or retry a mutation.
        guard await load(context), valid(context, generation) else { return }
        let requestID = store.discoveryRequestID
        await context.refreshModels()
        guard valid(context, generation), store.discoveryRequestID == requestID else { return }
    }

    private func valid(_ context: V2ConfigurationContext, _ generation: UUID) -> Bool {
        !Task.isCancelled && store.generation == generation && context.isCurrent()
    }

    private func fail(_ error: Error, _ context: V2ConfigurationContext, _ generation: UUID) {
        guard valid(context, generation) else { return }
        // Server error bodies can echo submitted secrets. Do not publish them into app diagnostics/UI.
        store.errorMessage = (error as? OpenCodeV2ConfigurationError)?.localizedDescription
            ?? OpenCodeV2ConfigurationError.requestFailed.localizedDescription
        if store.attempt != nil {
            store.attemptStatus = (error as? OpenCodeV2ConfigurationError) == .expired ? .expired : .failed
        }
    }
}
