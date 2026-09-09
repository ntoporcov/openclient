import Foundation

@MainActor
struct FunAndGamesCoordinator {
    let store: FunAndGamesStore

    // Called only from an explicit game-start action. Restoration never asks for weather/location.
    func start(
        game: FunAndGamesGame,
        model: OpenCodeModelReference,
        owner: FunAndGamesOwner,
        connection: BackendConnection,
        city: () -> FindPlaceGameCity = { FindPlaceGame.randomCity() },
        weather: (FindPlaceGameCity) async -> FindPlaceWeatherSummary = { await FindPlaceWeatherProvider.summary(for: $0) },
        isCurrent: @escaping @MainActor () -> Bool,
        sessionCreated: @escaping @MainActor (FunAndGamesSetup) async throws -> Void = { _ in }
    ) async throws -> FunAndGamesSetup? {
        func check() throws {
            try Task.checkCancellation()
            guard !connection.isClosed, isCurrent(), owner.backendID == connection.descriptor.id else { throw BackendError.disconnected }
        }
        try check()
        guard store.beginSetup(for: game, owner: owner) else { return nil }
        defer { store.finishSetup(for: game, owner: owner) }

        var setup = store.setup(for: game, owner: owner)
        if setup == nil || setup?.phase == .admitted || setup?.phase == .rejected || setup?.phase == .failed {
            setup = FunAndGamesSetup(game: game, model: model, messageID: OpenCodeIdentifier.message())
        }
        guard var setup else { return nil }
        store.saveSetup(setup, owner: owner)
        do {
            switch setup.phase {
            case .creating, .creationUncertain:
                // The create API has no caller-supplied identity. Never repeat an ambiguous create.
                return setup
            case .submitting, .uncertain:
                try await sessionCreated(setup)
                try check()
                return try await reconcile(setup, owner: owner, connection: connection, isCurrent: isCurrent)
            default: break
            }

            if setup.session == nil {
                let snapshot = try await connection.projects.projectsSnapshot()
                try check()
                guard let directory = snapshot.defaultDirectory, !directory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw BackendError.invalidScope
                }
                if let resolver = connection.projectLifecycle {
                    let resolution = try await resolver.resolveProject(directory: directory)
                    try check()
                    guard resolution.scope.directory == directory, resolution.scope.workspaceID == nil else { throw BackendError.invalidScope }
                    setup.scope = resolution.scope
                    setup.project = resolution.project
                } else {
                    setup.project = snapshot.projects.first { $0.worktree == directory }
                        ?? snapshot.currentProject.flatMap { $0.worktree == directory ? $0 : nil }
                    setup.scope = .init(projectID: setup.project?.id, directory: directory)
                }
                switch setup.game {
                case .findPlace:
                    let selectedCity = city()
                    let summary = await weather(selectedCity)
                    try check()
                    setup.city = selectedCity
                    setup.weather = summary
                    setup.prompt = FindPlaceGame.starterPrompt(city: selectedCity, weather: summary)
                case .findBug(let language):
                    setup.prompt = FindBugGame.starterPrompt(language: language)
                }
                setup.phase = .creating
                store.saveSetup(setup, owner: owner)
                let title = setup.game == .findPlace ? String(localized: "Find the Place") : String(localized: "Find the Bug")
                let session = try await connection.sessions.createSession(.init(title: title, scope: setup.scope, agent: "plan", model: setup.model))
                setup.session = session
                setup.scope = .init(projectID: session.projectID ?? setup.scope.projectID,
                    directory: session.directory ?? setup.scope.directory, workspaceID: session.workspaceID)
                setup.phase = .created
                // Capture late receipts under the original owner even after disconnect/navigation.
                store.saveSetup(setup, owner: owner)
                try check()
            }
            guard let session = setup.session else { throw BackendError.invalidScope }
            try await sessionCreated(setup)
            try check()
            setup.phase = .configuring
            store.saveSetup(setup, owner: owner)
            if let selection = connection.sessionSelection {
                try await selection.setModel(sessionID: session.id, model: setup.model, variant: nil, scope: setup.scope)
                try check()
                try await selection.setAgent(sessionID: session.id, agent: "plan", scope: setup.scope)
                try check()
            }
            setup.phase = .submitting
            store.saveSetup(setup, owner: owner)
            let admission = try await connection.chat.submit(.init(sessionID: session.id, messageID: setup.messageID,
                text: setup.prompt, scope: setup.scope, agent: "plan", model: setup.model))
            switch admission {
            case let .accepted(sessionID, messageID) where sessionID == session.id && messageID == setup.messageID:
                setup.phase = .admitted
            case let .rejected(sessionID, messageID) where sessionID == session.id && messageID == setup.messageID:
                setup.phase = .rejected
            default: setup.phase = .uncertain
            }
            store.saveSetup(setup, owner: owner)
            try check()
            return store.setup(for: session.id, owner: owner)
        } catch {
            switch setup.phase {
            case .creating: setup.phase = .creationUncertain
            case .submitting: setup.phase = .uncertain
            case .preparing: setup.phase = .failed
            default: break
            }
            store.saveSetup(setup, owner: owner)
            throw error
        }
    }

    func reconcile(_ checkpoint: FunAndGamesSetup, owner: FunAndGamesOwner, connection: BackendConnection,
                   isCurrent: @escaping @MainActor () -> Bool) async throws -> FunAndGamesSetup {
        var setup = checkpoint
        guard !Task.isCancelled, !connection.isClosed, isCurrent(), owner.backendID == connection.descriptor.id,
              let session = setup.session else { throw BackendError.disconnected }
        var cursor: String?
        var seen = Set<String>()
        repeat {
            let page = try await connection.chat.transcript(sessionID: session.id, scope: setup.scope, cursor: cursor, limit: 100)
            guard !Task.isCancelled, !connection.isClosed, isCurrent() else { throw BackendError.disconnected }
            if page.messages.contains(where: { $0.id == setup.messageID && $0.info.sessionID == session.id && $0.info.role == "user" }) {
                setup.phase = .admitted
                break
            }
            cursor = page.olderCursor
            if let cursor, !seen.insert(cursor).inserted { break }
        } while cursor != nil
        if setup.phase != .admitted, let pending = connection.sessionSelection as? any BackendPendingInputReading {
            let ids = try await pending.pendingInputIDs(sessionID: session.id, scope: setup.scope)
            guard !Task.isCancelled, !connection.isClosed, isCurrent() else { throw BackendError.disconnected }
            if ids.contains(setup.messageID) { setup.phase = .admitted }
        }
        // Absence is not rejection. Retain the same session/message checkpoint, without reposting.
        store.saveSetup(setup, owner: owner)
        if let current = store.setup(for: session.id, owner: owner), current.messageID == setup.messageID {
            return current
        }
        return setup
    }
}
