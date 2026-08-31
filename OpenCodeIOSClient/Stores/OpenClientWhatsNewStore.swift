import Combine
import Foundation

struct OpenClientReleaseNotes: Identifiable, Equatable {
    enum Hero: Equatable {
        case customization
        case activity
        case internationalization
        case ipad
        case talk
    }

    struct Feature: Identifiable, Equatable {
        let title: String
        let detail: String
        let systemImage: String

        var id: String { systemImage }

        init(title: LocalizedStringResource, detail: LocalizedStringResource, systemImage: String) {
            self.title = String(localized: title)
            self.detail = String(localized: detail)
            self.systemImage = systemImage
        }
    }

    struct InternationalizationAnnouncement: Identifiable, Equatable {
        struct Contributor: Equatable {
            let name: String
            let handle: String
        }

        struct PaletteColor: Equatable {
            let red: Double
            let green: Double
            let blue: Double
        }

        let localeIdentifier: String
        let nativeGreeting: String
        let nativeName: String
        let detail: String
        let palette: [PaletteColor]
        let contributor: Contributor?

        var id: String { localeIdentifier }

        init(
            localeIdentifier: String,
            nativeGreeting: String,
            nativeName: String,
            detail: LocalizedStringResource,
            palette: [PaletteColor],
            contributor: Contributor? = nil
        ) {
            self.localeIdentifier = localeIdentifier
            self.nativeGreeting = nativeGreeting
            self.nativeName = nativeName
            self.detail = String(localized: detail)
            self.palette = palette
            self.contributor = contributor
        }
    }

    let version: String
    let title: String
    let summary: String
    let features: [Feature]
    let hero: Hero
    let featureSectionTitle: String
    let showsSetup: Bool
    let internationalizationAnnouncements: [InternationalizationAnnouncement]

    var id: String { version }

    init(
        version: String,
        title: LocalizedStringResource,
        summary: LocalizedStringResource,
        features: [Feature],
        hero: Hero = .customization,
        featureSectionTitle: LocalizedStringResource = "Small changes, right where they count",
        showsSetup: Bool = true,
        internationalizationAnnouncements: [InternationalizationAnnouncement] = []
    ) {
        self.version = version
        self.title = String(localized: title)
        self.summary = String(localized: summary)
        self.features = features
        self.hero = hero
        self.featureSectionTitle = String(localized: featureSectionTitle)
        self.showsSetup = showsSetup
        self.internationalizationAnnouncements = internationalizationAnnouncements
    }
}

enum OpenClientReleaseNotesCatalog {
    static let releases = [
        OpenClientReleaseNotes(
            version: "1.0.15",
            title: "Make it yours",
            summary: "A tidier workspace, richer conversations, fresh app icons, and a smoother return to your projects.",
            features: [
                OpenClientReleaseNotes.Feature(
                    title: "Rich link previews",
                    detail: "Shared links now expand into rich, tappable previews after a message finishes streaming.",
                    systemImage: "link"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Projects, your way",
                    detail: "Use Manage Projects to drag workspaces into order or hide the ones you do not need.",
                    systemImage: "line.3.horizontal"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Make it yours",
                    detail: "Choose a new icon and decide whether chat activity gets a subtle shimmer.",
                    systemImage: "paintpalette.fill"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Connect on launch",
                    detail: "Choose a trusted saved server and OpenClient can reconnect when you open the app.",
                    systemImage: "bolt.horizontal.circle.fill"
                ),
            ]
        ),
        OpenClientReleaseNotes(
            version: "1.0.16",
            title: "Activity, at a glance",
            summary: "A calm command center for every chat that is working, waiting, or ready for your next move.",
            features: [
                OpenClientReleaseNotes.Feature(
                    title: "One view across projects",
                    detail: "Open Activity from Projects to follow working sessions, requests that need input, and recent conversations together.",
                    systemImage: "waveform.path.ecg"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "The latest context, live",
                    detail: "See the newest exchange, active tool, todo progress, and Live Activity status without opening every chat.",
                    systemImage: "bolt.horizontal.circle.fill"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Cards that fit your flow",
                    detail: "Choose Compact, Default, or Activity cards for each project’s session list, with optional last-user-message context.",
                    systemImage: "rectangle.3.group.fill"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Start from anywhere",
                    detail: "The floating New Chat button starts an unscoped conversation and lets you choose its project when you are ready.",
                    systemImage: "square.and.pencil"
                ),
            ],
            hero: .activity,
            featureSectionTitle: "Every conversation, in motion",
            showsSetup: false
        ),
        OpenClientReleaseNotes(
            version: "1.0.17",
            title: "Hello, world",
            summary: "OpenClient now speaks Brazilian Portuguese and Italian, throughout the app and beyond.",
            features: [],
            hero: .internationalization,
            showsSetup: false,
            internationalizationAnnouncements: [
                OpenClientReleaseNotes.InternationalizationAnnouncement(
                    localeIdentifier: "pt-BR",
                    nativeGreeting: "Olá!",
                    nativeName: "Português (Brasil)",
                    detail: "OpenClient is now available in Brazilian Portuguese across the app and its extensions.",
                    palette: [
                        .init(red: 0.00, green: 0.45, blue: 0.25),
                        .init(red: 0.98, green: 0.76, blue: 0.04),
                        .init(red: 0.03, green: 0.26, blue: 0.64),
                    ]
                ),
                OpenClientReleaseNotes.InternationalizationAnnouncement(
                    localeIdentifier: "it",
                    nativeGreeting: "Ciao!",
                    nativeName: "Italiano",
                    detail: "OpenClient is now available in Italian across the app and its extensions.",
                    palette: [
                        .init(red: 0.00, green: 0.55, blue: 0.31),
                        .init(red: 0.94, green: 0.94, blue: 0.90),
                        .init(red: 0.82, green: 0.10, blue: 0.17),
                    ],
                    contributor: .init(name: "Lorenzo Salami", handle: "@LSalami")
                ),
            ]
        ),
        OpenClientReleaseNotes(
            version: "1.0.18",
            title: "A bigger canvas",
            summary: "A focused iPad experience with more room to read, browse, and move between conversations.",
            features: [
                OpenClientReleaseNotes.Feature(
                    title: "Comfortable reading width",
                    detail: "Chats stay centered in a narrower column, making long conversations easier to scan on a large display.",
                    systemImage: "text.alignleft"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Open chats in new windows",
                    detail: "Move a conversation into its own iPad window and keep multiple sessions close at hand.",
                    systemImage: "macwindow.on.rectangle"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Browse beside your chat",
                    detail: "Keep the in-app browser and your conversation visible together, with a layout that adapts between portrait and landscape.",
                    systemImage: "rectangle.split.2x1"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Activity, simplified",
                    detail: "Working and recent sessions keep their context, while older conversations use compact cards that are easier to scan.",
                    systemImage: "waveform.path.ecg"
                ),
            ],
            hero: .ipad,
            featureSectionTitle: "More room for the work that matters",
            showsSetup: false
        ),
        OpenClientReleaseNotes(
            version: "1.0.19",
            title: "Talk it through",
            summary: "Speak naturally with OpenClient, hear answers sooner, and keep the conversation going from the Lock Screen.",
            features: [
                OpenClientReleaseNotes.Feature(
                    title: "Meet Talk mode",
                    detail: "Start a voice conversation from Projects, Activity, session lists, or any chat, with automatic and hold-to-talk controls.",
                    systemImage: "waveform"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Answers without the wait",
                    detail: "OpenClient speaks each completed answer while longer work continues, with Talk visible on the Lock Screen and Dynamic Island.",
                    systemImage: "waveform.badge.mic"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Todos on your terms",
                    detail: "Minimize the todo list when you want more room, then bring it back with one tap.",
                    systemImage: "checklist"
                ),
                OpenClientReleaseNotes.Feature(
                    title: "Activity, refined",
                    detail: "Search across sessions, projects, messages, statuses, and running tools with cleaner controls.",
                    systemImage: "magnifyingglass"
                ),
            ],
            hero: .talk,
            featureSectionTitle: "More natural, less in the way",
            showsSetup: false
        ),
    ]
}

enum OpenClientLocalizationContribution {
    static let prompt = String(localized: """
    Help me contribute a [YOUR LANGUAGE] translation to OpenClient.

    Clone https://github.com/ntoporcov/openclient and read AGENTS.md, LOCALIZATION.md, and any instructions relevant to the files you edit. Create a dedicated translation branch.

    Translate every shipping String Catalog entry from English into [YOUR LANGUAGE] across the main app, App Shortcuts, Info.plist copy, the Live Activity extension, and the Share extension. Add the locale to REQUIRED_LANGUAGES in scripts/lint-localizations.rb and to CFBundleLocalizations for every target in project.yml. Use the existing Brazilian Portuguese and Italian localizations as structural examples. Preserve placeholders, format specifiers, URLs, commands, code, and product names exactly, and review translations in their UI context.

    Regenerate the Xcode project as documented. Run ruby scripts/lint-localizations.rb and the full localization and build checks, then fix every failure. Commit the changes, push the branch, and open a pull request against main that names the language, summarizes the coverage, and lists the validation performed. Do not overwrite unrelated changes, and ask me before making an ambiguous terminology choice.
    """)
}

enum OpenClientPluginSetup {
    static let packageName = "@openclient-ios/opencode-plugin@0.2.0"

    static let prompt = """
    Install @openclient-ios/opencode-plugin@0.2.0 in my global OpenCode configuration at ~/.config/opencode/opencode.json.

    First inspect the existing configuration. Add the package to the existing "plugin" array without removing other plugins or settings. Preserve valid JSON and the existing schema entry.

    After making the change, explain what changed and remind me to restart OpenCode. Ask before editing if the configuration location is ambiguous.
    """
}

@MainActor
final class OpenClientWhatsNewStore: ObservableObject {
    @Published private(set) var presentedRelease: OpenClientReleaseNotes?

    private static let lastOpenedVersionKey = "whatsNew.lastOpenedVersion"
    private static let lastPresentedReleaseKey = "whatsNew.lastPresentedRelease"

    private let defaults: UserDefaults
    private let currentVersion: String
    private let releases: [OpenClientReleaseNotes]

    init(
        defaults: UserDefaults = .standard,
        currentVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "",
        releases: [OpenClientReleaseNotes] = OpenClientReleaseNotesCatalog.releases,
        hasExistingConnection: Bool = false,
        checksForUpdates: Bool = true
    ) {
        self.defaults = defaults
        self.currentVersion = currentVersion
        self.releases = releases

        if checksForUpdates {
            checkForUpdate(hasExistingConnection: hasExistingConnection)
        }
    }

    var hasCurrentRelease: Bool {
        release(for: currentVersion) != nil
    }

    func dismiss() {
        presentedRelease = nil
    }

    func presentLatestRelease() {
        presentedRelease = release(for: currentVersion) ?? releases.last
    }

    private func checkForUpdate(hasExistingConnection: Bool) {
        guard !currentVersion.isEmpty else { return }

        let previousVersion = defaults.string(forKey: Self.lastOpenedVersionKey)
        defaults.set(currentVersion, forKey: Self.lastOpenedVersionKey)

        guard let release = release(for: currentVersion) else { return }

        if previousVersion == nil, !hasExistingConnection {
            defaults.set(release.id, forKey: Self.lastPresentedReleaseKey)
            return
        }

        let isEligibleUpdate = if let previousVersion {
            previousVersion.compare(currentVersion, options: .numeric) != .orderedDescending
        } else {
            hasExistingConnection
        }

        guard isEligibleUpdate,
              defaults.string(forKey: Self.lastPresentedReleaseKey) != release.id else { return }

        // Consume before presentation so an interrupted launch cannot show the same release twice.
        defaults.set(release.id, forKey: Self.lastPresentedReleaseKey)
        presentedRelease = release
    }

    private func release(for version: String) -> OpenClientReleaseNotes? {
        releases.first { $0.version == version }
    }
}
