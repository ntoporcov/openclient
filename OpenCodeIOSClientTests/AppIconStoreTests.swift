import XCTest
@testable import OpenClient

#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class AppIconStoreTests: XCTestCase {
    func testAvailableIconsParsesPrimaryAndAlternateIcons() {
        let infoDictionary: [String: Any] = [
            "CFBundleIcons": [
                "CFBundlePrimaryIcon": [
                    "CFBundleIconName": "AppIcon",
                    "CFBundleIconFiles": ["AppIcon60x60"],
                ],
                "CFBundleAlternateIcons": [
                    "ocean-blue": [
                        "CFBundleIconName": "OceanBlue",
                        "CFBundleIconFiles": ["OceanBlue60x60"],
                    ],
                ],
            ],
            "OpenClientAlternateIconDisplayNames": [
                "ocean-blue": "Ocean",
            ],
            "OpenClientProLifetimeIconNames": ["ocean-blue"],
        ]

        let icons = AppIconStore.availableIcons(in: infoDictionary)

        XCTAssertEqual(icons, [
            OpenClientAppIcon(alternateIconName: nil, displayName: "Default", iconFiles: ["AppIcon60x60"]),
            OpenClientAppIcon(
                alternateIconName: "ocean-blue",
                displayName: "Ocean",
                iconFiles: ["OceanBlue60x60"],
                requiresProLifetime: true
            ),
        ])
    }

    func testAvailableIconsFormatsAlternateNameWhenNoDisplayNameIsConfigured() {
        let infoDictionary: [String: Any] = [
            "CFBundleIcons": [
                "CFBundleAlternateIcons": [
                    "midnightGlow": ["CFBundleIconFiles": ["MidnightGlow60x60"]],
                ],
            ],
        ]

        XCTAssertEqual(
            AppIconStore.availableIcons(in: infoDictionary)[1].displayName,
            "Midnight Glow"
        )
    }

    func testAvailableIconsHandlesIconComposerEntriesWithoutIconFiles() {
        let infoDictionary: [String: Any] = [
            "CFBundleIcons": [
                "CFBundleAlternateIcons": [
                    "Liquidy": ["CFBundleIconName": "Liquidy"],
                    "Trees": ["CFBundleIconName": "Trees"],
                ],
            ],
            "OpenClientAlternateIconPreviewFiles": [
                "Liquidy": "Liquidy.png",
                "Trees": "Trees.png",
            ],
        ]

        XCTAssertEqual(
            AppIconStore.availableIcons(in: infoDictionary).map(\.iconFiles),
            [[], ["Liquidy.png"], ["Trees.png"]]
        )
    }

    func testLifetimeIconCannotBeSelectedWithoutLifetimeAccess() async throws {
        let store = AppIconStore(infoDictionary: [
            "CFBundleIcons": [
                "CFBundleAlternateIcons": [
                    "ProLife": ["CFBundleIconName": "ProLife"],
                ],
            ],
            "OpenClientProLifetimeIconNames": ["ProLife"],
        ])
        let icon = try XCTUnwrap(store.icons.first { $0.alternateIconName == "ProLife" })

        await store.select(icon, allowsProLifetimeIcons: false)

        XCTAssertNil(store.selectedAlternateIconName)
        XCTAssertEqual(store.errorMessage, "This app icon requires Pro Lifetime.")
    }

    #if canImport(UIKit)
    func testBuiltAppExposesConfiguredAlternateIcons() {
        let store = AppIconStore()

        XCTAssertTrue(store.supportsAlternateIcons)
        XCTAssertEqual(store.icons.map(\.alternateIconName), [nil, "Liquidy", "AppIcon Pro Life", "Trees"])
        XCTAssertEqual(store.icons.map(\.requiresProLifetime), [false, false, true, false])
        let primaryIconFiles = UIDevice.current.userInterfaceIdiom == .pad
            ? ["AppIcon60x60", "AppIcon76x76"]
            : ["AppIcon60x60"]
        XCTAssertEqual(
            store.icons.map(\.iconFiles),
            [primaryIconFiles, ["Liquidy.png"], ["AppIcon Pro Life.png"], ["Trees.png"]]
        )
    }

    func testConfiguredPreviewFilesLoadFromBundle() throws {
        let liquidyPath = try XCTUnwrap(Bundle.main.path(forResource: "Liquidy.png", ofType: nil))
        let proLifePath = try XCTUnwrap(Bundle.main.path(forResource: "AppIcon Pro Life.png", ofType: nil))
        let treesPath = try XCTUnwrap(Bundle.main.path(forResource: "Trees.png", ofType: nil))

        XCTAssertNotNil(UIImage(contentsOfFile: liquidyPath))
        XCTAssertNotNil(UIImage(contentsOfFile: proLifePath))
        XCTAssertNotNil(UIImage(contentsOfFile: treesPath))
    }
    #endif
}
