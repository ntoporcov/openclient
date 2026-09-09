import Foundation

private struct OpenCodeV2PTYResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let location: OpenCodeV2Location
    let data: Value
}

extension OpenCodeAPIClient {
    func listV2PTYs(directory: String, workspaceID: String? = nil) async throws -> [OpenCodePTY] {
        let response: OpenCodeV2PTYResponse<[OpenCodePTY]> = try await send(
            path: "/api/pty", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID)
        )
        return response.data
    }

    func createV2PTY(title: String? = nil, directory: String, workspaceID: String? = nil) async throws -> OpenCodePTY {
        let response: OpenCodeV2PTYResponse<OpenCodePTY> = try await send(
            path: "/api/pty", method: "POST",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID),
            body: OpenCodePTYCreateRequest(title: title)
        )
        return response.data
    }

    func getV2PTY(id: String, directory: String, workspaceID: String? = nil) async throws -> OpenCodePTY {
        let response: OpenCodeV2PTYResponse<OpenCodePTY> = try await send(
            path: "/api/pty/\(id)", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID)
        )
        return response.data
    }

    func updateV2PTY(
        id: String, title: String? = nil, rows: Int? = nil, columns: Int? = nil,
        directory: String, workspaceID: String? = nil
    ) async throws -> OpenCodePTY {
        let response: OpenCodeV2PTYResponse<OpenCodePTY> = try await send(
            path: "/api/pty/\(id)", method: "PUT",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID),
            body: OpenCodePTYUpdateRequest(title: title, rows: rows, columns: columns)
        )
        return response.data
    }

    func deleteV2PTY(id: String, directory: String, workspaceID: String? = nil) async throws {
        try await sendNoContent(
            path: "/api/pty/\(id)", method: "DELETE",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID),
            directoryHeader: directory
        )
    }

    func v2PTYConnectRequest(
        id: String, directory: String, workspaceID: String? = nil, cursor: Int
    ) throws -> URLRequest {
        var request = try makeRequest(
            path: "/api/pty/\(id)/connect", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID)
                + [URLQueryItem(name: "cursor", value: String(cursor))],
            directoryHeader: directory, logRequest: false
        )
        guard let url = request.url,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw OpenCodeAPIError.invalidURL
        }
        switch components.scheme?.lowercased() {
        case "https": components.scheme = "wss"
        case "http": components.scheme = "ws"
        default: throw OpenCodeAPIError.invalidURL
        }
        guard let url = components.url else { throw OpenCodeAPIError.invalidURL }
        // URLSession supports Basic headers on upgrades; browser tickets are unnecessary here.
        request.url = url
        return request
    }
}
