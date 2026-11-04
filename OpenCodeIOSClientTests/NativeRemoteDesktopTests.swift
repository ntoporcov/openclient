import XCTest
@testable import OpenClient

@MainActor
final class NativeRemoteDesktopTests: XCTestCase {
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
