import Foundation

struct OpenCodeServerConfig: Equatable, Codable {
    var baseURL: String = "http://127.0.0.1:4096"
    var username: String = "opencode"
    var password: String = ""

    var sanitizedBaseURL: URL? {
        URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var trimmedBaseURL: String {
        baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasCredentials: Bool {
        !trimmedBaseURL.isEmpty && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
