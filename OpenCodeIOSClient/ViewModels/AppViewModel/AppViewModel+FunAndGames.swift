import Foundation
import SwiftUI

extension AppViewModel {
    func presentFindPlaceModelSheet() {
        withAnimation(opencodeSelectionAnimation) {
            isShowingFindPlaceModelSheet = true
        }
    }

    func presentFindBugLanguageSheet() {
        pendingFindBugLanguage = nil
        withAnimation(opencodeSelectionAnimation) {
            isShowingFindBugLanguageSheet = true
        }
    }

    func selectFindBugLanguage(_ language: FindBugGameLanguage) {
        pendingFindBugLanguage = language
        withAnimation(opencodeSelectionAnimation) {
            isShowingFindBugLanguageSheet = false
            isShowingFindBugModelSheet = true
        }
    }

    func startFindPlaceGame(model reference: OpenCodeModelReference) async {
        isLoading = true
        defer { isLoading = false }

        let globalProject = projects.first(where: { $0.id == "global" }) ?? OpenCodeProject(
            id: "global",
            worktree: "",
            vcs: nil,
            name: "Global",
            sandboxes: nil,
            icon: nil,
            time: nil
        )

        do {
            withAnimation(opencodeSelectionAnimation) {
                currentProject = globalProject
                isShowingFindPlaceModelSheet = false
            }
            prepareDirectorySelection(nil)
            try await reloadSessions()
            await loadComposerOptions()

            let city = FindPlaceGame.randomCity()
            let weather = await FindPlaceWeatherProvider.summary(for: city)
            if let weatherError = weather.errorDescription {
                appendDebugLog("find-place WeatherKit fallback city=\(city.id) error=\(weatherError)")
            } else {
                appendDebugLog("find-place WeatherKit success city=\(city.id)")
            }
            let session = try await client.createSession(title: "Find the Place", directory: nil)
            upsertVisibleSession(session)
            try await reloadSessions()
            upsertVisibleSession(session)

            selectedModelsBySessionID[session.id] = reference
            findPlaceSessionsByID[session.id] = FindPlaceGameSession(sessionID: session.id, city: city)
            withAnimation(opencodeSelectionAnimation) {
                selectedProjectContentTab = .sessions
                selectedSession = session
                isLoadingSelectedSession = true
                messages = []
                sessionInteractionStore.replaceTodos([])
            }
            restoreMessageDraft(for: session)
            streamDirectory = session.directory
            try await loadMessages(for: session)
            await sendMessage(
                FindPlaceGame.starterPrompt(city: city, weather: weather),
                in: session,
                userVisible: false,
                appendOptimisticMessage: false,
                meterPrompt: false
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func startFindBugGame(model reference: OpenCodeModelReference) async {
        guard let language = pendingFindBugLanguage else { return }

        isLoading = true
        defer { isLoading = false }

        let globalProject = projects.first(where: { $0.id == "global" }) ?? OpenCodeProject(
            id: "global",
            worktree: "",
            vcs: nil,
            name: "Global",
            sandboxes: nil,
            icon: nil,
            time: nil
        )

        do {
            withAnimation(opencodeSelectionAnimation) {
                currentProject = globalProject
                isShowingFindBugModelSheet = false
            }
            prepareDirectorySelection(nil)
            try await reloadSessions()
            await loadComposerOptions()

            let session = try await client.createSession(title: "Find the Bug", directory: nil)
            upsertVisibleSession(session)
            try await reloadSessions()
            upsertVisibleSession(session)

            selectedModelsBySessionID[session.id] = reference
            findBugSessionsByID[session.id] = FindBugGameSession(sessionID: session.id, language: language)
            pendingFindBugLanguage = nil
            withAnimation(opencodeSelectionAnimation) {
                selectedProjectContentTab = .sessions
                selectedSession = session
                isLoadingSelectedSession = true
                messages = []
                sessionInteractionStore.replaceTodos([])
            }
            restoreMessageDraft(for: session)
            streamDirectory = session.directory
            try await loadMessages(for: session)
            await sendMessage(
                FindBugGame.starterPrompt(language: language),
                in: session,
                userVisible: false,
                appendOptimisticMessage: false,
                meterPrompt: false
            )
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func findPlaceGame(for sessionID: String) -> FindPlaceGameSession? {
        if let game = findPlaceSessionsByID[sessionID] {
            return game
        }

        return inferredFindPlaceGame(for: sessionID)
    }

    func findBugGame(for sessionID: String) -> FindBugGameSession? {
        if let game = findBugSessionsByID[sessionID] {
            return game
        }

        return inferredFindBugGame(for: sessionID)
    }

    func isFunAndGamesSession(_ sessionID: String) -> Bool {
        findPlaceGame(for: sessionID) != nil || findBugGame(for: sessionID) != nil
    }

    func shouldMeterPrompts(for sessionID: String) -> Bool {
        !isFunAndGamesSession(sessionID)
    }

    private func inferredFindPlaceGame(for sessionID: String) -> FindPlaceGameSession? {
        for message in messages where message.info.sessionID == sessionID || selectedSession?.id == sessionID {
            for part in message.parts {
                guard let text = part.text, text.contains(FindPlaceGame.setupMarker) else { continue }
                guard let city = findPlaceCity(fromSetupPrompt: text) else { continue }
                return FindPlaceGameSession(sessionID: sessionID, city: city)
            }
        }

        return nil
    }

    private func inferredFindBugGame(for sessionID: String) -> FindBugGameSession? {
        for message in messages where message.info.sessionID == sessionID || selectedSession?.id == sessionID {
            for part in message.parts {
                guard let text = part.text, text.contains(FindBugGame.setupMarker) else { continue }
                guard let language = findBugLanguage(fromSetupPrompt: text) else { continue }
                return FindBugGameSession(sessionID: sessionID, language: language)
            }
        }

        return nil
    }

    private func findBugLanguage(fromSetupPrompt text: String) -> FindBugGameLanguage? {
        let lines = text.components(separatedBy: .newlines)
        guard let languageLine = lines.first(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Markdown fence language:") }) else {
            return nil
        }
        let id = languageLine
            .replacingOccurrences(of: "Markdown fence language:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return FindBugGame.supportedLanguages.first { $0.id == id } ?? FindBugGameLanguage(id: id, title: id.capitalized)
    }

    private func findPlaceCity(fromSetupPrompt text: String) -> FindPlaceGameCity? {
        let lines = text.components(separatedBy: .newlines)
        let cityLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Secret city:") }
        let coordinatesLine = lines.first { $0.trimmingCharacters(in: .whitespaces).hasPrefix("Coordinates:") }

        guard let cityLine, let coordinatesLine else { return nil }

        let cityValue = cityLine
            .replacingOccurrences(of: "Secret city:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let cityParts = cityValue.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard cityParts.count == 2 else { return nil }

        let coordinateValue = coordinatesLine
            .replacingOccurrences(of: "Coordinates:", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let coordinateParts = coordinateValue.split(separator: ",", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard coordinateParts.count == 2,
              let latitude = Double(coordinateParts[0]),
              let longitude = Double(coordinateParts[1]) else {
            return nil
        }

        return FindPlaceGameCity(name: cityParts[0], country: cityParts[1], latitude: latitude, longitude: longitude)
    }
}
