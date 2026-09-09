import XCTest
@testable import OpenClient

@MainActor
final class FunAndGamesLifecycleTests: XCTestCase {
    private let model = OpenCodeModelReference(providerID: "mock", modelID: "never-executed")
    private let owner = FunAndGamesOwner(backendID: "games", profile: .v2)
    private let city = FindPlaceGameCity(name: "Paris", country: "France", latitude: 48.8566, longitude: 2.3522)
    private var weather: FindPlaceWeatherSummary {
        .init(text: "Cloudy, 18 C", provider: "Fixture", requestedAt: Date(timeIntervalSince1970: 0), errorDescription: nil)
    }

    func testScopeIsBoundBeforeFacadeCreationAndRebindsWithBackendOwner() {
        let app = AppViewModel(backendFactory: HomeTestBackend())
        XCTAssertNotNil(app.funAndGamesStore.ownerProvider)
        let language = FindBugGame.supportedLanguages[0]
        app.funAndGamesStore.findBugSessionsByID["same-id"] = .init(sessionID: "same-id", language: language)
        app.backendConnection = GameBackend().connection()
        app.connectionStore.applySuccessfulV2Connection(version: "mock", healthy: true)
        XCTAssertNil(app.funAndGamesStore.findBugGame(for: "same-id"))
    }

    func testPendingSetupBlocksFacadeAndDirectSendUntilCanonicalHydration() async throws {
        let app = AppViewModel(backendFactory: HomeTestBackend())
        let fake = GameBackend()
        fake.admission = .uncertain
        let connection = fake.connection()
        app.backendConnection = connection
        app.connectionStore.applySuccessfulV2Connection(version: "mock", healthy: true)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        _ = try await FunAndGamesCoordinator(store: app.funAndGamesStore).start(
            game: game, model: model, owner: app.funAndGamesOwner, connection: connection, isCurrent: { true })
        let setup = try XCTUnwrap(app.funAndGamesStore.setup(for: game, owner: app.funAndGamesOwner))
        let session = try XCTUnwrap(setup.session)
        let facadeSend = await app.chatFacade.sendMessage("Too early", in: session, userVisible: true)
        let directSend = await app.sendMessage("Too early", in: session, userVisible: true)
        XCTAssertFalse(facadeSend)
        XCTAssertFalse(directSend)
        XCTAssertEqual(fake.submissions.count, 1)
        fake.messages = [.local(role: "user", text: setup.prompt, messageID: setup.messageID, sessionID: session.id)]
        _ = app.beginSessionNavigation(session)
        app.directoryStore.insertV2Session(session)
        let hydrated = await app.hydrateV2Transcript(for: session, navigationGeneration: app.sessionNavigationGeneration,
            expectedDirectoryKey: app.directoryStoreRegistry.activeKey)
        XCTAssertTrue(hydrated)
        XCTAssertFalse(app.funAndGamesStore.hasPendingSetup(for: session.id))
        XCTAssertFalse(app.shouldMeterPrompts(for: session.id))
        XCTAssertEqual(fake.submissions.count, 1)
    }

    func testV2FacadeRequiresBootstrapThenCreatesSelectsAndPreservesSpecialMetering() async throws {
        let previousDrafts = UserDefaults.standard.data(forKey: OpenClientStorageKey.messageDraftsByChat)
        defer { UserDefaults.standard.set(previousDrafts, forKey: OpenClientStorageKey.messageDraftsByChat) }
        let app = AppViewModel()
        let fake = GameBackend()
        app.backendConnection = fake.connection()
        app.connectionStore.applySuccessfulV2Connection(version: "mock", healthy: true)
        let games = app.funAndGamesFacade
        app.funAndGamesPreferences.showsSection = true
        XCTAssertFalse(games.showsSection, "Core location bootstrap is not complete")
        app.projectStore.defaultServerDirectory = "/server/default"
        XCTAssertTrue(games.showsSection, "The core game lifecycle does not require commands")
        let usage = app.usageMeter
        games.presentFindBugLanguageSheet()
        games.selectFindBugLanguage(FindBugGame.supportedLanguages[0])
        XCTAssertTrue(games.isShowingFindBugModelSheet)
        await games.startFindBugGame(model: model)
        XCTAssertEqual(app.selectedSession?.id, "same-id")
        XCTAssertEqual(app.currentProject?.id, "server-project")
        XCTAssertEqual(app.selectedDirectory, "/server/default")
        XCTAssertEqual(app.chatStore.preparedSessionID, "same-id")
        XCTAssertEqual(app.selectedModelsBySessionID["same-id"], model)
        XCTAssertEqual(app.effectiveAgentName(for: try XCTUnwrap(app.selectedSession)), "plan")
        XCTAssertEqual(games.setupPhase(for: "same-id"), .admitted)
        XCTAssertFalse(games.hasPendingSetup(for: "same-id"))
        XCTAssertFalse(app.shouldMeterPrompts(for: "same-id"))
        XCTAssertEqual(app.usageMeter, usage)
        XCTAssertTrue(app.messages.isEmpty, "Hidden setup is not inserted as a visible optimistic user message")
        XCTAssertNil(app.errorMessage)
        XCTAssertFalse(app.isLoading)
        XCTAssertEqual(fake.calls, ["projects", "resolve", "create", "transcript", "model", "agent", "submit"])
        app.connectionStore.apiProfile = nil
        XCTAssertFalse(games.showsSection, "An injected plugin has not opted into a complete game lifecycle")
        XCTAssertNil(app.findBugGame(for: "same-id"))
        app.backendConnection?.close()
    }

    func testEveryOfferedGameCreatesConfiguresAndSubmitsHiddenSetupWithoutCatalogOrFees() async throws {
        let games: [FunAndGamesGame] = [.findPlace] + FindBugGame.supportedLanguages.map { .findBug($0) }
        for game in games {
            let fake = GameBackend()
            let store = FunAndGamesStore()
            store.ownerProvider = { self.owner }
            var weatherRequests = 0
            var selected: OpenCodeSession?
            let result = try await FunAndGamesCoordinator(store: store).start(game: game, model: model,
                owner: owner, connection: fake.connection(), city: { self.city }, weather: { _ in
                    weatherRequests += 1
                    return self.weather
                }, isCurrent: { true }, sessionCreated: { setup in
                    selected = setup.session
                    XCTAssertNotNil(store.setupPhase(for: "same-id"))
                    fake.calls.append("select")
                })
            let setup = try XCTUnwrap(result)
            XCTAssertEqual(setup.phase, .admitted)
            XCTAssertEqual(selected?.id, "same-id")
            XCTAssertEqual(fake.calls, ["projects", "resolve", "create", "select", "model", "agent", "submit"])
            XCTAssertEqual(fake.creations.count, 1)
            XCTAssertEqual(fake.creations.first?.scope, .init(projectID: "server-project", directory: "/server/default"))
            XCTAssertEqual(fake.creations.first?.agent, "plan")
            XCTAssertEqual(fake.creations.first?.model, model)
            let submission = try XCTUnwrap(fake.submissions.first)
            XCTAssertEqual(submission.messageID, setup.messageID)
            XCTAssertEqual(submission.sessionID, selected?.id)
            XCTAssertEqual(submission.scope, setup.scope)
            XCTAssertEqual(submission.agent, "plan")
            XCTAssertEqual(submission.model, model)
            XCTAssertTrue(submission.attachments.isEmpty)
            XCTAssertTrue(submission.agentMentions.isEmpty)
            XCTAssertFalse(store.hasPendingSetup(for: "same-id"))
            switch game {
            case .findPlace:
                XCTAssertEqual(weatherRequests, 1)
                XCTAssertTrue(submission.text.contains(FindPlaceGame.setupMarker))
                XCTAssertEqual(store.findPlaceGame(for: "same-id")?.city, city)
            case .findBug(let language):
                XCTAssertEqual(weatherRequests, 0)
                XCTAssertTrue(submission.text.contains(FindBugGame.setupMarker))
                XCTAssertEqual(store.findBugGame(for: "same-id")?.language, language)
            }
        }
    }

    func testOptionalSelectionUsesSubmissionConfigurationWithoutProviderFetch() async throws {
        let fake = GameBackend()
        let result = try await FunAndGamesCoordinator(store: FunAndGamesStore()).start(
            game: .findBug(FindBugGame.supportedLanguages[0]), model: model, owner: owner,
            connection: fake.connection(selection: false, resolution: false), isCurrent: { true })
        XCTAssertEqual(result?.phase, .admitted)
        XCTAssertEqual(fake.calls, ["projects", "create", "submit"])
        XCTAssertEqual(fake.submissions.first?.model, model)
        XCTAssertEqual(fake.submissions.first?.agent, "plan")
    }

    func testMissingDefaultDirectoryDoesNotInventGlobalOrCreate() async {
        let fake = GameBackend()
        fake.defaultDirectory = nil
        do {
            _ = try await FunAndGamesCoordinator(store: FunAndGamesStore()).start(
                game: .findBug(FindBugGame.supportedLanguages[0]), model: model, owner: owner,
                connection: fake.connection(), isCurrent: { true })
            XCTFail("A concrete server location is required")
        } catch { XCTAssertEqual(error as? BackendError, .invalidScope) }
        XCTAssertEqual(fake.calls, ["projects"])
        XCTAssertTrue(fake.creations.isEmpty)
        XCTAssertTrue(fake.submissions.isEmpty)
    }

    func testUncertainAdmissionReconcilesPendingExactIdentityWithoutRecreatingOrReposting() async throws {
        let fake = GameBackend()
        fake.admission = .uncertain
        let store = FunAndGamesStore()
        store.ownerProvider = { self.owner }
        let coordinator = FunAndGamesCoordinator(store: store)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        let started = try await coordinator.start(game: game, model: model, owner: owner,
            connection: fake.connection(), isCurrent: { true })
        let first = try XCTUnwrap(started)
        XCTAssertEqual(first.phase, .uncertain)
        XCTAssertTrue(store.hasPendingSetup(for: "same-id"))
        let second = try await coordinator.start(game: game, model: model, owner: owner,
            connection: fake.connection(), isCurrent: { true })
        XCTAssertEqual(second?.phase, .uncertain, "Absence from transcript/pending is unknown")
        fake.pending = [first.messageID]
        let third = try await coordinator.start(game: game, model: model, owner: owner,
            connection: fake.connection(), isCurrent: { true })
        XCTAssertEqual(third?.phase, .admitted)
        XCTAssertEqual(third?.messageID, first.messageID)
        XCTAssertEqual(fake.creations.count, 1)
        XCTAssertEqual(fake.submissions.count, 1)
        XCTAssertFalse(store.hasPendingSetup(for: "same-id"))
    }

    func testRejectedSessionRemainsGuardedAfterAnotherGameOfTheSameKindStarts() async throws {
        for game in [FunAndGamesGame.findPlace, .findBug(FindBugGame.supportedLanguages[0])] {
            let app = AppViewModel(backendFactory: HomeTestBackend())
            let fake = GameBackend()
            fake.admission = .rejected
            let connection = fake.connection()
            app.backendConnection = connection
            app.connectionStore.applySuccessfulV2Connection(version: "mock", healthy: true)
            let owner = app.funAndGamesOwner
            let store = app.funAndGamesStore
            let coordinator = FunAndGamesCoordinator(store: store)
            let first = try await coordinator.start(game: game, model: model, owner: owner,
                connection: connection, city: { self.city }, weather: { _ in self.weather }, isCurrent: { true })
            let rejected = try XCTUnwrap(first)
            let sessionA = try XCTUnwrap(rejected.session)
            XCTAssertEqual(rejected.phase, .rejected)

            fake.createdSessionID = "session-B"
            fake.admission = .accepted
            let second = try await coordinator.start(game: game, model: model, owner: owner,
                connection: connection, city: { self.city }, weather: { _ in self.weather }, isCurrent: { true })
            let admitted = try XCTUnwrap(second)
            XCTAssertEqual(admitted.session?.id, "session-B")
            XCTAssertNotEqual(admitted.messageID, rejected.messageID)
            XCTAssertEqual(store.setupPhase(for: sessionA.id), .rejected)
            XCTAssertTrue(app.funAndGamesFacade.hasPendingSetup(for: sessionA.id))
            XCTAssertFalse(store.hasPendingSetup(for: "session-B"))
            XCTAssertFalse(app.shouldMeterPrompts(for: sessionA.id), "Game metadata is retained, but cannot enable an ordinary send")
            let usage = app.usageMeter
            let facadeSend = await app.chatFacade.sendMessage("Answer in rejected A", in: sessionA, userVisible: true, meterPrompt: false)
            let directSend = await app.sendMessage("Answer in rejected A", in: sessionA, userVisible: true, meterPrompt: false)
            XCTAssertFalse(facadeSend)
            XCTAssertFalse(directSend)
            await app.funAndGamesFacade.reconcileSetup(for: sessionA.id)
            XCTAssertEqual(store.setupPhase(for: sessionA.id), .rejected, "Reopening does not automatically retry a rejected setup")
            XCTAssertEqual(fake.creations.count, 2)
            XCTAssertEqual(fake.submissions.map(\.messageID), [rejected.messageID, admitted.messageID])
            XCTAssertEqual(app.usageMeter, usage)

            app.connectionStore.apiProfile = .legacy
            XCTAssertNil(store.setup(for: sessionA.id))
            app.connectionStore.apiProfile = .v2
            XCTAssertTrue(store.hasPendingSetup(for: sessionA.id))

            // Canonical evidence can still admit old A, without replacing B's creation checkpoint.
            let canonical = OpenCodeMessageEnvelope.local(role: "user", text: rejected.prompt,
                messageID: rejected.messageID, sessionID: sessionA.id)
            XCTAssertTrue(store.inferGames(from: [canonical], forSessionID: sessionA.id))
            store.saveSetup(rejected, owner: owner)
            XCTAssertEqual(store.setupPhase(for: sessionA.id), .admitted)
            XCTAssertFalse(store.hasPendingSetup(for: sessionA.id))
            XCTAssertFalse(app.shouldMeterPrompts(for: sessionA.id))
            XCTAssertEqual(store.setup(for: game, owner: owner)?.messageID, admitted.messageID)
            XCTAssertEqual(fake.creations.count, 2)
            XCTAssertEqual(fake.submissions.count, 2)
        }
    }

    func testStartingAnotherGameWhileUncertainReconcilesWithoutCreationAndRetainsOldDispositionAfterB() async throws {
        let fake = GameBackend()
        fake.admission = .uncertain
        let store = FunAndGamesStore()
        store.ownerProvider = { self.owner }
        let coordinator = FunAndGamesCoordinator(store: store)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        let connection = fake.connection()
        let first = try await coordinator.start(game: game, model: model, owner: owner,
            connection: connection, isCurrent: { true })
        let uncertain = try XCTUnwrap(first)
        let sessionA = try XCTUnwrap(uncertain.session)
        fake.createdSessionID = "session-B"
        fake.admission = .accepted
        let attemptedB = try await coordinator.start(game: game, model: model, owner: owner,
            connection: connection, isCurrent: { true })
        XCTAssertEqual(attemptedB?.session?.id, sessionA.id)
        XCTAssertEqual(attemptedB?.messageID, uncertain.messageID)
        XCTAssertTrue(store.hasPendingSetup(for: sessionA.id))
        XCTAssertEqual(fake.creations.count, 1)
        XCTAssertEqual(fake.submissions.count, 1)

        fake.pending = [uncertain.messageID]
        _ = try await coordinator.reconcile(uncertain, owner: owner, connection: connection, isCurrent: { true })
        let second = try await coordinator.start(game: game, model: model, owner: owner,
            connection: connection, isCurrent: { true })
        let admittedB = try XCTUnwrap(second)
        XCTAssertEqual(admittedB.session?.id, "session-B")
        store.saveSetup(uncertain, owner: owner)
        XCTAssertEqual(store.setupPhase(for: sessionA.id), .admitted, "Late uncertainty cannot erase canonical admission")
        XCTAssertEqual(store.setup(for: game, owner: owner)?.messageID, admittedB.messageID)
        let restoredA = try await coordinator.reconcile(uncertain, owner: owner, connection: connection, isCurrent: { true })
        XCTAssertEqual(restoredA.session?.id, sessionA.id)
        XCTAssertEqual(restoredA.phase, .admitted)
        XCTAssertEqual(store.setup(for: game, owner: owner)?.messageID, admittedB.messageID)
        XCTAssertEqual(fake.creations.count, 2)
        XCTAssertEqual(fake.submissions.map(\.messageID), [uncertain.messageID, admittedB.messageID])
    }

    func testConcurrentStartDoesNotDuplicateSessionOrSetup() async throws {
        let fake = GameBackend()
        let store = FunAndGamesStore()
        let coordinator = FunAndGamesCoordinator(store: store)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        let connection = fake.connection()
        let entered = expectation(description: "Create is pending")
        var release: CheckedContinuation<Void, Never>?
        fake.beforeCreate = {
            await withCheckedContinuation { continuation in
                release = continuation
                entered.fulfill()
            }
        }
        let first = Task { try await coordinator.start(game: game, model: model, owner: owner,
            connection: connection, isCurrent: { true }) }
        await fulfillment(of: [entered], timeout: 1)
        let duplicate = try await coordinator.start(game: game, model: model, owner: owner,
            connection: connection, isCurrent: { true })
        XCTAssertNil(duplicate)
        release?.resume()
        let result = try await first.value
        XCTAssertEqual(result?.phase, .admitted)
        XCTAssertEqual(fake.creations.count, 1)
        XCTAssertEqual(fake.submissions.count, 1)
    }

    func testThrownSubmitRetainsCheckpointAndCanonicalTranscriptWinsAfterReconnect() async throws {
        let fake = GameBackend()
        fake.failSubmit = true
        let store = FunAndGamesStore()
        let coordinator = FunAndGamesCoordinator(store: store)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        do {
            _ = try await coordinator.start(game: game, model: model, owner: owner, connection: fake.connection(), isCurrent: { true })
            XCTFail("Expected ambiguous transport failure")
        } catch { }
        let checkpoint = try XCTUnwrap(store.setup(for: game, owner: owner))
        XCTAssertEqual(checkpoint.phase, .uncertain)
        fake.messages = [.local(role: "user", text: checkpoint.prompt, messageID: checkpoint.messageID, sessionID: "same-id")]
        let restored = try await coordinator.start(game: game, model: model, owner: owner,
            connection: fake.connection(), isCurrent: { true })
        XCTAssertEqual(restored?.phase, .admitted)
        XCTAssertEqual(fake.creations.count, 1)
        XCTAssertEqual(fake.submissions.count, 1)
    }

    func testSelectionFailureResumesCreatedSessionWithOriginalModelAndSetupIdentity() async throws {
        let fake = GameBackend()
        fake.failSelection = true
        let store = FunAndGamesStore()
        let coordinator = FunAndGamesCoordinator(store: store)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        do {
            _ = try await coordinator.start(game: game, model: model, owner: owner, connection: fake.connection(), isCurrent: { true })
            XCTFail("Expected configuration failure")
        } catch { }
        let checkpoint = try XCTUnwrap(store.setup(for: game, owner: owner))
        XCTAssertEqual(checkpoint.session?.id, "same-id")
        XCTAssertTrue(fake.submissions.isEmpty)
        fake.failSelection = false
        let result = try await coordinator.start(game: game, model: .init(providerID: "different", modelID: "ignored"),
            owner: owner, connection: fake.connection(), isCurrent: { true })
        XCTAssertEqual(result?.messageID, checkpoint.messageID)
        XCTAssertEqual(result?.model, model)
        XCTAssertEqual(fake.creations.count, 1)
        XCTAssertEqual(fake.submissions.count, 1)
    }

    func testAmbiguousCreateNeverRepeatsCreation() async throws {
        let fake = GameBackend()
        fake.failCreate = true
        let store = FunAndGamesStore()
        let coordinator = FunAndGamesCoordinator(store: store)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        do {
            _ = try await coordinator.start(game: game, model: model, owner: owner, connection: fake.connection(), isCurrent: { true })
            XCTFail("Expected ambiguous create")
        } catch { }
        let result = try await coordinator.start(game: game, model: model, owner: owner,
            connection: fake.connection(), isCurrent: { true })
        XCTAssertEqual(result?.phase, .creationUncertain)
        XCTAssertEqual(fake.creations.count, 1)
        XCTAssertTrue(fake.submissions.isEmpty)
    }

    func testLateCreateReceiptIsCapturedUnderOriginalProfileWithoutFollowUp() async throws {
        let fake = GameBackend()
        let store = FunAndGamesStore()
        let original = owner
        var active = original
        store.ownerProvider = { active }
        fake.onCreate = { active = .init(backendID: original.backendID, profile: .legacy) }
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        do {
            _ = try await FunAndGamesCoordinator(store: store).start(game: game, model: model, owner: owner,
                connection: fake.connection(), isCurrent: { active == original })
            XCTFail("Changed profile must stop follow-up")
        } catch { }
        XCTAssertNil(store.findBugGame(for: "same-id"))
        XCTAssertEqual(store.setup(for: game, owner: original)?.session?.id, "same-id")
        XCTAssertEqual(fake.calls, ["projects", "resolve", "create"])
        active = original
        XCTAssertNotNil(store.findBugGame(for: "same-id"))
    }

    func testCanonicalSetupAndAnswerRestoreGamesAcrossServerAndProfileNamespaces() {
        let store = FunAndGamesStore()
        var active = owner
        store.ownerProvider = { active }
        let setup = OpenCodeMessageEnvelope.local(role: "user", text: FindPlaceGame.starterPrompt(city: city, weather: weather),
            messageID: "setup", sessionID: "same-id")
        let answer = OpenCodeMessageEnvelope.local(role: "assistant", text: FindPlaceGame.winMarker,
            messageID: "answer", sessionID: "same-id")
        XCTAssertTrue(store.inferGames(from: [setup, answer], forSessionID: "same-id"))
        XCTAssertEqual(store.findPlaceGame(for: "same-id")?.city, city)
        XCTAssertEqual(store.findPlaceGame(for: "same-id")?.didReveal, true)
        active = .init(backendID: owner.backendID, profile: .legacy)
        XCTAssertNil(store.findPlaceGame(for: "same-id"))
        let language = FindBugGame.supportedLanguages[0]
        let bug = OpenCodeMessageEnvelope.local(role: "user", text: FindBugGame.starterPrompt(language: language),
            messageID: "legacy-setup", sessionID: "same-id")
        XCTAssertTrue(store.inferGames(from: [bug], forSessionID: "same-id"))
        XCTAssertEqual(store.findBugGame(for: "same-id")?.language, language)
        active = .init(backendID: "different-server", profile: .v2)
        XCTAssertNil(store.findBugGame(for: "same-id"))
        XCTAssertNil(store.findPlaceGame(for: "same-id"))
        active = owner
        XCTAssertEqual(store.findPlaceGame(for: "same-id")?.didReveal, true)
        XCTAssertNil(store.findBugGame(for: "same-id"))
        let fresh = FunAndGamesStore()
        XCTAssertTrue(fresh.inferGames(from: [bug, .local(role: "assistant", text: FindBugGame.winMarker,
            messageID: "solved", sessionID: "same-id")], forSessionID: "same-id"))
        XCTAssertEqual(fresh.findBugGame(for: "same-id")?.language, language)
    }

    func testLegacySystemSetupMetadataStillRestoresWithoutMigrationOrWeatherAccess() {
        let place = OpenCodeMessageEnvelope.local(role: "system", text: """
            \(FindPlaceGame.setupMarker)
            Secret city: Paris, France
            Coordinates: 48.8566, 2.3522
            Current clue: Cloudy
            WeatherKit diagnostic: success
            """, messageID: "legacy-place", sessionID: "place")
        let bug = OpenCodeMessageEnvelope.local(role: "system", text: """
            \(FindBugGame.setupMarker)
            Markdown fence language: swift
            """, messageID: "legacy-bug", sessionID: "bug")
        let store = FunAndGamesStore()
        XCTAssertTrue(store.inferGames(from: [place], forSessionID: "place"))
        XCTAssertTrue(store.inferGames(from: [bug], forSessionID: "bug"))
        XCTAssertEqual(store.findPlaceGame(for: "place")?.city, city)
        XCTAssertEqual(store.findBugGame(for: "bug")?.language.id, "swift")
    }

    func testCanonicalAdmissionEvidenceCannotBeDowngradedByLateUncertainReceipt() async throws {
        let fake = GameBackend()
        fake.admission = .uncertain
        let store = FunAndGamesStore()
        store.ownerProvider = { self.owner }
        let coordinator = FunAndGamesCoordinator(store: store)
        let game = FunAndGamesGame.findBug(FindBugGame.supportedLanguages[0])
        _ = try await coordinator.start(game: game, model: model, owner: owner, connection: fake.connection(), isCurrent: { true })
        let checkpoint = try XCTUnwrap(store.setup(for: game, owner: owner))
        let message = OpenCodeMessageEnvelope.local(role: "user", text: checkpoint.prompt,
            messageID: checkpoint.messageID, sessionID: "same-id")
        XCTAssertTrue(store.inferGames(from: [message], forSessionID: "same-id"))
        store.saveSetup(checkpoint, owner: owner)
        XCTAssertEqual(store.setupPhase(for: "same-id"), .admitted)
        XCTAssertFalse(store.hasPendingSetup(for: "same-id"))
    }

    func testTitlesAndAssistantEchoesAloneDoNotRestoreAGame() {
        let store = FunAndGamesStore()
        let title = OpenCodeMessageEnvelope.local(role: "user", text: "Find the Place", messageID: "title", sessionID: "same-id")
        let echo = OpenCodeMessageEnvelope.local(role: "assistant", text: FindPlaceGame.starterPrompt(city: city, weather: weather),
            messageID: "echo", sessionID: "same-id")
        XCTAssertFalse(store.inferGames(from: [title, echo], forSessionID: "same-id"))
        XCTAssertNil(store.findPlaceGame(for: "same-id"))
        XCTAssertNil(store.findBugGame(for: "same-id"))
    }
}

@MainActor
private final class GameBackend: BackendProjectsService, BackendSessionsService, BackendChatService,
    BackendModelsService, BackendEventSource, BackendSessionSelectionService, BackendPendingInputReading, BackendProjectLifecycleService {
    enum Admission { case accepted, rejected, uncertain }
    var calls: [String] = []
    var creations: [BackendSessionCreation] = []
    var submissions: [BackendSubmission] = []
    var defaultDirectory: String? = "/server/default"
    var admission = Admission.accepted
    var createdSessionID = "same-id"
    var failCreate = false
    var failSelection = false
    var failSubmit = false
    var onCreate: (() -> Void)?
    var beforeCreate: (() async -> Void)?
    var pending: Set<String> = []
    var messages: [OpenCodeMessageEnvelope] = []
    private var project: OpenCodeProject {
        .init(id: "server-project", worktree: "/server/default", vcs: nil, name: nil, sandboxes: nil, icon: nil, time: nil)
    }

    func connection(selection: Bool = true, resolution: Bool = true) -> BackendConnection {
        .init(descriptor: .init(id: "games", name: "Mock", version: "test"), projects: self, sessions: self,
            chat: self, models: self, events: self, projectLifecycle: resolution ? self : nil,
            sessionSelection: selection ? self : nil)
    }
    func projectsSnapshot() async throws -> BackendProjectsSnapshot {
        calls.append("projects")
        return .init(projects: [project], currentProject: project, defaultDirectory: defaultDirectory)
    }
    func resolveProject(directory: String) async throws -> BackendProjectResolution {
        calls.append("resolve")
        XCTAssertEqual(directory, "/server/default")
        return .init(project: project, scope: .init(projectID: project.id, directory: directory), canonicalDirectory: directory)
    }
    func createSession(_ request: BackendSessionCreation) async throws -> OpenCodeSession {
        calls.append("create")
        creations.append(request)
        await beforeCreate?()
        onCreate?()
        if failCreate { throw URLError(.networkConnectionLost) }
        return .init(id: createdSessionID, title: request.title, workspaceID: request.scope.workspaceID,
            directory: request.scope.directory, projectID: "server-project", parentID: nil)
    }
    func setModel(sessionID: String, model: OpenCodeModelReference, variant: String?, scope: BackendScope) async throws {
        calls.append("model")
        if failSelection { throw URLError(.networkConnectionLost) }
    }
    func setAgent(sessionID: String, agent: String, scope: BackendScope) async throws {
        calls.append("agent")
        XCTAssertEqual(agent, "plan")
    }
    func submit(_ request: BackendSubmission) async throws -> BackendAdmission {
        calls.append("submit")
        submissions.append(request)
        if failSubmit { throw URLError(.networkConnectionLost) }
        switch admission {
        case .accepted: return .accepted(sessionID: request.sessionID, messageID: request.messageID)
        case .rejected: return .rejected(sessionID: request.sessionID, messageID: request.messageID)
        case .uncertain: return .uncertain(sessionID: request.sessionID, messageID: request.messageID)
        }
    }
    func transcript(sessionID: String, scope: BackendScope, cursor: String?, limit: Int) async throws -> BackendTranscriptPage {
        calls.append("transcript")
        return .init(messages: messages)
    }
    func pendingInputIDs(sessionID: String, scope: BackendScope) async throws -> Set<String> {
        calls.append("pending")
        return pending
    }
    func modelCatalog(scope: BackendScope) async throws -> BackendModelCatalog {
        XCTFail("Game start must not fetch providers")
        throw URLError(.unsupportedURL)
    }
    func sessions(scope: BackendScope, cursor: String?, limit: Int, roots: Bool) async throws -> BackendSessionPage {
        XCTFail("No broad session reload")
        throw URLError(.unsupportedURL)
    }
    func session(id: String, scope: BackendScope) async throws -> OpenCodeSession { throw URLError(.unsupportedURL) }
    func renameSession(id: String, title: String, scope: BackendScope) async throws -> OpenCodeSession { throw URLError(.unsupportedURL) }
    func deleteSession(id: String, scope: BackendScope) async throws { XCTFail("No delete") }
    func searchSessions(query: String, scope: BackendScope, limit: Int) async throws -> [OpenCodeSession] { throw URLError(.unsupportedURL) }
    func interrupt(sessionID: String, scope: BackendScope) async throws { XCTFail("No interrupt") }
    func searchDirectories(query: String, root: String) async throws -> BackendDirectorySearch { throw URLError(.unsupportedURL) }
    func start(receive: @escaping @MainActor (BackendEvent) -> Void) { XCTFail("No second event owner") }
    func stop() {}
}
