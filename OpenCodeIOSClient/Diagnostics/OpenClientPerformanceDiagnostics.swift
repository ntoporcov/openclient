import Foundation
import os

/// Signpost intervals for the chat hot paths. Record them in Instruments with the
/// os_signpost instrument filtered to subsystem `com.ntoporcov.openclient`,
/// category `Performance`. Intervals cost nothing when no recorder is attached.
enum OpenClientPerformanceSignposts {
    static let signposter = OSSignposter(subsystem: "com.ntoporcov.openclient", category: "Performance")

    static func interval<T>(_ name: StaticString, detail: @autoclosure () -> String = "", _ body: () throws -> T) rethrows -> T {
        guard signposter.isEnabled else { return try body() }
        let state = begin(name, detail: detail())
        defer { end(name, state) }
        return try body()
    }

    static func begin(_ name: StaticString, detail: String = "") -> OSSignpostIntervalState? {
        guard signposter.isEnabled else { return nil }
        let id = signposter.makeSignpostID()
        if detail.isEmpty {
            return signposter.beginInterval(name, id: id)
        }
        return signposter.beginInterval(name, id: id, "\(detail, privacy: .public)")
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState?) {
        guard let state else { return }
        signposter.endInterval(name, state)
    }
}

/// Persisted timeline of the sidebar click -> selection -> transcript reveal path.
/// Read back with `log show --predicate 'subsystem == "com.ntoporcov.openclient" AND category == "SessionSwitch"'`.
/// Off unless performance diagnostics are enabled, so shipped builds log nothing per click.
enum OpenClientSessionSwitchLog {
    private static let logger = Logger(subsystem: "com.ntoporcov.openclient", category: "SessionSwitch")
    private static let isEnabled = OpenClientMainThreadWatchdog.isEnabled

    static func log(_ message: @autoclosure () -> String) {
        guard isEnabled else { return }
        let message = message()
        logger.notice("\(message, privacy: .public)")
    }

    static func elapsedMS(since start: ContinuousClock.Instant) -> Int {
        Int(start.duration(to: .now) / .milliseconds(1))
    }
}

#if canImport(UIKit)
import UIKit

extension UIResponder {
    private static weak var openClientReportedFirstResponder: UIResponder?

    @objc private func openClientReportFirstResponder() {
        UIResponder.openClientReportedFirstResponder = self
    }

    /// The current first responder, found through the responder chain's action dispatch.
    static var openClientCurrentFirstResponder: UIResponder? {
        openClientReportedFirstResponder = nil
        UIApplication.shared.sendAction(#selector(openClientReportFirstResponder), to: nil, from: nil, for: nil)
        return openClientReportedFirstResponder
    }

    static var openClientFirstResponderDescription: String {
        openClientCurrentFirstResponder.map { String(describing: type(of: $0)) } ?? "none"
    }
}
#endif

/// Logs main-thread stalls so a day of normal use leaves a record that can be read
/// back with `log show --predicate 'subsystem == "com.ntoporcov.openclient" AND category == "Hangs"'`.
///
/// Enable with `defaults write com.ntoporcov.openclient OpenClientPerformanceDiagnosticsEnabled -bool YES`
/// or the `OPENCLIENT_PERF_DIAGNOSTICS=1` environment variable. Off, this does nothing.
final class OpenClientMainThreadWatchdog: @unchecked Sendable {
    static let shared = OpenClientMainThreadWatchdog()
    static let defaultsKey = "OpenClientPerformanceDiagnosticsEnabled"

    private static let logger = Logger(subsystem: "com.ntoporcov.openclient", category: "Hangs")
    private static let pingInterval: TimeInterval = 0.1
    private static let stallThresholdMilliseconds = 200

    private let lock = NSLock()
    private var isRunning = false

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: defaultsKey)
            || ProcessInfo.processInfo.environment["OPENCLIENT_PERF_DIAGNOSTICS"] == "1"
    }

    func startIfEnabled() {
        guard Self.isEnabled else { return }
        lock.lock()
        defer { lock.unlock() }
        guard !isRunning else { return }
        isRunning = true

        let thread = Thread {
            let logger = Self.logger
            let signposter = OpenClientPerformanceSignposts.signposter
            logger.notice("Main thread watchdog started (threshold \(Self.stallThresholdMilliseconds) ms)")
            while true {
                let semaphore = DispatchSemaphore(value: 0)
                let start = DispatchTime.now()
                DispatchQueue.main.async { semaphore.signal() }
                if semaphore.wait(timeout: .now() + .milliseconds(Self.stallThresholdMilliseconds)) == .timedOut {
                    let id = signposter.makeSignpostID()
                    let state = signposter.beginInterval("MainThreadStall", id: id)
                    semaphore.wait()
                    let elapsedMS = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
                    signposter.endInterval("MainThreadStall", state, "\(elapsedMS, format: .fixed(precision: 0)) ms")
                    logger.error("Main thread stalled for \(elapsedMS, format: .fixed(precision: 0), privacy: .public) ms")
                }
                Thread.sleep(forTimeInterval: Self.pingInterval)
            }
        }
        thread.name = "OpenClientMainThreadWatchdog"
        thread.qualityOfService = .utility
        thread.start()
    }
}
