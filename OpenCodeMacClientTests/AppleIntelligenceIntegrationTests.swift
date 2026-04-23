import XCTest
import Foundation

#if canImport(FoundationModels)
import FoundationModels
@testable import OpenCodeMacClient

@MainActor
@available(macOS 26.0, *)
final class AppleIntelligenceIntegrationTests: XCTestCase {
    private func makeTempWorkspace(named name: String = UUID().uuidString) throws -> (url: URL, workspace: AppleIntelligenceWorkspaceRecord) {
        let rootURL = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: rootURL, withIntermediateDirectories: true)

        let workspace = AppleIntelligenceWorkspaceRecord(
            id: "apple-workspace:test",
            title: "Test Workspace",
            bookmarkData: Data(),
            lastKnownPath: rootURL.path(percentEncoded: false),
            sessionID: "apple-session:test",
            messages: [],
            updatedAt: Date()
        )
        return (rootURL, workspace)
    }

    private func requireAvailableModel(file: StaticString = #filePath, line: UInt = #line) throws -> SystemLanguageModel {
        guard #available(macOS 26.0, *) else {
            throw XCTSkip("Foundation Models requires macOS 26 or later.")
        }

        let model = SystemLanguageModel.default
        guard model.isAvailable else {
            throw XCTSkip("Apple Intelligence is not available on this Mac right now.")
        }

        guard model.supportsLocale(Locale.current) else {
            throw XCTSkip("Apple Intelligence does not support the current locale: \(Locale.current.identifier)")
        }

        return model
    }

    func testDirectLanguageModelResponds() async throws {
        let model = try requireAvailableModel()
        let systemInstructions = "Reply briefly and directly."
        let userPrompt = "Say hello in 1 to 3 words."

        let session = LanguageModelSession(model: model) {
            systemInstructions
        }

        let response = try await session.respond(to: userPrompt)
        let responseText = response.content.trimmingCharacters(in: .whitespacesAndNewlines)

        print("""
        APPLE_INTELLIGENCE_TEST_TRANSCRIPT_START
        test: testDirectLanguageModelResponds
        system:
        \(systemInstructions)
        user:
        \(userPrompt)
        assistant:
        \(responseText)
        APPLE_INTELLIGENCE_TEST_TRANSCRIPT_END
        """)

        XCTAssertFalse(responseText.isEmpty)
    }

    func testIntentInferenceClassifiesGreetingAsChat() async throws {
        _ = try requireAvailableModel()
        let userPrompt = "Hey"

        let viewModel = AppViewModel()
        let workspace = try makeTempWorkspace().workspace

        let intent = try await viewModel.inferAppleIntelligenceIntent(
            currentText: userPrompt,
            attachments: [],
            priorMessages: [],
            workspace: workspace
        )

        print("""
        APPLE_INTELLIGENCE_TEST_TRANSCRIPT_START
        test: testIntentInferenceClassifiesGreetingAsChat
        user:
        \(userPrompt)
        classifier:
        \(intent.label)
        APPLE_INTELLIGENCE_TEST_TRANSCRIPT_END
        """)

        XCTAssertEqual(intent, .chat)
    }

    func testTwoRoundPipelineReadsWorkspaceFile() async throws {
        _ = try requireAvailableModel()

        let viewModel = AppViewModel()
        let (rootURL, workspace) = try makeTempWorkspace(named: "ai-two-round-\(UUID().uuidString)")
        let fileURL = rootURL.appendingPathComponent("hello.txt")
        try "Hello from the workspace\nSecond line".write(to: fileURL, atomically: true, encoding: .utf8)

        let userPrompt = "Read hello.txt and tell me its first line."
        let initialContext = viewModel.appleIntelligenceInitialContext(for: rootURL)
        let intent = try await viewModel.inferAppleIntelligenceIntent(
            currentText: userPrompt,
            attachments: [],
            priorMessages: [],
            workspace: workspace
        )
        let executionPrompt = viewModel.appleIntelligenceExecutionPrompt(
            intent: intent,
            currentText: userPrompt,
            attachments: [],
            priorMessages: [],
            workspace: workspace,
            initialContext: initialContext
        )

        var finalResponse = ""
        for try await snapshot in try viewModel.makeAppleIntelligenceResponseStream(
            intent: intent,
            prompt: executionPrompt,
            rootURL: rootURL
        ) {
            finalResponse = snapshot.content.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        print("""
        APPLE_INTELLIGENCE_TEST_TRANSCRIPT_START
        test: testTwoRoundPipelineReadsWorkspaceFile
        user:
        \(userPrompt)
        classifier:
        \(intent.label)
        execution_prompt:
        \(executionPrompt)
        assistant:
        \(finalResponse)
        APPLE_INTELLIGENCE_TEST_TRANSCRIPT_END
        """)

        XCTAssertEqual(intent, .readFile)
        XCTAssertTrue(finalResponse.localizedCaseInsensitiveContains("Hello from the workspace"))
    }
}
#endif
