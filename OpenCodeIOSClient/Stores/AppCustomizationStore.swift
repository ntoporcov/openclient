import Combine
import Foundation

enum SessionCardStyle: String, Codable, CaseIterable, Identifiable {
    case compact
    case simple
    case activity

    var id: Self { self }
    var title: String {
        switch self {
        case .compact: String(localized: "Compact")
        case .simple: String(localized: "Default")
        case .activity: String(localized: "Activity")
        }
    }

    static var allCases: [SessionCardStyle] { [.compact, .simple, .activity] }
}

enum AutoConnectLandingDestination: String, Codable, CaseIterable, Identifiable {
    case projects
    case activity

    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .projects: "Projects"
        case .activity: "Activity"
        }
    }
}

enum ComposerStyle: String, Codable, CaseIterable, Identifiable {
    case messenger
    case assistant

    var id: Self { self }
    var title: LocalizedStringResource {
        switch self {
        case .messenger: "Messenger"
        case .assistant: "Assistant"
        }
    }
}

struct AppCustomizationPreferences: Codable, Equatable {
    var showsChatActivityShimmer: Bool
    var showsToolCalls: Bool
    var showsReasoningBlocks: Bool
    var showsActivityLastUserMessage: Bool
    var isTodoStripMinimized: Bool
    var sessionCardStyle: SessionCardStyle
    var composerStyle: ComposerStyle
    var autoConnectServerID: String?
    var autoConnectLandingDestination: AutoConnectLandingDestination

    init(
        showsChatActivityShimmer: Bool = true,
        showsToolCalls: Bool = true,
        showsReasoningBlocks: Bool = true,
        showsActivityLastUserMessage: Bool = true,
        isTodoStripMinimized: Bool = false,
        sessionCardStyle: SessionCardStyle = .simple,
        composerStyle: ComposerStyle = .messenger,
        autoConnectServerID: String? = nil,
        autoConnectLandingDestination: AutoConnectLandingDestination = .projects
    ) {
        self.showsChatActivityShimmer = showsChatActivityShimmer
        self.showsToolCalls = showsToolCalls
        self.showsReasoningBlocks = showsReasoningBlocks
        self.showsActivityLastUserMessage = showsActivityLastUserMessage
        self.isTodoStripMinimized = isTodoStripMinimized
        self.sessionCardStyle = sessionCardStyle
        self.composerStyle = composerStyle
        self.autoConnectServerID = autoConnectServerID
        self.autoConnectLandingDestination = autoConnectLandingDestination
    }

    private enum CodingKeys: String, CodingKey {
        case showsChatActivityShimmer
        case showsToolCalls
        case showsReasoningBlocks
        case showsActivityLastUserMessage
        case isTodoStripMinimized
        case sessionCardStyle
        case composerStyle
        case autoConnectServerID
        case autoConnectLandingDestination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showsChatActivityShimmer = try container.decodeIfPresent(Bool.self, forKey: .showsChatActivityShimmer) ?? true
        showsToolCalls = try container.decodeIfPresent(Bool.self, forKey: .showsToolCalls) ?? true
        showsReasoningBlocks = try container.decodeIfPresent(Bool.self, forKey: .showsReasoningBlocks) ?? true
        showsActivityLastUserMessage = try container.decodeIfPresent(Bool.self, forKey: .showsActivityLastUserMessage) ?? true
        isTodoStripMinimized = try container.decodeIfPresent(Bool.self, forKey: .isTodoStripMinimized) ?? false
        sessionCardStyle = try container.decodeIfPresent(String.self, forKey: .sessionCardStyle)
            .flatMap(SessionCardStyle.init(rawValue:)) ?? .simple
        composerStyle = try container.decodeIfPresent(String.self, forKey: .composerStyle)
            .flatMap(ComposerStyle.init(rawValue:)) ?? .messenger
        autoConnectServerID = try container.decodeIfPresent(String.self, forKey: .autoConnectServerID)
        autoConnectLandingDestination = try container.decodeIfPresent(String.self, forKey: .autoConnectLandingDestination)
            .flatMap(AutoConnectLandingDestination.init(rawValue:)) ?? .projects
    }
}

@MainActor
final class AppCustomizationStore: ObservableObject {
    @Published private(set) var preferences: AppCustomizationPreferences

    private let defaults: UserDefaults
    private let storageKey: String

    init(
        defaults: UserDefaults = .standard,
        storageKey: String = "appCustomizationPreferences"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
        if let data = defaults.data(forKey: storageKey),
           let preferences = try? JSONDecoder().decode(AppCustomizationPreferences.self, from: data) {
            self.preferences = preferences
        } else {
            preferences = AppCustomizationPreferences()
        }
    }

    var showsChatActivityShimmer: Bool {
        preferences.showsChatActivityShimmer
    }

    var showsToolCalls: Bool {
        preferences.showsToolCalls
    }

    var showsReasoningBlocks: Bool {
        preferences.showsReasoningBlocks
    }

    var autoConnectServerID: String? {
        preferences.autoConnectServerID
    }

    var autoConnectLandingDestination: AutoConnectLandingDestination {
        preferences.autoConnectLandingDestination
    }

    var showsActivityLastUserMessage: Bool {
        preferences.showsActivityLastUserMessage
    }

    var isTodoStripMinimized: Bool {
        preferences.isTodoStripMinimized
    }

    var sessionCardStyle: SessionCardStyle {
        preferences.sessionCardStyle
    }

    var composerStyle: ComposerStyle {
        preferences.composerStyle
    }

    func setShowsChatActivityShimmer(_ shows: Bool) {
        guard preferences.showsChatActivityShimmer != shows else { return }
        preferences.showsChatActivityShimmer = shows
        persist()
    }

    func setShowsToolCalls(_ shows: Bool) {
        guard preferences.showsToolCalls != shows else { return }
        preferences.showsToolCalls = shows
        persist()
    }

    func setShowsReasoningBlocks(_ shows: Bool) {
        guard preferences.showsReasoningBlocks != shows else { return }
        preferences.showsReasoningBlocks = shows
        persist()
    }

    func setShowsActivityLastUserMessage(_ shows: Bool) {
        guard preferences.showsActivityLastUserMessage != shows else { return }
        preferences.showsActivityLastUserMessage = shows
        persist()
    }

    func setTodoStripMinimized(_ isMinimized: Bool) {
        guard preferences.isTodoStripMinimized != isMinimized else { return }
        preferences.isTodoStripMinimized = isMinimized
        persist()
    }

    func setSessionCardStyle(_ style: SessionCardStyle) {
        guard preferences.sessionCardStyle != style else { return }
        preferences.sessionCardStyle = style
        persist()
    }

    func setComposerStyle(_ style: ComposerStyle) {
        guard preferences.composerStyle != style else { return }
        preferences.composerStyle = style
        persist()
    }

#if DEBUG
    func setComposerStyleForFixture(_ style: ComposerStyle) {
        preferences.composerStyle = style
    }
#endif

    func setAutoConnectServerID(_ serverID: String?) {
        guard preferences.autoConnectServerID != serverID else { return }
        preferences.autoConnectServerID = serverID
        persist()
    }

    func setAutoConnectLandingDestination(_ destination: AutoConnectLandingDestination) {
        guard preferences.autoConnectLandingDestination != destination else { return }
        preferences.autoConnectLandingDestination = destination
        persist()
    }

    func autoConnectServer(in servers: [OpenCodeServerConfig]) -> OpenCodeServerConfig? {
        guard let autoConnectServerID else { return nil }
        return servers.first { $0.recentServerID == autoConnectServerID }
    }

    func migrateAutoConnectServerID(from oldID: String, to newID: String) {
        guard autoConnectServerID == oldID else { return }
        setAutoConnectServerID(newID)
    }

    func reconcileAutoConnectServer(in servers: [OpenCodeServerConfig]) {
        guard let autoConnectServerID,
              !servers.contains(where: { $0.recentServerID == autoConnectServerID }) else { return }
        setAutoConnectServerID(nil)
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
