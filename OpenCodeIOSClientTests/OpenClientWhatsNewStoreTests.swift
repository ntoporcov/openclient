import XCTest
@testable import OpenClient

@MainActor
final class OpenClientWhatsNewStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "OpenClientWhatsNewStoreTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testFreshInstallRecordsVersionWithoutPresenting() {
        let store = makeStore(hasExistingConnection: false)

        XCTAssertNil(store.presentedRelease)

        let nextLaunch = makeStore(hasExistingConnection: true)
        XCTAssertNil(nextLaunch.presentedRelease)
    }

    func testExistingInstallWithoutTrackedVersionPresentsCurrentRelease() {
        let store = makeStore(hasExistingConnection: true)

        XCTAssertEqual(store.presentedRelease?.version, "2.0")
    }

    func testExistingInstallMigrationPresentsCurrentReleaseOnlyOnce() {
        let firstLaunch = makeStore(hasExistingConnection: true)
        XCTAssertEqual(firstLaunch.presentedRelease?.version, "2.0")

        let secondLaunch = makeStore(hasExistingConnection: true)
        XCTAssertNil(secondLaunch.presentedRelease)
    }

    func testTrackedUpgradePresentsCurrentReleaseOnlyOnce() {
        _ = OpenClientWhatsNewStore(
            defaults: defaults,
            currentVersion: "1.0",
            releases: [release],
            hasExistingConnection: false
        )

        let updatedStore = makeStore(hasExistingConnection: false)
        XCTAssertEqual(updatedStore.presentedRelease?.version, "2.0")

        let reopenedStore = makeStore(hasExistingConnection: false)
        XCTAssertNil(reopenedStore.presentedRelease)
    }

    func testNewAnnouncementPresentsOnceForALaterBuildOfTheSameVersion() {
        _ = OpenClientWhatsNewStore(
            defaults: defaults,
            currentVersion: "2.0",
            releases: [],
            hasExistingConnection: false
        )

        let updatedBuild = makeStore(hasExistingConnection: false)
        XCTAssertEqual(updatedBuild.presentedRelease?.version, "2.0")

        let reopenedBuild = makeStore(hasExistingConnection: false)
        XCTAssertNil(reopenedBuild.presentedRelease)
    }

    func testCurrentCatalogDescribesVersionOnePointZeroPointFifteen() {
        let release = OpenClientReleaseNotesCatalog.releases.first { $0.version == "1.0.15" }

        XCTAssertEqual(release?.title, "Make it yours")
        XCTAssertEqual(release?.features.map(\.title), [
            "Rich link previews",
            "Projects, your way",
            "Make it yours",
            "Connect on launch",
        ])
    }

    func testCurrentCatalogDescribesActivityRelease() {
        let release = OpenClientReleaseNotesCatalog.releases.first { $0.version == "1.0.16" }

        XCTAssertEqual(release?.title, "Activity, at a glance")
        XCTAssertEqual(release?.hero, .activity)
        XCTAssertEqual(release?.featureSectionTitle, "Every conversation, in motion")
        XCTAssertFalse(release?.showsSetup == true)
        XCTAssertEqual(release?.features.map(\.title), [
            "One view across projects",
            "The latest context, live",
            "Cards that fit your flow",
            "Start from anywhere",
        ])
    }

    func testCurrentCatalogDescribesInternationalizationRelease() {
        let release = OpenClientReleaseNotesCatalog.releases.first { $0.version == "1.0.17" }

        XCTAssertEqual(release?.title, "Hello, world")
        XCTAssertEqual(release?.hero, .internationalization)
        XCTAssertTrue(release?.features.isEmpty == true)
        XCTAssertFalse(release?.showsSetup == true)
        XCTAssertEqual(release?.internationalizationAnnouncements.map(\.localeIdentifier), ["pt-BR", "it"])
        XCTAssertEqual(release?.internationalizationAnnouncements.map(\.nativeName), ["Português (Brasil)", "Italiano"])
        XCTAssertTrue(release?.internationalizationAnnouncements.allSatisfy { $0.palette.count == 3 } == true)
        XCTAssertNil(release?.internationalizationAnnouncements.first?.contributor)
        XCTAssertEqual(release?.internationalizationAnnouncements.last?.contributor?.name, "Lorenzo Salami")
        XCTAssertEqual(release?.internationalizationAnnouncements.last?.contributor?.handle, "@LSalami")
        XCTAssertTrue(OpenClientLocalizationContribution.prompt.contains("https://github.com/ntoporcov/openclient"))
        XCTAssertTrue(OpenClientLocalizationContribution.prompt.contains("[YOUR LANGUAGE]"))
    }

    func testNextVersionPresentsInternationalizationRelease() {
        let store = OpenClientWhatsNewStore(
            defaults: defaults,
            currentVersion: "1.0.17",
            releases: OpenClientReleaseNotesCatalog.releases,
            hasExistingConnection: true
        )

        XCTAssertEqual(store.presentedRelease?.version, "1.0.17")
        XCTAssertEqual(store.presentedRelease?.internationalizationAnnouncements.count, 2)
    }

    func testCurrentCatalogDescribesIPadRelease() {
        let release = OpenClientReleaseNotesCatalog.releases.first { $0.version == "1.0.18" }

        XCTAssertEqual(release?.title, "A bigger canvas")
        XCTAssertEqual(release?.hero, .ipad)
        XCTAssertEqual(release?.featureSectionTitle, "More room for the work that matters")
        XCTAssertFalse(release?.showsSetup == true)
        XCTAssertEqual(release?.features.map(\.title), [
            "Comfortable reading width",
            "Open chats in new windows",
            "Browse beside your chat",
            "Activity, simplified",
        ])
    }

    func testCurrentCatalogDescribesTalkRelease() {
        let release = OpenClientReleaseNotesCatalog.releases.first { $0.version == "1.0.19" }

        XCTAssertEqual(release?.title, "Talk it through")
        XCTAssertEqual(release?.hero, .talk)
        XCTAssertEqual(release?.featureSectionTitle, "More natural, less in the way")
        XCTAssertFalse(release?.showsSetup == true)
        XCTAssertEqual(release?.features.map(\.title), [
            "Meet Talk mode",
            "Answers without the wait",
            "Todos on your terms",
            "Activity, refined",
        ])
    }

    private var release: OpenClientReleaseNotes {
        OpenClientReleaseNotes(
            version: "2.0",
            title: "Release",
            summary: "Summary",
            features: []
        )
    }

    private func makeStore(hasExistingConnection: Bool) -> OpenClientWhatsNewStore {
        OpenClientWhatsNewStore(
            defaults: defaults,
            currentVersion: "2.0",
            releases: [release],
            hasExistingConnection: hasExistingConnection
        )
    }
}
