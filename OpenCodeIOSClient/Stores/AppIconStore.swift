import Combine
import Foundation

#if canImport(UIKit)
import UIKit
#endif

struct OpenClientAppIcon: Identifiable, Equatable {
    let alternateIconName: String?
    let displayName: String
    let iconFiles: [String]
    let requiresProLifetime: Bool

    init(
        alternateIconName: String?,
        displayName: String,
        iconFiles: [String],
        requiresProLifetime: Bool = false
    ) {
        self.alternateIconName = alternateIconName
        self.displayName = displayName
        self.iconFiles = iconFiles
        self.requiresProLifetime = requiresProLifetime
    }

    var id: String {
        alternateIconName ?? "__primary__"
    }
}

@MainActor
final class AppIconStore: ObservableObject {
    @Published private(set) var icons: [OpenClientAppIcon]
    @Published private(set) var selectedAlternateIconName: String?
    @Published private(set) var supportsAlternateIcons: Bool
    @Published private(set) var isChangingIcon = false
    @Published private(set) var errorMessage: String?

    init(infoDictionary: [String: Any] = Bundle.main.infoDictionary ?? [:]) {
        icons = Self.availableIcons(in: infoDictionary)
        selectedAlternateIconName = nil
        supportsAlternateIcons = false
        refresh()
    }

    var selectedIcon: OpenClientAppIcon {
        icons.first { $0.alternateIconName == selectedAlternateIconName }
            ?? icons[0]
    }

    func refresh() {
        #if canImport(UIKit)
        supportsAlternateIcons = UIApplication.shared.supportsAlternateIcons
        selectedAlternateIconName = UIApplication.shared.alternateIconName
        #else
        supportsAlternateIcons = false
        selectedAlternateIconName = nil
        #endif
    }

    func select(_ icon: OpenClientAppIcon, allowsProLifetimeIcons: Bool) async {
        guard icon.alternateIconName != selectedAlternateIconName else { return }
        guard !icon.requiresProLifetime || allowsProLifetimeIcons else {
            errorMessage = String(localized: "This app icon requires Pro Lifetime.")
            return
        }

        #if canImport(UIKit)
        guard supportsAlternateIcons else {
            errorMessage = String(localized: "Alternate app icons are unavailable in this build.")
            return
        }

        isChangingIcon = true
        errorMessage = nil
        defer { isChangingIcon = false }

        do {
            try await setAlternateIconName(icon.alternateIconName)
            selectedAlternateIconName = UIApplication.shared.alternateIconName
        } catch {
            errorMessage = error.localizedDescription
        }
        #else
        errorMessage = String(localized: "Alternate app icons are unavailable on this platform.")
        #endif
    }

    func enforceLifetimeEligibility(allowsProLifetimeIcons: Bool) async {
        refresh()
        guard !allowsProLifetimeIcons, selectedIcon.requiresProLifetime,
              let primaryIcon = icons.first(where: { $0.alternateIconName == nil }) else {
            return
        }
        await select(primaryIcon, allowsProLifetimeIcons: true)
    }

    func clearError() {
        errorMessage = nil
    }

    static func availableIcons(in infoDictionary: [String: Any]) -> [OpenClientAppIcon] {
        let iconsDictionary = infoDictionary["CFBundleIcons"] as? [String: Any]
            ?? infoDictionary["CFBundleIcons~ipad"] as? [String: Any]
            ?? [:]
        let displayNames = infoDictionary["OpenClientAlternateIconDisplayNames"] as? [String: String] ?? [:]
        let previewFiles = infoDictionary["OpenClientAlternateIconPreviewFiles"] as? [String: String] ?? [:]
        let proLifetimeIconNames = Set(infoDictionary["OpenClientProLifetimeIconNames"] as? [String] ?? [])
        let primary = iconsDictionary["CFBundlePrimaryIcon"] as? [String: Any] ?? [:]
        let primaryName = primary["CFBundleIconName"] as? String ?? "AppIcon"

        var result = [OpenClientAppIcon(
            alternateIconName: nil,
            displayName: displayNames[primaryName] ?? String(localized: "Default"),
            iconFiles: primary["CFBundleIconFiles"] as? [String] ?? []
        )]

        let alternates = iconsDictionary["CFBundleAlternateIcons"] as? [String: Any] ?? [:]
        result.append(contentsOf: alternates.compactMap { name, value in
            guard let icon = value as? [String: Any] else { return nil }
            return OpenClientAppIcon(
                alternateIconName: name,
                displayName: displayNames[name] ?? formattedDisplayName(name),
                iconFiles: previewFiles[name].map { [$0] } ?? (icon["CFBundleIconFiles"] as? [String] ?? []),
                requiresProLifetime: proLifetimeIconNames.contains(name)
            )
        }.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending })

        return result
    }

    private static func formattedDisplayName(_ name: String) -> String {
        name
            .replacingOccurrences(of: "_", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .replacingOccurrences(
                of: "([a-z0-9])([A-Z])",
                with: "$1 $2",
                options: .regularExpression
            )
            .capitalized
    }

    #if canImport(UIKit)
    private func setAlternateIconName(_ name: String?) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            UIApplication.shared.setAlternateIconName(name) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
    #endif
}
