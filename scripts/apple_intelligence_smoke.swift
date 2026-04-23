import Foundation

#if canImport(FoundationModels)
import FoundationModels

enum SmokeFailure: Error, CustomStringConvertible {
    case unavailable
    case unsupportedLocale(String)
    case emptyResponse
    case badClassification(String)

    var description: String {
        switch self {
        case .unavailable:
            return "Apple Intelligence is not available in this process."
        case let .unsupportedLocale(locale):
            return "Apple Intelligence does not support locale: \(locale)"
        case .emptyResponse:
            return "Model returned an empty response."
        case let .badClassification(label):
            return "Intent classifier returned unexpected label: \(label)"
        }
    }
}

@available(macOS 26.0, *)
func runSmokeTests() async throws {
    let model = SystemLanguageModel.default
    guard model.isAvailable else {
        throw SmokeFailure.unavailable
    }

    let locale = Locale.current.identifier
    guard model.supportsLocale(Locale.current) else {
        throw SmokeFailure.unsupportedLocale(locale)
    }

    let chatSession = LanguageModelSession(model: model) {
        "Reply briefly and directly."
    }
    let chatResponse = try await chatSession.respond(to: "Say hello in 1 to 3 words.")
    let chatText = chatResponse.content.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !chatText.isEmpty else {
        throw SmokeFailure.emptyResponse
    }

    let classifierSession = LanguageModelSession(model: model) {
        "Return exactly one label from: chat, list_directory, read_file, search_files, write_file, clarify."
    }
    let classifierResponse = try await classifierSession.respond(
        to: "Classify this user request: 'Hey'. Return only the label."
    )
    let label = classifierResponse.content.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard label == "chat" else {
        throw SmokeFailure.badClassification(label)
    }

    print("PASS chat_response=\(chatText)")
    print("PASS classification=\(label)")
}

@main
struct AppleIntelligenceSmokeMain {
    static func main() async {
        guard #available(macOS 26.0, *) else {
            print("SKIP unsupported-os")
            exit(0)
        }

        do {
            try await runSmokeTests()
        } catch let failure as SmokeFailure {
            print("SKIP \(failure.description)")
            exit(0)
        } catch {
            print("FAIL \(error.localizedDescription)")
            exit(1)
        }
    }
}
#else
@main
struct AppleIntelligenceSmokeMain {
    static func main() {
        print("SKIP FoundationModels unavailable")
    }
}
#endif
