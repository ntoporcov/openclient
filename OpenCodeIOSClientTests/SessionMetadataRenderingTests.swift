import XCTest
import SwiftUI
import UIKit
@testable import OpenClient

/// Deterministic presentation smoke tests: no server, credentials, or saved-state changes.
@MainActor
final class SessionMetadataRenderingTests: XCTestCase {
    func testOpenCodePerformanceUsesWeightedDecodeTimeAndExcludesIncompleteResponses() async {
        let messages = [
            response("fast", created: 1000, streamed: 1500, completed: 2500, output: 80, reasoning: 20),
            response("slow", created: 3000, streamed: 4000, completed: 8000, output: 100, reasoning: 0),
            response("running", created: 9000, streamed: 9200, completed: nil, output: 900, reasoning: 0)
        ]
        let metrics = OpenCodeSessionContextMetricsBuilder.metrics(messages: messages, providers: [])
        let performance = metrics.responseMetadataSections.first { $0.id == "performance" }
        XCTAssertEqual(performance?.rows.first { $0.id == "speed" }?.value, .decimal(40))
        XCTAssertEqual(performance?.rows.first { $0.id == "ttft" }?.value, .durationMilliseconds(750))
        XCTAssertEqual(performance?.rows.first { $0.id == "completed" }?.value, .integer(2))
        let latest = metrics.responseMetadataSections.first { $0.id == "last-response" }
        XCTAssertEqual(latest?.rows.first { $0.id == "speed" }?.value, .unavailable)
        await render(metrics: metrics, size: CGSize(width: 440, height: 956), name: "opencode-performance")
    }

    func testOpenCodeMissingOrInvalidTimingDoesNotInventSpeed() {
        let messages = [
            response("legacy", created: 1000, streamed: nil, completed: 2000, output: 100, reasoning: 10),
            response("zero", created: 1000, streamed: 2000, completed: 2000, output: 100, reasoning: 10),
            response("reversed", created: 1000, streamed: 3000, completed: 2000, output: 100, reasoning: 10)
        ]
        let sections = OpenCodeResponseMetadataBuilder.sections(messages: messages, providers: [])
        XCTAssertEqual(sections.first { $0.id == "performance" }?.rows.first { $0.id == "speed" }?.value, .unavailable)
        XCTAssertEqual(sections.first { $0.id == "last-response" }?.rows.first { $0.id == "speed" }?.value, .unavailable)
    }

    func testShellRecordsDoNotReplaceLatestModelResponse() {
        let model = response("model", created: 1000, streamed: 1200, completed: 2200, output: 40, reasoning: 10)
        let shell = OpenCodeMessageEnvelope(info: .init(id: "shell", role: "assistant", sessionID: "session",
                                                       time: .init(created: 3000, completed: 4000), agent: nil, model: nil), parts: [])
        let sections = OpenCodeResponseMetadataBuilder.sections(messages: [model, shell], providers: [])
        XCTAssertEqual(sections.first { $0.id == "last-response" }?.rows.first { $0.id == "id" }?.value, .text("model"))
        XCTAssertEqual(sections.first { $0.id == "performance" }?.rows.first { $0.id == "completed" }?.value, .integer(1))
    }

    private func response(_ id: String, created: Double, streamed: Double?, completed: Double?, output: Int, reasoning: Int) -> OpenCodeMessageEnvelope {
        .init(info: OpenCodeMessage(id: id, role: "assistant", sessionID: "session",
                                   time: .init(created: created, completed: completed, streamed: streamed),
                                   agent: nil, model: nil,
                                   tokens: .init(input: 1000, output: output, reasoning: reasoning, cache: .init(read: 500))), parts: [])
    }

    private func render(metrics: OpenCodeSessionContextMetrics, size: CGSize, name: String) async {
        let root = NavigationStack {
            Form {
                Section { SessionServerContextSummaryView(context: metrics.context) }
                SessionMetadataSectionsView(sections: metrics.responseMetadataSections)
            }
            .navigationTitle("Context")
            .navigationBarTitleDisplayMode(.inline)
        }
        .environment(\.locale, Locale(identifier: "en_US"))
        .preferredColorScheme(.light)
        let controller = UIHostingController(rootView: root)
        let window = UIWindow(frame: CGRect(origin: .zero, size: size))
        window.rootViewController = controller
        window.isHidden = false
        defer { window.isHidden = true; window.rootViewController = nil }
        controller.view.frame = window.bounds
        controller.view.setNeedsLayout()
        controller.view.layoutIfNeeded()
        await Task.yield()
        controller.view.layoutIfNeeded()
        let image = UIGraphicsImageRenderer(size: size).image { _ in
            controller.view.drawHierarchy(in: controller.view.bounds, afterScreenUpdates: true)
        }
        XCTAssertEqual(image.size, size)
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

}
