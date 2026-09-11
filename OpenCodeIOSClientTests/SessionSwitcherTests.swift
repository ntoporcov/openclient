import SwiftUI
import UIKit
import XCTest
@testable import OpenClient

@MainActor
final class SessionSwitcherTests: XCTestCase {
    func testMRUOrderingTracksOpeningsAcrossDirectoriesButNotBackgroundSelections() {
        let registry = DirectoryStoreRegistry(activeDirectory: "/a")
        let first = makeSession("a", directory: "/a")
        let second = makeSession("b", directory: "/b")
        let third = makeSession("c", directory: "/a")
        let unseen = makeSession("d", directory: "/b")
        let firstStore = registry.activeStore
        firstStore.sessions = [first, third]
        firstStore.selectedSession = first
        let secondStore = registry.activate("/b")
        secondStore.sessions = [second, unseen]
        secondStore.selectedSession = second
        registry.activate("/a")
        firstStore.selectedSession = third

        secondStore.selectedSession = unseen
        firstStore.selectedSession = third
        let ordered = registry.orderedSessionSwitcherCandidates([unseen, first, second, third], currentSession: third)
        XCTAssertEqual(ordered.map(\.id), ["c", "b", "a", "d"])
    }

    func testMRUQuickSwitchTogglesToLastOpenedSession() {
        let registry = DirectoryStoreRegistry()
        let a = makeSession("a")
        let b = makeSession("b")
        let c = makeSession("c")
        let store = registry.activeStore
        store.sessions = [a, b, c]
        for session in [c, b, a] { store.selectedSession = session }

        let initial = registry.orderedSessionSwitcherCandidates([c, a, b], currentSession: a)
        XCTAssertEqual(initial.map(\.id), ["a", "b", "c"])
        XCTAssertEqual(store.advanceSessionSwitcher(from: a.id, candidates: initial)?.id, b.id)
        store.revealSessionSwitcher()
        XCTAssertEqual(store.sessionSwitcherPresentation?.sessions.map(\.id), ["a", "b", "c"])
        store.selectedSession = store.finishSessionSwitcher()

        let next = registry.orderedSessionSwitcherCandidates([c, a, b], currentSession: b)
        XCTAssertEqual(next.map(\.id), ["b", "a", "c"])
        XCTAssertEqual(store.advanceSessionSwitcher(from: b.id, candidates: next)?.id, a.id)
        _ = store.finishSessionSwitcher()
    }

    func testMRUIncludesCurrentFirstAndKeepsUnvisitedOrderWithoutDuplicates() {
        let registry = DirectoryStoreRegistry()
        let current = makeSession("current")
        let a = makeSession("a")
        let b = makeSession("b")
        XCTAssertEqual(registry.orderedSessionSwitcherCandidates([b, a, b], currentSession: current).map(\.id),
            ["current", "b", "a"])
        XCTAssertEqual(registry.orderedSessionSwitcherCandidates([b, current, a], currentSession: current).map(\.id),
            ["current", "b", "a"])
    }

    func testMRUResetIgnoresRetiredStoresAndDeletedSessions() {
        let registry = DirectoryStoreRegistry()
        let old = registry.activeStore
        let a = makeSession("a")
        let b = makeSession("b")
        old.selectedSession = b
        registry.reset()
        old.selectedSession = a
        XCTAssertEqual(registry.orderedSessionSwitcherCandidates([b, a], currentSession: nil).map(\.id), ["b", "a"])
        registry.markV2SessionDeleted(b.id)
        XCTAssertEqual(registry.orderedSessionSwitcherCandidates([b, a], currentSession: b).map(\.id), ["a"])
    }

    func testQuickReleaseCommitsWithoutShowingOverlay() async {
        let monitor = OpenClientCommandHoldMonitor()
        let released = expectation(description: "Quick switch committed")
        monitor.monitor(isCommandPressed: { false }, holdDelay: .zero,
            onHold: { XCTFail("A released Command key must not show the overlay") },
            onRelease: { released.fulfill() })
        await fulfillment(of: [released], timeout: 1)
    }

    func testHoldRevealsOnceAndCommitsOnceAfterRelease() async {
        let monitor = OpenClientCommandHoldMonitor()
        let released = expectation(description: "Held switch committed")
        var pressed = true
        var reveals = 0
        var commits = 0
        monitor.monitor(isCommandPressed: { pressed }, holdDelay: .zero, onHold: {
            reveals += 1
            monitor.monitor(isCommandPressed: { true }, onHold: { XCTFail("Repeated chord restarted hold") },
                onRelease: { XCTFail("Repeated chord replaced release") })
            pressed = false
        }, onRelease: {
            commits += 1
            released.fulfill()
        })
        await fulfillment(of: [released], timeout: 1)
        XCTAssertEqual(reveals, 1)
        XCTAssertEqual(commits, 1)
    }

    func testFocusLossCancelsRatherThanCommitting() async {
        let monitor = OpenClientCommandHoldMonitor()
        let cancelled = expectation(description: "Focus loss cancelled switch")
        var active = true
        monitor.monitor(isCommandPressed: { true }, isActive: { active }, holdDelay: .zero,
            onHold: { active = false }, onRelease: { XCTFail("Must not navigate after focus loss") },
            onCancel: { cancelled.fulfill() })
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testExplicitCancellationPreventsReleaseNavigation() async {
        let monitor = OpenClientCommandHoldMonitor()
        let cancelled = expectation(description: "Explicit cancellation")
        monitor.monitor(isCommandPressed: { true }, holdDelay: .zero,
            onHold: { monitor.cancel() }, onRelease: { XCTFail("Cancelled switch committed") },
            onCancel: { cancelled.fulfill() })
        await fulfillment(of: [cancelled], timeout: 1)
    }

    func testProjectSwitchingDoesNotRequirePreviouslyVisitedSessions() {
        let model = AppViewModel()
        let first = OpenCodeSession(id: "first", title: "First", workspaceID: nil,
            directory: "/tmp/switcher", projectID: "project", parentID: nil)
        let second = OpenCodeSession(id: "second", title: "Second", workspaceID: nil,
            directory: first.directory, projectID: first.projectID, parentID: nil)
        model.selectedDirectory = first.directory
        model.allSessions = [first, second]
        model.selectedSession = first
        let facade = model.chatFacade

        XCTAssertNil(facade.previouslyOpenedSession(excluding: first.id))
        XCTAssertTrue(facade.canSwitchSession(from: first.id))
        XCTAssertEqual(facade.advanceSessionSwitcher(from: first.id)?.id, second.id)
        _ = model.directoryStore.finishSessionSwitcher()
    }

    func testPriorityCommandLivesOnComposerResponderChainWithoutTakingFocus() async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let editor = ComposerPlaceholderTextView(frame: CGRect(x: 0, y: 0, width: 300, height: 100), textContainer: nil)
        root.view.addSubview(editor)
        XCTAssertTrue(editor.becomeFirstResponder())
        var calls = 0
        let bridge = SessionSwitcherKeyboardController(onAdvance: { isActive in
            XCTAssertTrue(isActive())
            calls += 1
        }, onCancel: {})
        root.addChild(bridge)
        root.view.addSubview(bridge.view)
        bridge.didMove(toParent: root)
        bridge.install()
        let command = try XCTUnwrap(root.keyCommands?.first { $0.input == "`" && $0.modifierFlags == .command })
        XCTAssertTrue(command.wantsPriorityOverSystemBehavior)
        XCTAssertTrue(editor.keyCommands?.contains { $0.propertyList as? String == command.propertyList as? String } == true)
        XCTAssertTrue(editor.isFirstResponder)
        let action = try XCTUnwrap(command.action)
        let target = try XCTUnwrap(editor.target(forAction: action, withSender: command) as? NSObject)
        XCTAssertTrue(target === editor)
        _ = target.perform(action, with: command)
        XCTAssertEqual(calls, 1)
        let copied = try XCTUnwrap(command.copy() as? UIKeyCommand)
        _ = target.perform(action, with: copied)
        XCTAssertEqual(calls, 2, "UIKit may dispatch a copy rather than the registered command")
        SessionSwitcherKeyboardController.dispatchFromMenu()
        XCTAssertEqual(calls, 3, "Native menu and composer commands must reach the same registration")
        XCTAssertTrue(editor.isFirstResponder)
        bridge.uninstall()
        XCTAssertFalse(root.keyCommands?.contains { $0 === command } ?? false)
    }

    func testOutgoingControllerCannotRemoveIncomingChatCommand() throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let old = SessionSwitcherKeyboardController(onAdvance: { _ in XCTFail("Outgoing command invoked") }, onCancel: {})
        var calls = 0
        let new = SessionSwitcherKeyboardController(onAdvance: { _ in calls += 1 }, onCancel: {})
        for bridge in [old, new] {
            root.addChild(bridge)
            root.view.addSubview(bridge.view)
            bridge.didMove(toParent: root)
            bridge.install()
        }
        old.uninstall()
        let commands = root.keyCommands?.filter { $0.input == "`" && $0.modifierFlags == .command } ?? []
        XCTAssertEqual(commands.count, 1)
        let command = try XCTUnwrap(commands.first)
        SessionSwitcherKeyboardController.dispatch(command)
        XCTAssertEqual(calls, 1)
        new.uninstall()
    }

    private func makeSession(_ id: String, directory: String? = nil) -> OpenCodeSession {
        OpenCodeSession(id: id, title: id, workspaceID: nil, directory: directory, projectID: "project", parentID: nil)
    }
}
