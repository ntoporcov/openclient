import XCTest
import UIKit
@testable import OpenClient

@MainActor
final class AppCustomizationStoreTests: XCTestCase {
    func testLineHeightMigratesWithDeviceDefaultAndRestoresExplicitChoice() throws {
        let oldPreferences = try JSONDecoder().decode(AppCustomizationPreferences.self, from: Data("{}".utf8))
        XCTAssertNil(oldPreferences.chatLineHeight)
        let name = "LineHeightPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppCustomizationStore(defaults: defaults)
#if targetEnvironment(macCatalyst)
        XCTAssertEqual(store.chatLineHeight, .standard)
#else
        XCTAssertEqual(store.chatLineHeight, UIDevice.current.userInterfaceIdiom == .pad ? .standard : .tight)
#endif
        for choice in ChatLineHeight.allCases {
            store.setChatLineHeight(choice)
            let restored = AppCustomizationStore(defaults: defaults)
            XCTAssertEqual(restored.chatLineHeight, choice)
            XCTAssertEqual(restored.preferences.appearanceOnly.chatLineHeight, choice)
        }
    }

    func testAnnouncementChoicesPersistWithoutResettingExistingOptIn() throws {
        let name = "AnnouncementPreferences.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let store = AppCustomizationStore(defaults: defaults)
        XCTAssertTrue(store.groupsToolCalls)
        XCTAssertNil(store.preferredStreamingDelivery)
        store.setGroupsToolCalls(true)
        store.setPreferredStreamingDelivery(.steer)
        let restored = AppCustomizationStore(defaults: defaults)
        XCTAssertTrue(restored.groupsToolCalls)
        XCTAssertEqual(restored.preferredStreamingDelivery, .steer)
    }
    func testComposerStylesUseLocalizedLabels() {
        XCTAssertEqual(ComposerStyle.allCases, [.messenger, .assistant])
        XCTAssertEqual(ComposerStyle.allCases.map { String(localized: $0.title) }, ["Messenger", "Assistant"])
    }

    func testSessionCardStylesUseRequestedOrderAndLabels() {
        XCTAssertEqual(SessionCardStyle.allCases, [.compact, .simple, .activity])
        XCTAssertEqual(SessionCardStyle.allCases.map(\.title), ["Compact", "Default", "Activity"])
    }

    func testPreferencesPersistAndRestore() throws {
        let suiteName = "AppCustomizationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let store = AppCustomizationStore(defaults: defaults)
        XCTAssertTrue(store.showsToolCalls)
        XCTAssertTrue(store.groupsToolCalls)
        XCTAssertTrue(store.showsContextChanges)
        XCTAssertTrue(store.showsReasoningBlocks)
        XCTAssertTrue(store.showsActivityLastUserMessage)
        XCTAssertFalse(store.isTodoStripMinimized)
        XCTAssertEqual(store.sessionCardStyle, .simple)
        XCTAssertEqual(store.composerStyle, .messenger)
        XCTAssertNil(store.autoConnectServerID)
        XCTAssertEqual(store.autoConnectLandingDestination, .projects)

        store.setShowsToolCalls(false)
        store.setGroupsToolCalls(false)
        store.setShowsContextChanges(false)
        store.setShowsReasoningBlocks(false)
        store.setShowsActivityLastUserMessage(false)
        store.setTodoStripMinimized(true)
        store.setSessionCardStyle(.activity)
        store.setComposerStyle(.assistant)
        store.setAutoConnectServerID("server-one")
        store.setAutoConnectLandingDestination(.activity)

        let restored = AppCustomizationStore(defaults: defaults)
        XCTAssertFalse(restored.showsToolCalls)
        XCTAssertFalse(restored.groupsToolCalls)
        XCTAssertFalse(restored.showsContextChanges)
        XCTAssertFalse(restored.showsReasoningBlocks)
        XCTAssertFalse(restored.showsActivityLastUserMessage)
        XCTAssertTrue(restored.isTodoStripMinimized)
        XCTAssertEqual(restored.sessionCardStyle, .activity)
        XCTAssertEqual(restored.composerStyle, .assistant)
        XCTAssertEqual(restored.autoConnectServerID, "server-one")
        XCTAssertEqual(restored.autoConnectLandingDestination, .activity)
    }

    func testExistingPreferencesDecodeWithoutRemovedCachePreference() throws {
        let suiteName = "AppCustomizationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "showsChatActivityShimmer": false,
                "autoConnectServerID": "server-one",
            ]),
            forKey: "appCustomizationPreferences"
        )

        let store = AppCustomizationStore(defaults: defaults)

        XCTAssertTrue(store.showsToolCalls)
        XCTAssertTrue(store.groupsToolCalls)
        XCTAssertTrue(store.showsReasoningBlocks)
        XCTAssertTrue(store.showsActivityLastUserMessage)
        XCTAssertFalse(store.isTodoStripMinimized)
        XCTAssertEqual(store.sessionCardStyle, .simple)
        XCTAssertEqual(store.composerStyle, .messenger)
        XCTAssertEqual(store.autoConnectServerID, "server-one")
        XCTAssertEqual(store.autoConnectLandingDestination, .projects)
    }

    func testUnknownPreferenceValuesFallBackWithoutDiscardingOtherPreferences() throws {
        let suiteName = "AppCustomizationStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(
            try JSONSerialization.data(withJSONObject: [
                "showsChatActivityShimmer": false,
                "sessionCardStyle": "future-style",
                "composerStyle": "future-style",
                "autoConnectServerID": "server-one",
                "autoConnectLandingDestination": "future-destination",
            ]),
            forKey: "appCustomizationPreferences"
        )

        let store = AppCustomizationStore(defaults: defaults)

        XCTAssertEqual(store.sessionCardStyle, .simple)
        XCTAssertEqual(store.composerStyle, .messenger)
        XCTAssertEqual(store.autoConnectServerID, "server-one")
        XCTAssertEqual(store.autoConnectLandingDestination, .projects)
    }

    func testAutoConnectServerSelectionMigratesAndReconciles() {
        let suiteName = "AppCustomizationStoreTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let first = OpenCodeServerConfig(name: "First", baseURL: "https://one.example", username: "opencode")
        let renamed = OpenCodeServerConfig(name: "Renamed", baseURL: "https://two.example", username: "opencode")
        let store = AppCustomizationStore(defaults: defaults)
        store.setAutoConnectServerID(first.recentServerID)

        XCTAssertEqual(store.autoConnectServer(in: [first]), first)

        store.migrateAutoConnectServerID(from: first.recentServerID, to: renamed.recentServerID)
        XCTAssertEqual(store.autoConnectServer(in: [renamed]), renamed)

        store.reconcileAutoConnectServer(in: [])
        XCTAssertNil(store.autoConnectServerID)
    }
}
