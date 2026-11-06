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

    func testAppleSubscriptionRequestsPromisedClipboardWithoutChangingDevicePasteboard() async throws {
        try await verifyAppleClipboard(utf16: false, expected: "Mac clipboard — café 🖥")
    }

    func testAppleMalformedArchiveDoesNotPreventFollowingUTF16Clipboard() async throws {
        try await verifyAppleClipboard(utf16: true, expected: "Selection — 🖥")
    }

    private func verifyAppleClipboard(utf16: Bool, expected: String) async throws {
        let received = expectation(description: "Apple compressed pasteboard callback")
        let server = try ClipboardRFBFixture(apple: true, utf16: utf16)
        defer { server.stop() }
        let port = try await server.start()
        let changeCount = UIPasteboard.general.changeCount
        let session = OpenClientNativeDesktopSession()
        let store = OpenClientRemoteDesktopStore()
        defer { session.stop() }
        session.onClipboardText = { text in
            XCTAssertEqual(text, expected)
            received.fulfill()
        }
        session.start(port: port, store: store)
        await fulfillment(of: [received], timeout: 10)
        XCTAssertEqual(UIPasteboard.general.changeCount, changeCount)
    }
}

/// A local RFB 3.8 server with no authentication, used only by isolated tests.
private final class ClipboardRFBFixture: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "DesktopClipboardTests.RFB")
    private var peer: NWConnection?
    private let apple: Bool
    private let utf16: Bool

    init(apple: Bool = false, utf16: Bool = false) throws {
        self.apple = apple
        self.utf16 = utf16
        listener = try NWListener(using: .tcp, on: .any)
    }

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
                self.send(Data((self.apple ? "RFB 003.889\n" : "RFB 003.008\n").utf8), peer: peer)
                self.read(12, peer: peer) {
                    self.send(Data([1, 1]), peer: peer)
                    self.read(1, peer: peer) {
                        self.send(Data([0, 0, 0, 0]), peer: peer)
                        self.read(1, peer: peer) {
                            // 2×2 framebuffer, 32-bit true color, empty desktop name.
                            self.send(Data([0, 2, 0, 2, 32, 24, 0, 1, 0, 255, 0, 255, 0, 255,
                                             16, 8, 0, 0, 0, 0, 0, 0, 0, 0]), peer: peer)
                            if self.apple {
                                self.readAppleClientMessage(peer)
                            } else {
                                let text = Data("Computer clipboard fixture".utf8)
                                self.send(Data([3, 0, 0, 0, 0, 0, 0, UInt8(text.count)]) + text, peer: peer)
                            }
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

    private func readAppleClientMessage(_ peer: NWConnection) {
        peer.receive(minimumIncompleteLength: 1, maximumLength: 1) { data, _, _, error in
            guard error == nil, let type = data?.first else { return }
            switch type {
            case 0:
                self.read(19, peer: peer) { self.readAppleClientMessage(peer) }
            case 2:
                peer.receive(minimumIncompleteLength: 3, maximumLength: 3) { data, _, _, _ in
                    guard let data, data.count == 3 else { return }
                    let count = Int(data[1]) * 256 + Int(data[2])
                    self.read(count * 4, peer: peer) { self.readAppleClientMessage(peer) }
                }
            case 3:
                self.read(9, peer: peer) { self.readAppleClientMessage(peer) }
            case 0x15:
                self.read(7, peer: peer) {
                    // Promise notification. The payload is sent only after a request.
                    self.send(Data([0x1f, 0, 1, 0] + Array(repeating: 0, count: 12)), peer: peer)
                    self.readAppleClientMessage(peer)
                }
            case 0x0b:
                self.read(7, peer: peer) {
                    if self.utf16 {
                        // A truncated flavor archive followed by valid UTF-16BE.
                        self.send(Data(base64Encoded: "HwAAAAAAAAEAAABGAAAARHicY2BgYGRgYBAvKE3KyUzWKy1JMzTTLchJzMzTLUmtKGFAABmGYIZUhhwgTmYoYchkyGfIY1BQEGFQuGF7FwAGbQ7X")!, peer: peer)
                        self.send(Data(base64Encoded: "HwAAAAAAAAEAAABHAAAARXicY2BgYGRgYBAvKE3KyUzWKy1JMzTTLchJzMzTLUmtKGFAABmGYIZUhhwgTmYoYchkyGfIY1BQEGFQuGF7dykAFekPfA==")!, peer: peer)
                        return
                    }
                    // Independent zlib fixture with UTF-8 text and a big-endian archive.
                    self.send(Data(base64Encoded: "HwAAAAAAAAEAAABGAAAARnicY2BgYGRgYBArKE3KyUzWKy1Js9AtyEnMzNMtSa0oYUAAGd/EZIXknMyCpPzEohSFRw1TFJIT0w6vVPgwf9pSAFxWFTI=")!, peer: peer)
                }
            default: break
            }
        }
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
