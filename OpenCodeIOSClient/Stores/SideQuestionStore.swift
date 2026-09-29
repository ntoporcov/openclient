import Combine
import Foundation

/// Transient, sheet-local output. Never participates in the session transcript or inbox.
@MainActor
final class SideQuestionStore: ObservableObject {
    struct Request: Identifiable {
        let id = UUID()
        let prompt: String
    }

    @Published var prompt: String
    @Published private(set) var request: Request?
    @Published private(set) var answer: String?
    @Published private(set) var errorMessage: String?

    init(prompt: String = "") {
        self.prompt = prompt
    }

    var isGenerating: Bool { request != nil }
    var canAsk: Bool { !isGenerating && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    func ask() {
        guard canAsk else { return }
        answer = nil
        errorMessage = nil
        request = Request(prompt: prompt.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func complete(_ text: String, requestID: UUID) {
        guard request?.id == requestID else { return }
        answer = text
        request = nil
    }

    func fail(_ message: String, requestID: UUID) {
        guard request?.id == requestID else { return }
        errorMessage = message
        request = nil
    }

    func cancel(requestID: UUID? = nil) {
        if let requestID, request?.id != requestID { return }
        request = nil
    }
}
