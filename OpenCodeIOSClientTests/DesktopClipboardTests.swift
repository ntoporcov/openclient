import XCTest
import Network
import UIKit
@testable import OpenClient

@MainActor
final class DesktopClipboardTests: XCTestCase {
    func testHistorySurvivesViewerReopenButIsolatesAccountsAndTargets() {
        let store = DesktopClipboardStore()
        let first = store.history(serverID: "server/account-a")
        first.activate(targetID: "computer-a")
        first.capture("copied text", targetID: "computer-a")
        first.activate(targetID: "computer-a")
        XCTAssertTrue(first === store.history(serverID: "server/account-a"))
        XCTAssertEqual(first.items.map(\.text), ["copied text"])
        XCTAssertTrue(store.history(serverID: "server/account-b").items.isEmpty)
        first.activate(targetID: "computer-b")
        first.capture("late event", targetID: "computer-a")
        XCTAssertTrue(first.items.isEmpty)
    }

    func testHistoryBoundsDeduplicatesAndPromotesRecopiedItems() {
        let history = DesktopClipboardHistory()
        history.activate(targetID: "target")
        history.capture("", targetID: "target")
        history.capture(String(repeating: "é", count: 40_000), targetID: "target")
        XCTAssertTrue(history.items.isEmpty)
        for index in 0..<45 { history.capture("item \(index)", targetID: "target") }
        XCTAssertEqual(history.items.count, DesktopClipboardHistory.maximumItems)
        let id = history.items.first?.id
        history.capture("item 44", targetID: "target")
        XCTAssertEqual(history.items.first?.id, id)
        history.capture("item 10", targetID: "target")
        XCTAssertEqual(history.items.first?.text, "item 10")
        XCTAssertEqual(history.items.filter { $0.text == "item 10" }.count, 1)
        history.clear()
        XCTAssertTrue(history.items.isEmpty)
    }

    func testRFBClipboardArrivesWithAutomaticClipboardRedirectionDisabled() async throws {
        let received = expectation(description: "Receive-only RFB clipboard callback")
        let server = try ClipboardRFBFixture()
        defer { server.stop() }
        let port = try await server.start()
        let clipboardChangeCount = UIPasteboard.general.changeCount
        let session = OpenClientNativeDesktopSession()
        let store = OpenClientRemoteDesktopStore()
        defer { session.stop() }
        session.onClipboardText = { text in
            XCTAssertEqual(text, "Computer clipboard fixture")
            received.fulfill()
        }
        session.start(port: port, store: store)
        await fulfillment(of: [received], timeout: 10)
        XCTAssertEqual(UIPasteboard.general.changeCount, clipboardChangeCount,
                       "Capturing remote text must not overwrite the device clipboard")
    }
}

/// A local RFB 3.8 server with no authentication, used only by isolated tests.
private final class ClipboardRFBFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DesktopClipboardTests.RFB")
    private var peer: NWConnection?

    init() throws { listener = try NWListener(using: .tcp, on: .any) }

    func start() async throws -> UInt16 {
        try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    continuation.resume(returning: listener.port!.rawValue)
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default: break
                }
            }
            listener.newConnectionHandler = { [weak self] peer in
                guard let self else { return }
                self.peer = peer
                peer.start(queue: self.queue)
                self.send(Data("RFB 003.008\n".utf8), peer: peer)
                self.read(12, peer: peer) {
                    self.send(Data([1, 1]), peer: peer)
                    self.read(1, peer: peer) {
                        self.send(Data([0, 0, 0, 0]), peer: peer)
                        self.read(1, peer: peer) {
                            // 2×2 framebuffer, 32-bit true color, empty desktop name.
                            self.send(Data([0, 2, 0, 2, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255,
                                             16, 8, 0, 0, 0, 0, 0, 0, 0, 0]), peer: peer)
                            let text = Data("Computer clipboard fixture".utf8)
                            self.send(Data([3, 0, 0, 0, 0, 0, 0, UInt8(text.count)]) + text, peer: peer)
                        }
                    }
                }
            }
            listener.start(queue: queue)
        }
    }

    private func send(_ data: Data, peer: NWConnection) {
        peer.send(content: data, completion: .contentProcessed { _ in })
    }

    private func read(_ count: Int, peer: NWConnection, then: @escaping @Sendable () -> Void) {
        peer.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
            guard error == nil, data?.count == count else { return }
            then()
        }
    }

    func stop() {
        queue.async { [self] in peer?.cancel(); listener.cancel() }
    }
}
