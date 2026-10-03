import Foundation

struct OpenCodeTurnFileDiff: Decodable, Identifiable, Hashable, Sendable {
    let file: String
    let patch: String
    let additions: Int
    let deletions: Int
    let status: String
    var id: String { file }
}

extension OpenCodeAPIClient {
    func v2TurnDiff(sessionID: String, promptID: String) async throws -> [OpenCodeTurnFileDiff] {
        struct Response: Decodable { let data: [OpenCodeTurnFileDiff] }
        let response: Response = try await send(path: "/api/session/\(sessionID)/diff", method: "GET",
            queryItems: [.init(name: "from", value: promptID)])
        return response.data
    }

    func moveV2Session(sessionID: String, directory: String) async throws {
        struct Move: Encodable { let directory: String; let delivery = "queue" }
        try await sendNoContent(path: "/api/session/\(sessionID)/move", method: "POST", queryItems: [], body: Move(directory: directory))
    }
}
