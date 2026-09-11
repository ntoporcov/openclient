import XCTest
@testable import OpenClient

@MainActor
final class OpenCodeSavedServerTests: XCTestCase {
    private let defaults = UserDefaults.standard
    private let storageKey = AppViewModel.StorageKey.recentServerConfigs
    private var passwordIDsToClean: Set<String> = []
    private var previousMirror: Data?
    private var previousSavedServers: Data?

    override func setUp() async throws {
        try await super.setUp()
        previousSavedServers = defaults.data(forKey: storageKey)
        defaults.removeObject(forKey: storageKey)
        passwordIDsToClean = []
        previousMirror = UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey)
    }

    override func tearDown() async throws {
        defaults.set(previousSavedServers, forKey: storageKey)
        OpenClientSharePayloadStore.mirrorRecentServersData(previousMirror)
        for serverID in passwordIDsToClean {
            viewPasswordStore.deletePassword(for: serverID)
        }
        try await super.tearDown()
    }

    func testSavedServerDecodesWithoutName() throws {
        let data = try XCTUnwrap("""
        [{"baseURL":"https://example.com","username":"nick"}]
        """.data(using: .utf8))

        let servers = try JSONDecoder().decode([OpenCodeSavedServer].self, from: data)

        XCTAssertEqual(servers, [OpenCodeSavedServer(name: nil, iconName: nil, baseURL: "https://example.com", username: "nick")])
        XCTAssertEqual(servers.first?.apiPreference, .automatic)
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
        let saved = OpenCodeServerConfig(
            name: "Desk",
            iconName: "desktopcomputer",
            baseURL: "https://example.com",
            username: "nick",
            password: "",
            apiPreference: .v2
        )
        let viewModel = AppViewModel()
        passwordIDsToClean.insert(saved.recentServerID)
        viewModel.passwordStore.savePassword("secret", for: saved.recentServerID)

        let hydrated = viewModel.hydratedServerConfig(from: saved)

        XCTAssertEqual(hydrated.name, "Desk")
        XCTAssertEqual(hydrated.iconName, "desktopcomputer")
        XCTAssertEqual(hydrated.password, "secret")
        XCTAssertEqual(hydrated.apiPreference, .v2)
    }

    func testSavedServerRoundTripsAPIPreferences() throws {
        for preference in OpenCodeAPIPreference.allCases {
            let saved = OpenCodeSavedServer(
                baseURL: "https://\(preference.rawValue).example.com",
                username: "nick",
                apiPreference: preference
            )

            let data = try JSONEncoder().encode(saved)
            let decoded = try JSONDecoder().decode(OpenCodeSavedServer.self, from: data)

            XCTAssertEqual(decoded.apiPreference, preference)
            XCTAssertEqual(decoded.serverConfig(password: "secret").apiPreference, preference)
        }
    }

    func testServerConfigWithoutAPIPreferenceDefaultsToAutomatic() throws {
        let data = try XCTUnwrap(#"{"baseURL":"https://example.com","username":"nick"}"#.data(using: .utf8))

        let config = try JSONDecoder().decode(OpenCodeServerConfig.self, from: data)

        XCTAssertEqual(config.apiPreference, .automatic)
    }

    func testSavingExplicitPreferenceNormalizesWithoutChangingServerIdentityAndPassword() throws {
        let original = OpenCodeServerConfig(
            name: "Desk",
            baseURL: "https://api-preference.example.com",
            username: "nick",
            password: "secret"
        )
        try writeSavedServers([original])
        let viewModel = AppViewModel()
        viewModel.prepareToEditRecentServer(original)
        viewModel.config.apiPreference = .v2

        viewModel.saveEditedServer()

        let saved = try XCTUnwrap(viewModel.loadRecentServerConfigs().first)
        XCTAssertEqual(saved.recentServerID, original.recentServerID)
        XCTAssertEqual(saved.password, "secret")
        XCTAssertEqual(saved.apiPreference, .automatic)
        XCTAssertEqual(viewModel.config.apiPreference, .v2)
        XCTAssertEqual(viewModel.recentServerConfigs.first?.apiPreference, .automatic)
        XCTAssertEqual(viewModel.recentServerConfigs.count, 1)
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
        XCTAssertEqual(cleanedServers.first?.apiPreference, .automatic)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: cleanedData) as? [[String: Any]])
        XCTAssertEqual(entries.first?["apiPreference"] as? String, "automatic")
        XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey), cleanedData)
    }

    func testLoadRecentServerConfigsDoesNotLimitConnections() throws {
        let configs = (1...6).map { index in
            OpenCodeServerConfig(
                name: "Server \(index)",
                baseURL: "https://server-\(index).example.com",
                username: "nick",
                password: "secret-\(index)"
            )
        }
        try writeSavedServers(configs)

        let viewModel = AppViewModel()

        XCTAssertEqual(viewModel.recentServerConfigs.map(\.name), configs.map(\.name))
    }

    func testAddingConnectionsDoesNotDiscardOldestConnection() throws {
        let viewModel = AppViewModel()
        let configs = (1...6).map { index in
            OpenCodeServerConfig(
                name: "Server \(index)",
                baseURL: "https://server-\(index).example.com",
                username: "nick",
                password: "secret-\(index)"
            )
        }
        configs.forEach { passwordIDsToClean.insert($0.recentServerID) }

        for config in configs {
            viewModel.config = config
            viewModel.persistConfigAfterSuccessfulConnection()
        }

        XCTAssertEqual(viewModel.recentServerConfigs.count, configs.count)
        XCTAssertEqual(viewModel.recentServerConfigs.last?.recentServerID, configs.first?.recentServerID)
        let persistedData = try XCTUnwrap(defaults.data(forKey: storageKey))
        let persistedServers = try JSONDecoder().decode([OpenCodeSavedServer].self, from: persistedData)
        XCTAssertEqual(persistedServers.count, configs.count)
    }

    func testSuccessfulConnectionPersistsServerWithoutUsername() throws {
        let config = OpenCodeServerConfig(
            name: "Unauthenticated LAN",
            baseURL: "http://192.168.0.10:4096",
            username: "",
            password: ""
        )
        let viewModel = AppViewModel()
        viewModel.config = config

        viewModel.persistConfigAfterSuccessfulConnection()

        XCTAssertEqual(viewModel.recentServerConfigs, [config])
        let persistedData = try XCTUnwrap(defaults.data(forKey: storageKey))
        let persistedServers = try JSONDecoder().decode([OpenCodeSavedServer].self, from: persistedData)
        XCTAssertEqual(persistedServers, [OpenCodeSavedServer(config: config)])
        XCTAssertEqual(viewModel.loadRecentServerConfigs(), [config])
    }

    func testEditedServerCanBeSavedWithoutUsername() throws {
        let original = OpenCodeServerConfig(
            name: "LAN",
            baseURL: "http://192.168.0.10:4096",
            username: "opencode",
            password: ""
        )
        try writeSavedServers([original])
        let viewModel = AppViewModel()
        viewModel.recentServerConfigs = [original]
        viewModel.config = OpenCodeServerConfig(
            name: original.name,
            iconName: original.iconName,
            baseURL: original.baseURL,
            username: "",
            password: ""
        )
        viewModel.savedServerEditorMode = .edit(originalServerID: original.recentServerID)

        XCTAssertTrue(viewModel.canSaveEditedServer)
        viewModel.saveEditedServer()

        XCTAssertEqual(viewModel.recentServerConfigs, [viewModel.config])
        XCTAssertEqual(viewModel.loadRecentServerConfigs(), [viewModel.config])
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

    func testNewConfigsDefaultToAutomaticButExplicitJSONOverridesRemainInternal() throws {
        XCTAssertEqual(OpenCodeServerConfig().apiPreference, .automatic)
        XCTAssertEqual(OpenCodeSavedServer(baseURL: "https://default.invalid", username: "nick").apiPreference, .automatic)
        for preference in OpenCodeAPIPreference.allCases {
            let config = OpenCodeServerConfig(apiPreference: preference)
            let decoded = try JSONDecoder().decode(OpenCodeServerConfig.self, from: JSONEncoder().encode(config))
            XCTAssertEqual(decoded.apiPreference, preference)
        }
    }

    func testLaunchMigratesAllSavedPreferencesAndMirrorWithoutChangingCredentialsOrIdentity() throws {
        let configs = OpenCodeAPIPreference.allCases.enumerated().map { index, preference in
            OpenCodeServerConfig(name: "Server \(index)", iconName: "desktopcomputer",
                                 baseURL: "https://migration-\(index).invalid", username: "nick",
                                 password: index == 0 ? "" : "secret-\(index)", apiPreference: preference)
        }
        try writeSavedServers(configs)
        let viewModel = AppViewModel()
        XCTAssertEqual(viewModel.recentServerConfigs, configs.map(\.publicConnectionConfig))
        XCTAssertEqual(viewModel.config.apiPreference, .automatic)
        let data = try XCTUnwrap(defaults.data(forKey: storageKey))
        let records = try JSONDecoder().decode([OpenCodeSavedServer].self, from: data)
        XCTAssertEqual(records.map(\.recentServerID), configs.map(\.recentServerID))
        XCTAssertTrue(records.allSatisfy { $0.apiPreference == .automatic })
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertTrue(entries.allSatisfy { $0["password"] == nil })
        for config in configs {
            // Empty passwords have a stored marker and must not become missing credentials.
            XCTAssertEqual(viewPasswordStore.loadPassword(for: config.recentServerID), config.password)
        }
        XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey), data)
        _ = viewModel.loadRecentServerConfigs()
        XCTAssertEqual(defaults.data(forKey: storageKey), data)
    }

    func testPublicLoaderMigratesPlaintextBeforeRewritingMetadata() throws {
        let config = OpenCodeServerConfig(name: "Old", baseURL: "https://plaintext.invalid",
                                          password: "old-secret", apiPreference: .legacy)
        let original = try JSONEncoder().encode([config])
        defaults.set(original, forKey: storageKey)
        var credentials: [String: String] = [:]
        var savedIDs: [String] = []

        let servers = OpenCodeSavedServer.loadPublicSavedServers(
            loadPassword: { credentials[$0] },
            savePassword: { password, id in
                XCTAssertEqual(self.defaults.data(forKey: self.storageKey), original)
                credentials[id] = password
                savedIDs.append(id)
            }
        )

        XCTAssertEqual(savedIDs, [config.recentServerID])
        XCTAssertEqual(credentials[config.recentServerID], config.password)
        XCTAssertEqual(servers, [OpenCodeSavedServer(config: config.publicConnectionConfig)])
        let sanitized = try XCTUnwrap(defaults.data(forKey: storageKey))
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [[String: Any]])
        XCTAssertNil(entries.first?["password"])
        XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey), sanitized)
    }

    func testPublicLoaderPreservesExistingCredentialIncludingEmptyPasswordMarker() throws {
        for existingPassword in ["current-secret", ""] {
            let config = OpenCodeServerConfig(baseURL: "https://precedence.invalid", password: "stale-plaintext", apiPreference: .v2)
            defaults.set(try JSONEncoder().encode([config]), forKey: storageKey)
            let servers = OpenCodeSavedServer.loadPublicSavedServers(
                loadPassword: { id in
                    XCTAssertEqual(id, config.recentServerID)
                    return existingPassword
                },
                savePassword: { _, _ in XCTFail("An existing credential must never be replaced by plaintext migration") }
            )
            XCTAssertEqual(servers.first?.apiPreference, .automatic)
            let sanitized = try XCTUnwrap(defaults.data(forKey: storageKey))
            let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [[String: Any]])
            XCTAssertNil(entries.first?["password"])
            XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey), sanitized)
        }
    }

    func testFailedOrUnreadableCredentialSavePreservesOriginalBytesAndOnlyMirrorsSanitizedMetadata() throws {
        let available = OpenCodeServerConfig(baseURL: "https://available.invalid", password: "stale", apiPreference: .v2)
        let locked = OpenCodeServerConfig(baseURL: "https://locked.invalid", password: "only-copy", apiPreference: .legacy)
        var original = try JSONEncoder().encode([available, locked])
        original.append(contentsOf: [0x20, 0x0A])
        for readBack: String? in [nil, "unverified-value"] {
            defaults.set(original, forKey: storageKey)
            var attemptedSave = false
            let servers = OpenCodeSavedServer.loadPublicSavedServers(
                loadPassword: { id in
                    if id == available.recentServerID { return "current" }
                    return attemptedSave ? readBack : nil
                },
                savePassword: { _, id in
                    XCTAssertEqual(id, locked.recentServerID)
                    attemptedSave = true
                }
            )
            XCTAssertTrue(attemptedSave)
            XCTAssertEqual(defaults.data(forKey: storageKey), original)
            XCTAssertEqual(servers.map(\.recentServerID), [available.recentServerID, locked.recentServerID])
            XCTAssertTrue(servers.allSatisfy { $0.apiPreference == .automatic })
            let mirrored = try XCTUnwrap(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey))
            let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: mirrored) as? [[String: Any]])
            XCTAssertEqual(entries.count, 2)
            XCTAssertTrue(entries.allSatisfy { $0["password"] == nil })
        }
    }

    func testInvalidSecretBearingRecordsPreventDestructiveMixedArrayCleanup() throws {
        for invalid in [
            #"{"baseURL":"https://broken.invalid","password":"only-copy"}"#,
            #"{"baseURL":"https://broken.invalid","username":"nick","apiPreference":"unknown","password":"only-copy"}"#,
            #"{"baseURL":"https://broken.invalid","username":"nick","password":{"unexpected":"only-copy"}}"#
        ] {
            let original = Data("[{\"baseURL\":\"https://valid.invalid\",\"username\":\"nick\",\"apiPreference\":\"legacy\"},\(invalid)]\n".utf8)
            defaults.set(original, forKey: storageKey)
            let servers = OpenCodeSavedServer.loadPublicSavedServers(
                loadPassword: { _ in XCTFail("Malformed secret records cannot hydrate credentials"); return nil },
                savePassword: { _, _ in XCTFail("Malformed secret records cannot migrate credentials") }
            )
            XCTAssertEqual(servers.first?.baseURL, "https://valid.invalid")
            XCTAssertTrue(servers.allSatisfy { $0.apiPreference == .automatic })
            XCTAssertEqual(defaults.data(forKey: storageKey), original)
            let mirrored = try XCTUnwrap(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey))
            let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: mirrored) as? [[String: Any]])
            XCTAssertTrue(entries.allSatisfy { $0["password"] == nil })
        }
    }

    func testRememberingForcedConnectionPreservesCapturedOwnerConfigWhileSavingAutomaticPreferences() throws {
        for preference in [OpenCodeAPIPreference.legacy, .v2] {
            let config = OpenCodeServerConfig(name: "Forced", baseURL: "https://forced-\(preference.rawValue).invalid",
                                              password: "fixture", apiPreference: preference)
            passwordIDsToClean.insert(config.recentServerID)
            let model = AppViewModel()
            model.config = config
            let profile: OpenCodeAPIProfile = preference == .legacy ? .legacy : .v2
            let connection = OpenCodeBackendFactory(client: .init(config: config), eventManager: model.eventManager)
                .makeConnection(profile: profile, version: "fixture", healthy: true)
            model.backendConnection = connection
            defer { connection.close() }

            model.persistConfigAfterSuccessfulConnection()

            XCTAssertEqual(model.config, config)
            XCTAssertEqual(model.config, connection.openCodeCompatibility?.client.config)
            XCTAssertEqual(connection.openCodeCompatibility?.profile, profile)
            XCTAssertTrue(model.isCurrentBackendConnection(connection))
            XCTAssertEqual(model.recentServerConfigs.first?.apiPreference, .automatic)
            let data = try XCTUnwrap(defaults.data(forKey: storageKey))
            let saved = try JSONDecoder().decode([OpenCodeSavedServer].self, from: data)
            XCTAssertEqual(saved.first?.recentServerID, config.recentServerID)
            XCTAssertTrue(saved.allSatisfy { $0.apiPreference == .automatic })
            XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey), data)
        }
    }

    func testDeferredMigrationBlocksAllChangesThenRetryPreservesRecoveredCredentials() throws {
        let first = OpenCodeServerConfig(name: "First", baseURL: "https://first-deferred.invalid", password: "first-secret", apiPreference: .legacy)
        let locked = OpenCodeServerConfig(name: "Locked", baseURL: "https://locked-deferred.invalid", password: "only-copy", apiPreference: .v2)
        let other = OpenCodeServerConfig(name: "Other", baseURL: "https://other-deferred.invalid", password: "new-secret")
        let original = try JSONEncoder().encode([first, locked])
        defaults.set(original, forKey: storageKey)
        var credentials: [String: String] = [:]
        var isLocked = true
        var saves: [String] = []
        var deletes: [String] = []
        let load: (String) -> String? = { credentials[$0] }
        let save: (String, String) -> Void = { password, id in
            saves.append(id)
            if id != locked.recentServerID || !isLocked { credentials[id] = password }
        }
        let remove: (String) -> Void = { id in
            deletes.append(id)
            credentials.removeValue(forKey: id)
        }
        let staleConfigs = OpenCodeSavedServer.loadPublicSavedServers(loadPassword: load, savePassword: save)
            .map { $0.serverConfig(password: credentials[$0.recentServerID] ?? "") }
        XCTAssertEqual(staleConfigs.last?.password, "")
        XCTAssertEqual(credentials[first.recentServerID], "first-secret")
        XCTAssertEqual(defaults.data(forKey: storageKey), original)
        saves = []
        for change in [OpenCodeSavedServer.Change.save(other, replacingServerID: nil),
                       .save(first, replacingServerID: first.recentServerID), .remove(first.recentServerID)] {
            XCTAssertThrowsError(try OpenCodeSavedServer.persistPublicSavedServers(staleConfigs, change: change,
                loadPassword: load, savePassword: save, deletePassword: remove)) { error in
                XCTAssertTrue(error is OpenCodeSavedServer.PersistenceError)
            }
            XCTAssertEqual(defaults.data(forKey: storageKey), original)
            XCTAssertEqual(credentials[first.recentServerID], "first-secret")
            XCTAssertNil(credentials[locked.recentServerID])
            XCTAssertNil(credentials[other.recentServerID])
            XCTAssertTrue(deletes.isEmpty)
            XCTAssertTrue(saves.allSatisfy { $0 == locked.recentServerID })
        }
        let safeMirror = try XCTUnwrap(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey))
        let mirrorEntries = try XCTUnwrap(JSONSerialization.jsonObject(with: safeMirror) as? [[String: Any]])
        XCTAssertTrue(mirrorEntries.allSatisfy { $0["password"] == nil })

        isLocked = false
        saves = []
        let updated = try OpenCodeSavedServer.persistPublicSavedServers(staleConfigs, change: .save(other, replacingServerID: nil),
            loadPassword: load, savePassword: save, deletePassword: remove)
        XCTAssertEqual(saves, [locked.recentServerID, other.recentServerID])
        XCTAssertEqual(credentials[locked.recentServerID], "only-copy")
        XCTAssertEqual(updated.first(where: { $0.recentServerID == locked.recentServerID })?.password, "only-copy")
        XCTAssertEqual(updated.map(\.recentServerID), [other.recentServerID, first.recentServerID, locked.recentServerID])
        XCTAssertTrue(updated.allSatisfy { $0.apiPreference == .automatic })

        var edited = first
        edited.password = ""
        saves = []
        let afterEdit = try OpenCodeSavedServer.persistPublicSavedServers(updated, change: .save(edited, replacingServerID: first.recentServerID),
            loadPassword: load, savePassword: save, deletePassword: remove)
        XCTAssertEqual(saves, [first.recentServerID])
        XCTAssertEqual(credentials[first.recentServerID], "")
        XCTAssertEqual(credentials[locked.recentServerID], "only-copy")
        XCTAssertEqual(afterEdit.first?.password, "")
        let sanitized = try XCTUnwrap(defaults.data(forKey: storageKey))
        XCTAssertEqual(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey), sanitized)
        let entries = try XCTUnwrap(JSONSerialization.jsonObject(with: sanitized) as? [[String: Any]])
        XCTAssertTrue(entries.allSatisfy { $0["password"] == nil })
    }

    func testCorruptSecretBlocksSaveRememberAndDeleteWithoutClaimingPersistence() throws {
        let other = OpenCodeServerConfig(name: "Other", baseURL: "https://other-corrupt.invalid", password: "protected")
        try writeSavedServers([other])
        var entries = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(defaults.data(forKey: storageKey))) as? [[String: Any]])
        entries.append(["baseURL": "https://corrupt.invalid", "password": "only-copy"])
        let original = try JSONSerialization.data(withJSONObject: entries)
        defaults.set(original, forKey: storageKey)
        let model = AppViewModel()
        let previousRecents = model.recentServerConfigs
        model.prepareToEditRecentServer(other)
        model.config.name = "Changed"
        model.config.password = ""

        model.saveEditedServer()

        XCTAssertEqual(model.recentServerConfigs, previousRecents)
        XCTAssertTrue(model.isShowingAddServerSheet)
        XCTAssertTrue(model.isEditingSavedServer)
        XCTAssertEqual(model.errorMessage, OpenCodeSavedServer.PersistenceError.credentialsUnavailable.localizedDescription)
        XCTAssertEqual(defaults.data(forKey: storageKey), original)
        XCTAssertEqual(viewPasswordStore.loadPassword(for: other.recentServerID), "protected")

        XCTAssertFalse(model.persistConfigAfterSuccessfulConnection())
        XCTAssertTrue(model.isEditingSavedServer)
        XCTAssertEqual(model.recentServerConfigs, previousRecents)
        XCTAssertEqual(defaults.data(forKey: storageKey), original)
        model.removeRecentServer(other)
        XCTAssertEqual(model.recentServerConfigs, previousRecents)
        XCTAssertEqual(defaults.data(forKey: storageKey), original)
        XCTAssertEqual(viewPasswordStore.loadPassword(for: other.recentServerID), "protected")
        XCTAssertNotNil(model.errorMessage)
    }

    func testRememberingExistingStaleConfigDoesNotReplaceRecoveredCredentialWithEmptyMarker() throws {
        let config = OpenCodeServerConfig(name: "Recovered", baseURL: "https://remember-recovered.invalid", password: "only-copy")
        defaults.set(try JSONEncoder().encode([config]), forKey: storageKey)
        var credentials: [String: String] = [:]
        var stale = config
        stale.password = ""
        var writes = 0
        let updated = try OpenCodeSavedServer.persistPublicSavedServers([stale], change: .save(stale, replacingServerID: nil),
            loadPassword: { credentials[$0] }, savePassword: { password, id in
                writes += 1
                credentials[id] = password
            }, deletePassword: { _ in XCTFail("Remembering a server must not delete credentials") })
        XCTAssertEqual(writes, 1, "Only the legacy migration writes the credential")
        XCTAssertEqual(credentials[config.recentServerID], "only-copy")
        XCTAssertEqual(updated.first?.password, "only-copy")
    }

    func testSuccessfulDeletionOnlyDeletesTargetCredentialAndClearsLastServerPrompt() throws {
        let first = OpenCodeServerConfig(name: "First", baseURL: "https://delete-first.invalid", password: "first")
        let second = OpenCodeServerConfig(name: "Second", baseURL: "https://delete-second.invalid", password: "second")
        try writeSavedServers([first, second])
        let model = AppViewModel()
        model.removeRecentServer(first)
        XCTAssertNil(viewPasswordStore.loadPassword(for: first.recentServerID))
        XCTAssertEqual(viewPasswordStore.loadPassword(for: second.recentServerID), "second")
        XCTAssertEqual(model.recentServerConfigs, [second])
        XCTAssertEqual(model.config, second)
        model.removeRecentServer(second)
        XCTAssertNil(viewPasswordStore.loadPassword(for: second.recentServerID))
        XCTAssertTrue(model.recentServerConfigs.isEmpty)
        XCTAssertFalse(model.hasSavedServer)
        XCTAssertFalse(model.showSavedServerPrompt)
        XCTAssertNil(defaults.data(forKey: storageKey))
        XCTAssertNil(UserDefaults(suiteName: OpenClientSharePayloadStore.appGroupID)?.data(forKey: storageKey))
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
