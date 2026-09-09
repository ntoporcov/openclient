import Combine
import Foundation

struct FunAndGamesOwner: Hashable {
    let backendID: String
    let profile: OpenCodeProfileIdentity
}

enum FunAndGamesGame: Equatable {
    case findPlace
    case findBug(FindBugGameLanguage)

    var key: String {
        switch self {
        case .findPlace: "place"
        case .findBug: "bug"
        }
    }
}

struct FunAndGamesSetup {
    enum Phase: Equatable {
        case preparing, creating, creationUncertain, created, configuring, submitting, uncertain, admitted, rejected, failed
    }

    let game: FunAndGamesGame
    let model: OpenCodeModelReference
    let messageID: String
    var phase: Phase = .preparing
    var scope = BackendScope()
    var project: OpenCodeProject?
    var session: OpenCodeSession?
    var prompt = ""
    var city: FindPlaceGameCity?
    var weather: FindPlaceWeatherSummary?
}

@MainActor
final class FunAndGamesStore: ObservableObject {
    @Published var preferences: FunAndGamesPreferences
    private struct Games {
        var places: [String: FindPlaceGameSession] = [:]
        var bugs: [String: FindBugGameSession] = [:]
        var language: FindBugGameLanguage?
        var setups: [String: FunAndGamesSetup] = [:]
        var setupsBySessionID: [String: FunAndGamesSetup] = [:]
        var running: Set<String> = []
    }
    @Published private var gamesByOwner: [FunAndGamesOwner: Games] = [:]
    // In-memory only. Existing persisted game preferences and transcript markers are unchanged.
    var ownerProvider: (@MainActor () -> FunAndGamesOwner)? {
        didSet {
            if oldValue == nil, ownerProvider != nil,
               let initial = gamesByOwner.removeValue(forKey: .init(backendID: "unbound", profile: .legacy)) {
                gamesByOwner[owner] = initial
            }
        }
    }
    private var owner: FunAndGamesOwner {
        ownerProvider?() ?? FunAndGamesOwner(backendID: "unbound", profile: .legacy)
    }
    var findPlaceSessionsByID: [String: FindPlaceGameSession] {
        get { gamesByOwner[owner]?.places ?? [:] }
        set { gamesByOwner[owner, default: Games()].places = newValue }
    }
    var findBugSessionsByID: [String: FindBugGameSession] {
        get { gamesByOwner[owner]?.bugs ?? [:] }
        set { gamesByOwner[owner, default: Games()].bugs = newValue }
    }
    var pendingFindBugLanguage: FindBugGameLanguage? {
        get { gamesByOwner[owner]?.language }
        set { gamesByOwner[owner, default: Games()].language = newValue }
    }

    func setup(for game: FunAndGamesGame, owner: FunAndGamesOwner) -> FunAndGamesSetup? {
        gamesByOwner[owner]?.setups[game.key]
    }

    func saveSetup(_ setup: FunAndGamesSetup, owner: FunAndGamesOwner) {
        var setup = setup
        let active = gamesByOwner[owner]?.setups[setup.game.key]
        let existing = setup.session.flatMap { gamesByOwner[owner]?.setupsBySessionID[$0.id] } ?? active
        if let existing,
           existing.messageID == setup.messageID, existing.phase == .admitted {
            setup.phase = .admitted
        }
        // Advancing creation must not retire an older session's admission guard. Late
        // evidence updates that session without replacing the active creation checkpoint.
        if active == nil || active?.messageID == setup.messageID || setup.phase == .preparing {
            gamesByOwner[owner, default: Games()].setups[setup.game.key] = setup
        }
        guard let session = setup.session else { return }
        gamesByOwner[owner, default: Games()].setupsBySessionID[session.id] = setup
        switch setup.game {
        case .findPlace:
            if let city = setup.city, gamesByOwner[owner]?.places[session.id] == nil {
                gamesByOwner[owner, default: Games()].places[session.id] = .init(sessionID: session.id, city: city, weather: setup.weather)
            }
        case .findBug(let language):
            gamesByOwner[owner, default: Games()].bugs[session.id] = .init(sessionID: session.id, language: language)
        }
    }

    func beginSetup(for game: FunAndGamesGame, owner: FunAndGamesOwner) -> Bool {
        gamesByOwner[owner, default: Games()].running.insert(game.key).inserted
    }

    func finishSetup(for game: FunAndGamesGame, owner: FunAndGamesOwner) {
        gamesByOwner[owner]?.running.remove(game.key)
    }

    func setupPhase(for sessionID: String) -> FunAndGamesSetup.Phase? {
        setup(for: sessionID)?.phase
    }

    func setup(for sessionID: String, owner: FunAndGamesOwner? = nil) -> FunAndGamesSetup? {
        gamesByOwner[owner ?? self.owner]?.setupsBySessionID[sessionID]
    }

    func hasPendingSetup(for sessionID: String) -> Bool {
        guard let phase = setupPhase(for: sessionID) else { return false }
        return phase != .admitted
    }

    init(
        preferences: FunAndGamesPreferences = FunAndGamesPreferences(),
        findPlaceSessionsByID: [String: FindPlaceGameSession] = [:],
        findBugSessionsByID: [String: FindBugGameSession] = [:],
        pendingFindBugLanguage: FindBugGameLanguage? = nil
    ) {
        self.preferences = preferences
        self.findPlaceSessionsByID = findPlaceSessionsByID
        self.findBugSessionsByID = findBugSessionsByID
        self.pendingFindBugLanguage = pendingFindBugLanguage
    }

    func findPlaceGame(for sessionID: String) -> FindPlaceGameSession? {
        findPlaceSessionsByID[sessionID]
    }

    func findBugGame(for sessionID: String) -> FindBugGameSession? {
        findBugSessionsByID[sessionID]
    }

    @discardableResult
    func recordFindPlaceSession(_ session: FindPlaceGameSession) -> Bool {
        guard findPlaceSessionsByID[session.sessionID] != session else { return false }
        var next = findPlaceSessionsByID
        next[session.sessionID] = session
        findPlaceSessionsByID = next
        return true
    }

    @discardableResult
    func recordFindBugSession(_ session: FindBugGameSession) -> Bool {
        guard findBugSessionsByID[session.sessionID] != session else { return false }
        var next = findBugSessionsByID
        next[session.sessionID] = session
        findBugSessionsByID = next
        return true
    }

    @discardableResult
    func inferGames(from messages: [OpenCodeMessageEnvelope], forSessionID sessionID: String) -> Bool {
        var changed = false

        if findPlaceSessionsByID[sessionID] == nil,
           let game = Self.inferredFindPlaceGame(in: messages, sessionID: sessionID) {
            changed = recordFindPlaceSession(game) || changed
        }

        if findBugSessionsByID[sessionID] == nil,
           let game = Self.inferredFindBugGame(in: messages, sessionID: sessionID) {
            changed = recordFindBugSession(game) || changed
        }

        if var setup = setup(for: sessionID), setup.phase != .admitted,
           messages.contains(where: { $0.id == setup.messageID && $0.info.role == "user" && $0.info.sessionID == sessionID }) {
            setup.phase = .admitted
            saveSetup(setup, owner: owner)
            changed = true
        }

        if var game = findPlaceSessionsByID[sessionID], !game.didReveal,
           messages.contains(where: { $0.info.role == "assistant" && $0.info.sessionID == sessionID && $0.parts.contains { $0.text?.contains(FindPlaceGame.winMarker) == true } }) {
            game.didReveal = true
            changed = recordFindPlaceSession(game) || changed
        }

        return changed
    }

    @discardableResult
    func inferGame(from part: OpenCodePart) -> Bool {
        guard part.type == "text", let sessionID = part.sessionID,
              let text = part.text else { return false }
        return inferGame(fromSetupText: text, sessionID: sessionID)
    }

    @discardableResult
    func inferGame(from event: OpenCodeTypedEvent) -> Bool {
        guard case let .messagePartUpdated(part) = event else { return false }
        return inferGame(from: part)
    }

    @discardableResult
    private func inferGame(fromSetupText text: String, sessionID: String) -> Bool {
        var changed = false

        if findPlaceSessionsByID[sessionID] == nil,
           text.contains(FindPlaceGame.setupMarker),
           let city = Self.findPlaceCity(fromSetupPrompt: text) {
            changed = recordFindPlaceSession(
                FindPlaceGameSession(
                    sessionID: sessionID,
                    city: city,
                    weather: Self.findPlaceWeather(fromSetupPrompt: text)
                )
            ) || changed
        }

        if findBugSessionsByID[sessionID] == nil,
           text.contains(FindBugGame.setupMarker),
           let language = Self.findBugLanguage(fromSetupPrompt: text) {
            changed = recordFindBugSession(FindBugGameSession(sessionID: sessionID, language: language)) || changed
        }

        return changed
    }

    static func inferredFindPlaceGame(in messages: [OpenCodeMessageEnvelope], sessionID: String) -> FindPlaceGameSession? {
        for message in messages where (message.info.role == "user" || message.info.role == "system") && (message.info.sessionID == nil || message.info.sessionID == sessionID) {
            for part in message.parts {
                guard let text = part.text, text.contains(FindPlaceGame.setupMarker) else { continue }
                guard let city = findPlaceCity(fromSetupPrompt: text) else { continue }
                let revealed = messages.contains { $0.info.role == "assistant" && $0.info.sessionID == sessionID && $0.parts.contains { $0.text?.contains(FindPlaceGame.winMarker) == true } }
                return FindPlaceGameSession(sessionID: sessionID, city: city, weather: findPlaceWeather(fromSetupPrompt: text), didReveal: revealed)
            }
        }

        return nil
    }

    static func inferredFindBugGame(in messages: [OpenCodeMessageEnvelope], sessionID: String) -> FindBugGameSession? {
        for message in messages where (message.info.role == "user" || message.info.role == "system") && (message.info.sessionID == nil || message.info.sessionID == sessionID) {
            for part in message.parts {
                guard let text = part.text, text.contains(FindBugGame.setupMarker) else { continue }
                guard let language = findBugLanguage(fromSetupPrompt: text) else { continue }
                return FindBugGameSession(sessionID: sessionID, language: language)
            }
        }

        return nil
    }

    private static func findBugLanguage(fromSetupPrompt text: String) -> FindBugGameLanguage? {
        let lines = text.components(separatedBy: .newlines)
        let languagePrefixes = [FindBugGame.languageIDPrefix, "Markdown fence language:"]
        guard let languageLine = lines.first(where: { line in
            languagePrefixes.contains { line.contains($0) }
        }), let prefix = languagePrefixes.first(where: { languageLine.contains($0) }) else {
            return nil
        }
        let id = languageLine
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .replacingOccurrences(of: prefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FindBugGame.supportedLanguages.first { $0.id == id } ?? FindBugGameLanguage(id: id, title: id.capitalized)
    }

    private static func findPlaceCity(fromSetupPrompt text: String) -> FindPlaceGameCity? {
        let lines = text.components(separatedBy: .newlines)
        let cityPrefixes = [FindPlaceGame.secretCityPrefix, "Secret city:"]
        let coordinatePrefixes = [FindPlaceGame.coordinatesPrefix, "Coordinates:"]
        let cityLine = lines.first { line in cityPrefixes.contains { line.contains($0) } }
        let coordinatesLine = lines.first { line in coordinatePrefixes.contains { line.contains($0) } }

        guard let cityLine, let coordinatesLine,
              let cityPrefix = cityPrefixes.first(where: { cityLine.contains($0) }),
              let coordinatePrefix = coordinatePrefixes.first(where: { coordinatesLine.contains($0) }) else { return nil }

        let cityValue = cityLine
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .replacingOccurrences(of: cityPrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cityParts = cityValue.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cityParts.count == 2 else { return nil }

        let coordinateValue = coordinatesLine
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .replacingOccurrences(of: coordinatePrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinateParts = coordinateValue.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard coordinateParts.count == 2,
              let latitude = Double(coordinateParts[0]),
              let longitude = Double(coordinateParts[1]) else {
            return nil
        }

        return FindPlaceGameCity(name: cityParts[0], country: cityParts[1], latitude: latitude, longitude: longitude)
    }

    private static func findPlaceWeather(fromSetupPrompt text: String) -> FindPlaceWeatherSummary? {
        let lines = text.components(separatedBy: .newlines)
        let cluePrefixes = [FindPlaceGame.cluePrefix, "Current clue:"]
        guard let clueLine = lines.first(where: { line in cluePrefixes.contains { line.contains($0) } }),
              let cluePrefix = cluePrefixes.first(where: { clueLine.contains($0) }) else {
            return nil
        }

        let clue = clueLine
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .replacingOccurrences(of: cluePrefix, with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let diagnosticPrefixes = [FindPlaceGame.weatherDiagnosticPrefix, "WeatherKit diagnostic:"]
        let diagnosticLine = lines.first { line in diagnosticPrefixes.contains { line.contains($0) } }
        let diagnosticPrefix = diagnosticLine.flatMap { line in diagnosticPrefixes.first { line.contains($0) } }
        let diagnostic = diagnosticLine?
            .replacingOccurrences(of: "<!--", with: "")
            .replacingOccurrences(of: "-->", with: "")
            .replacingOccurrences(of: diagnosticPrefix ?? "", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let errorDescription = diagnostic == "success" ? nil : diagnostic
        let provider = errorDescription == nil ? "WeatherKit" : "Fallback"
        return FindPlaceWeatherSummary(text: clue, provider: provider, errorDescription: errorDescription)
    }
}
