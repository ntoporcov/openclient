import XCTest
@testable import OpenClient

final class DSHCredentialTests: XCTestCase {
    @MainActor
    func testConnectionFormSeparatesPastedTokenAndPersistsOnlyIdentityMetadata() throws {
        let suite = "DSHConnectionFormTests." + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DSHConnectionStore(defaults: defaults)
        store.updateServerURL("https://host.test/?token=test%2Bsecret")
        XCTAssertEqual(store.launchURLInput, "https://host.test/")
        XCTAssertEqual(store.tokenInput, "test+secret")
        XCTAssertTrue(store.canConnect)
        let credential = try DSHCredential(serverURL: store.launchURLInput, token: store.tokenInput)
        XCTAssertEqual(credential.token, "test+secret")
        store.nameInput = " My Mac "
        store.iconInput = "laptopcomputer"
        store.saveIdentity(for: credential)
        store.clearInput()
        let restored = DSHConnectionStore(defaults: defaults)
        restored.savedServer(credential)
        XCTAssertEqual(restored.savedName, "My Mac")
        XCTAssertEqual(restored.savedIcon, "laptopcomputer")
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: suite)).contains("test+secret"))
        restored.launchURLInput = "https://host.test/"
        restored.usesPasswordLogin = true
        XCTAssertFalse(restored.canConnect)
        restored.usernameInput = "admin"
        restored.passwordInput = "test-password"
        XCTAssertTrue(restored.canConnect)
        restored.usesPasswordLogin = false
        XCTAssertFalse(restored.canConnect, "A password must never become a token")
    }

    func testSeparateTokenEscapingAndLaunchLinkCompatibility() throws {
        let credential = try DSHCredential(serverURL: "https://host.test/", token: "a+&=秘密")
        XCTAssertEqual(credential.token, "a+&=秘密")
        XCTAssertEqual(credential.baseURL.absoluteString, "https://host.test/")
        XCTAssertEqual(try DSHCredential(serverURL: credential.launchURL.absoluteString, token: ""), credential)
        XCTAssertThrowsError(try DSHCredential(serverURL: "https://host.test/", token: " "))
        XCTAssertThrowsError(try DSHCredential(serverURL: "https://user:pass@host.test/", token: "secret"))
        XCTAssertThrowsError(try DSHCredential(serverURL: "https://host.test/?token=one", token: "two"))
    }

    @MainActor
    func testConnectionIdentityPersistsSeparatelyFromCredentials() throws {
        let suite = "DSHIdentityTests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credential = try DSHCredential(serverURL: "https://host.test", token: "private-token")
        let store = DSHConnectionStore(defaults: defaults)
        store.nameInput = " Studio "
        store.iconInput = "desktopcomputer"
        store.saveIdentity(for: credential)
        let restored = DSHConnectionStore(defaults: defaults)
        restored.savedServer(credential)
        XCTAssertEqual(restored.savedName, "Studio")
        XCTAssertEqual(restored.savedIcon, "desktopcomputer")
        XCTAssertFalse(String(describing: defaults.persistentDomain(forName: suite)).contains("private-token"))
        restored.savedServer(try DSHCredential(serverURL: "https://other.test", token: "other"))
        XCTAssertEqual(restored.savedName, "")
        XCTAssertEqual(restored.savedIcon, "server.rack")
    }

    func testLegacySavedCredentialAndPasswordCredentialRemainDistinct() throws {
        let legacy = try JSONDecoder().decode(DSHCredential.self,
            from: Data(#"{"baseURL":"https://host.test/","token":"old-token"}"#.utf8))
        XCTAssertNil(legacy.username)
        XCTAssertEqual(legacy.token, "old-token")
        let account = try DSHCredential(serverURL: "https://host.test", username: " admin ", password: " p+&=秘密 ")
        XCTAssertEqual(account.launchURL.absoluteString, "https://host.test/")
        XCTAssertEqual(account.username, "admin")
        XCTAssertEqual(try account.configuration.password, " p+&=秘密 ")
        XCTAssertNil(try account.configuration.launchToken)
        let storage = DSHCredentialStore(service: "DSHCredentialTests." + UUID().uuidString)
        defer { try? storage.delete() }
        try storage.save(legacy)
        try storage.save(account)
        XCTAssertEqual(try storage.load(), account)
        XCTAssertThrowsError(try DSHCredential(serverURL: "https://host.test/?token=secret", username: "admin", password: "p"))
    }

    @MainActor
    func testPasswordFormEscapingAndRedirectOriginRestriction() throws {
        let body = String(decoding: DSHTransport.passwordForm(username: "user+test", password: " p&=+ "), as: UTF8.self)
        XCTAssertEqual(body, "username=user%2Btest&password=%20p%26%3D%2B%20&next=%2F")
        let policy = DSHLoginRedirectPolicy(origin: URL(string: "https://host.test/")!)
        XCTAssertTrue(policy.permits(URL(string: "https://host.test:443/?token=t")!))
        for address in ["http://host.test/", "https://other.test/", "https://host.test:8443/", "https://user:pass@host.test/"] {
            XCTAssertFalse(policy.permits(URL(string: address)!))
        }
    }

    func testCredentialValidationKeepsSecretOutOfServerAddress() throws {
        let credential = try DSHCredential(launchURL: " https://host.test/?token=private%2Bvalue#fragment \n")
        XCTAssertEqual(credential.baseURL.absoluteString, "https://host.test/")
        XCTAssertEqual(credential.token, "private+value")
        XCTAssertEqual(try DSHCredential(launchURL: credential.launchURL.absoluteString), credential)
        for invalid in ["https://host.test/", "https://host.test/?token=", "https://user:pass@host.test/?token=t", "file:///private?token=t"] {
            XCTAssertThrowsError(try DSHCredential(launchURL: invalid))
        }
    }

    func testKeychainRoundTripReplacementAndDeletionAreIsolated() throws {
        let storage = DSHCredentialStore(service: "DSHCredentialTests." + UUID().uuidString)
        defer { try? storage.delete() }
        XCTAssertNil(try storage.load())
        let first = try DSHCredential(launchURL: "https://first.test/?token=one")
        let second = try DSHCredential(launchURL: "https://second.test/?token=two")
        try storage.save(first)
        XCTAssertEqual(try storage.load(), first)
        try storage.save(second)
        XCTAssertEqual(try storage.load(), second)
        try storage.delete()
        XCTAssertNil(try storage.load())
        try storage.delete()
    }
}
