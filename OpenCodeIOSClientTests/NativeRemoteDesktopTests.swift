import XCTest
import UIKit
@testable import OpenClient

@MainActor
final class NativeRemoteDesktopTests: XCTestCase {
    func testSavedCredentialsAndAuthenticatedOpenCodeAccess() async throws {
        struct Fixture: Decodable { let bridgePort: Int }
        let data: Data
        do { (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:14079/events")!) }
        catch { throw XCTSkip("Start the native-desktop fixture") }
        let port = try JSONDecoder().decode(Fixture.self, from: data).bridgePort
        let endpoint = OpenClientBridgeEndpoint(healthURL: URL(string: "http://127.0.0.1:\(port)/openclient/v1/health")!,
            webSocketURL: URL(string: "ws://127.0.0.1:\(port)/openclient/v1/ws")!, port: port, openCodePort: 14079)
        let config = OpenCodeServerConfig(baseURL: "http://127.0.0.1:14079", password: "fixture-api-password", apiPreference: .v2)
        let access = OpenClientDesktopAccess(client: OpenCodeAPIClient(config: config), directory: nil, workspaceID: nil)
        let keychain = OpenClientDesktopCredentialStore(service: "desktop-tests-" + UUID().uuidString)
        let scope = config.recentServerID + ":fixture-target"
        defer { try? keychain.delete(scope: scope) }
        let coordinator = OpenClientRemoteDesktopCoordinator(credentials: keychain)
        let store = OpenClientRemoteDesktopStore()
        let history = DesktopClipboardHistory()
        defer { coordinator.disconnect(store: store) }
        func wait(_ condition: () -> Bool) async throws {
            for _ in 0..<100 {
                if condition() { return }
                try await Task.sleep(for: .milliseconds(50))
            }
            XCTFail("Desktop state did not arrive: \(store.errorMessage ?? "no error")")
        }
        coordinator.open(endpoint: endpoint, access: access, store: store)
        try await wait { store.needsCredentials }
        coordinator.authenticate(username: "fixture-user", password: "wrong", save: true)
        try await wait { store.errorMessage != nil }
        XCTAssertNil(try keychain.load(scope: scope), "Rejected credentials must never be saved")

        let pasteboardChanges = UIPasteboard.general.changeCount
        coordinator.open(endpoint: endpoint, access: access, store: store, clipboardHistory: history)
        try await wait { store.needsCredentials }
        coordinator.authenticate(username: "fixture-user", password: "fixture-password", save: true)
        try await wait { store.isConnected }
        try await wait { history.items.first?.text == "Host clipboard fixture — 🖥" }
        XCTAssertEqual(UIPasteboard.general.changeCount, pasteboardChanges)
        XCTAssertEqual(try keychain.load(scope: scope)?.password, "fixture-password")
        XCTAssertNil(try keychain.load(scope: scope + "other-host"))

        coordinator.open(endpoint: endpoint, access: access, store: store)
        try await wait { store.isConnected }
        XCTAssertFalse(store.needsCredentials, "Saved login must bypass the form")

        coordinator.disconnect(store: store)
        try keychain.save(.init(username: "fixture-user", password: "stale"), scope: scope)
        coordinator.open(endpoint: endpoint, access: access, store: store)
        try await wait { store.errorMessage != nil }
        coordinator.open(endpoint: endpoint, access: access, store: store)
        try await wait { store.needsCredentials }
        coordinator.forgetCredentials(store: store)
        XCTAssertNil(try keychain.load(scope: scope))
        coordinator.authenticate(username: "fixture-user", password: "fixture-password", save: false)
        try await wait { store.isConnected }
        XCTAssertNil(try keychain.load(scope: scope))

        let denied = OpenClientDesktopAccess(client: OpenCodeAPIClient(config: .init(baseURL: config.baseURL, password: "wrong")), directory: nil, workspaceID: nil)
        coordinator.open(endpoint: endpoint, access: denied, store: store)
        try await wait { store.errorMessage != nil }
        XCTAssertFalse(store.needsCredentials)
        XCTAssertFalse(store.isConnected)
    }

    // Run `bun test/fixtures/native-desktop.ts` in OpenClientPlugin first.
    // This fixture contains fake ARD credentials and never opens the host desktop.
    func testNativeAuthenticationFramebufferInputAndReconnect() async throws {
        struct Fixture: Decodable {
            let fixture: String
            let viewerURL: URL?
            let events: [Event]
            struct Event: Decodable { let type: String; let key: Int?; let x: Int?; let y: Int? }
        }
        func fixture(_ path: String) async throws -> Fixture {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:14079/\(path)")!)
            return try JSONDecoder().decode(Fixture.self, from: data)
        }
        let initial: Fixture
        do { initial = try await fixture("session") }
        catch { throw XCTSkip("Start the native-desktop fixture to run this integration test") }
        XCTAssertEqual(initial.fixture, "native-desktop")
        for attempt in 0..<3 {
            let ticket = attempt == 0 ? initial : try await fixture("session")
            let tunnel = OpenClientDesktopTunnel()
            let native = OpenClientNativeDesktopSession()
            let store = OpenClientRemoteDesktopStore()
            defer { native.stop(); tunnel.stop() }
            let port = try await tunnel.start(viewerURL: XCTUnwrap(ticket.viewerURL))
            native.start(port: port, store: store)
            for _ in 0..<100 where !store.needsCredentials && store.errorMessage == nil { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(store.needsCredentials, store.errorMessage ?? "No credential challenge")
            native.authenticate(username: "fixture-user", password: attempt == 1 ? "wrong" : "fixture-password")
            if attempt == 1 {
                for _ in 0..<100 where store.errorMessage == nil { try await Task.sleep(for: .milliseconds(50)) }
                XCTAssertNotNil(store.errorMessage)
                XCTAssertFalse(store.isConnected)
                continue
            }
            for _ in 0..<100 where store.frame == nil && store.errorMessage == nil { try await Task.sleep(for: .milliseconds(50)) }
            XCTAssertTrue(store.isConnected, store.errorMessage ?? "Not connected")
            XCTAssertEqual(store.frame?.width, 320)
            XCTAssertEqual(store.frame?.height, 180)
            native.type("A")
            native.pointer(x: 100, y: 50, down: true)
            native.pointer(x: 100, y: 50, down: false)
            try await Task.sleep(for: .milliseconds(100))
            let events = try await fixture("events").events.dropFirst(ticket.events.count)
            XCTAssertTrue(events.contains { $0.type == "authenticated" })
            XCTAssertTrue(events.contains { $0.key == 65 })
            XCTAssertTrue(events.contains { $0.x == 100 && $0.y == 50 })
        }
    }
}
