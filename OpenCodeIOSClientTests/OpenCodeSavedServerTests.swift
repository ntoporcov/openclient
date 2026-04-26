import XCTest
@testable import OpenClient

@MainActor
final class OpenCodeSavedServerTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let storageKey = AppViewModel.StorageKey.recentServerConfigs
    private var passwordIDsToClean: Set<String> = []

    override func setUp() {
        super.setUp()
        defaults.removeObject(forKey: storageKey)
        passwordIDsToClean = []
    }

    override func tearDown() {
        defaults.removeObject(forKey: storageKey)
        for serverID in passwordIDsToClean {
            viewPasswordStore.deletePassword(for: serverID)
        }
        super.tearDown()
    }

    func testSavedServerDecodesWithoutName() throws {
        let data = try XCTUnwrap("""
        [{"baseURL":"https://example.com","username":"nick"}]
        """.data(using: .utf8))

        let servers = try JSONDecoder().decode([OpenCodeSavedServer].self, from: data)

        XCTAssertEqual(servers, [OpenCodeSavedServer(name: nil, iconName: nil, baseURL: "https://example.com", username: "nick")])
    }

    func testSavedServerPreservesIconWhenDecoded() throws {
        let data = try XCTUnwrap("""
        [{"name":"Desk","iconName":"desktopcomputer","baseURL":"https://example.com","username":"nick"}]
        """.data(using: .utf8))

        let servers = try JSONDecoder().decode([OpenCodeSavedServer].self, from: data)

        XCTAssertEqual(servers.first?.iconName, "desktopcomputer")
        XCTAssertEqual(servers.first?.serverConfig(password: "secret").displayIconName, "desktopcomputer")
    }

    func testHydratedServerConfigPreservesNameAndIcon() {
        let saved = OpenCodeServerConfig(name: "Desk", iconName: "desktopcomputer", baseURL: "https://example.com", username: "nick", password: "")
        let viewModel = AppViewModel()
        passwordIDsToClean.insert(saved.recentServerID)
        viewModel.passwordStore.savePassword("secret", for: saved.recentServerID)

        let hydrated = viewModel.hydratedServerConfig(from: saved)

        XCTAssertEqual(hydrated.name, "Desk")
        XCTAssertEqual(hydrated.iconName, "desktopcomputer")
        XCTAssertEqual(hydrated.password, "secret")
    }

    func testLoadRecentServerConfigsRecoversValidEntriesFromCorruptPayload() throws {
        let data = try XCTUnwrap("""
        [
          {"name":"Desk","iconName":"desktopcomputer","baseURL":"https://example.com","username":"nick"},
          {"baseURL":"https://broken.example.com"}
        ]
        """.data(using: .utf8))
        defaults.set(data, forKey: storageKey)

        let viewModel = AppViewModel()
        let servers = viewModel.loadRecentServerConfigs()

        XCTAssertEqual(servers.count, 1)
        XCTAssertEqual(servers.first?.name, "Desk")
        XCTAssertEqual(servers.first?.iconName, "desktopcomputer")

        let cleanedData = try XCTUnwrap(defaults.data(forKey: storageKey))
        let cleanedServers = try JSONDecoder().decode([OpenCodeSavedServer].self, from: cleanedData)
        XCTAssertEqual(cleanedServers.count, 1)
        XCTAssertEqual(cleanedServers.first?.name, "Desk")
    }

    func testSaveEditedServerRenamesWithoutChangingIdentity() throws {
        let original = OpenCodeServerConfig(name: "Old Name", iconName: "server.rack", baseURL: "https://rename-only.example.com", username: "nick", password: "secret")
        let viewModel = AppViewModel()

        try writeSavedServers([original])
        viewModel.recentServerConfigs = [original]
        viewModel.config = OpenCodeServerConfig(name: "New Name", iconName: "desktopcomputer", baseURL: original.baseURL, username: original.username, password: original.password)
        viewModel.savedServerEditorMode = .edit(originalServerID: original.recentServerID)

        viewModel.saveEditedServer()

        XCTAssertEqual(viewModel.recentServerConfigs.first?.name, "New Name")
        XCTAssertEqual(viewModel.recentServerConfigs.first?.iconName, "desktopcomputer")
        XCTAssertEqual(viewModel.passwordStore.loadPassword(for: original.recentServerID), "secret")

        let reloaded = viewModel.loadRecentServerConfigs()
        XCTAssertEqual(reloaded.first?.name, "New Name")
        XCTAssertEqual(reloaded.first?.iconName, "desktopcomputer")
    }

    func testSaveEditedServerMigratesPasswordWhenIdentityChanges() throws {
        let original = OpenCodeServerConfig(name: "LAN", baseURL: "http://old-host.local:4096", username: "nick", password: "")
        let originalID = original.recentServerID
        let updated = OpenCodeServerConfig(name: "LAN", baseURL: "https://new-host.example.com", username: "dev", password: "")
        let updatedID = updated.recentServerID
        let viewModel = AppViewModel()

        try writeSavedServers([original])
        passwordIDsToClean.insert(updatedID)
        viewModel.recentServerConfigs = [original]
        viewModel.passwordStore.savePassword("migrated-secret", for: originalID)
        viewModel.config = updated
        viewModel.savedServerEditorMode = .edit(originalServerID: originalID)

        viewModel.saveEditedServer()

        XCTAssertNil(viewModel.passwordStore.loadPassword(for: originalID))
        XCTAssertEqual(viewModel.passwordStore.loadPassword(for: updatedID), "migrated-secret")
        XCTAssertEqual(viewModel.recentServerConfigs.first?.recentServerID, updatedID)
        XCTAssertEqual(viewModel.recentServerConfigs.first?.password, "migrated-secret")
    }

    func testSaveEditedServerDeduplicatesCollidingDestination() throws {
        let original = OpenCodeServerConfig(name: "Alpha", baseURL: "https://alpha.example.com", username: "nick", password: "alpha-secret")
        let duplicate = OpenCodeServerConfig(name: "Beta", baseURL: "https://beta.example.com", username: "dev", password: "beta-secret")
        let viewModel = AppViewModel()

        try writeSavedServers([original, duplicate])
        passwordIDsToClean.insert(duplicate.recentServerID)
        viewModel.recentServerConfigs = [original, duplicate]
        viewModel.config = OpenCodeServerConfig(name: "Merged", baseURL: duplicate.baseURL, username: duplicate.username, password: "merged-secret")
        viewModel.savedServerEditorMode = .edit(originalServerID: original.recentServerID)

        viewModel.saveEditedServer()

        XCTAssertEqual(viewModel.recentServerConfigs.count, 1)
        XCTAssertEqual(viewModel.recentServerConfigs.first?.name, "Merged")
        XCTAssertEqual(viewModel.passwordStore.loadPassword(for: duplicate.recentServerID), "merged-secret")
    }

    private func writeSavedServers(_ configs: [OpenCodeServerConfig]) throws {
        for config in configs {
            passwordIDsToClean.insert(config.recentServerID)
            viewPasswordStore.deletePassword(for: config.recentServerID)
            viewPasswordStore.savePassword(config.password, for: config.recentServerID)
        }

        let savedServers = configs.map(OpenCodeSavedServer.init)
        let data = try JSONEncoder().encode(savedServers)
        defaults.set(data, forKey: storageKey)
    }

    private var viewPasswordStore: OpenCodeServerPasswordStore {
        OpenCodeServerPasswordStore()
    }
}
