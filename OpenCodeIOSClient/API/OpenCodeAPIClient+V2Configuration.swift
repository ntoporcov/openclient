import Foundation

private struct V2ConfigurationResponse<Value: Decodable & Sendable>: Decodable, Sendable {
    let location: OpenCodeV2ResponseLocation
    let data: Value
}

extension OpenCodeAPIClient {
    func v2Integrations(directory: String?, workspaceID: String? = nil) async throws -> [OpenCodeV2Integration] {
        let response: V2ConfigurationResponse<[OpenCodeV2Integration]> = try await send(
            path: "/api/integration", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data
    }

    func v2Plugins(directory: String?, workspaceID: String? = nil) async throws -> [OpenCodeV2Plugin] {
        let response: V2ConfigurationResponse<[OpenCodeV2Plugin]> = try await send(
            path: "/api/plugin", method: "GET", queryItems: v2LocationQueryItems(directory: directory, workspaceID: workspaceID))
        return response.data
    }

    func v2ConnectKey(integrationID: String, key: String, answer: [String: OpenCodeJSONValue], directory: String?) async throws {
        struct Body: Encodable { let key: String; let answer: [String: OpenCodeJSONValue]? }
        try await sendNoContent(path: "/api/integration/\(try v2ConfigurationID(integrationID))/connect/key", method: "POST",
                                queryItems: v2LocationQueryItems(directory: directory), body: Body(key: key, answer: answer.isEmpty ? nil : answer))
    }

    func v2BeginOAuth(integrationID: String, methodID: String, answer: [String: OpenCodeJSONValue], directory: String?) async throws -> OpenCodeV2OAuthAttempt {
        struct Body: Encodable { let methodID: String; let answer: [String: OpenCodeJSONValue]? }
        let response: V2ConfigurationResponse<OpenCodeV2OAuthAttempt> = try await send(
            path: "/api/integration/\(try v2ConfigurationID(integrationID))/connect/oauth", method: "POST",
            queryItems: v2LocationQueryItems(directory: directory), body: Body(methodID: methodID, answer: answer.isEmpty ? nil : answer))
        return response.data
    }

    func v2OAuthStatus(integrationID: String, attemptID: String, directory: String?) async throws -> OpenCodeV2OAuthStatus {
        let response: V2ConfigurationResponse<OpenCodeV2OAuthStatus> = try await send(
            path: "/api/integration/\(try v2ConfigurationID(integrationID))/connect/oauth/\(try v2ConfigurationID(attemptID))", method: "GET",
            queryItems: v2LocationQueryItems(directory: directory))
        return response.data
    }

    func v2CompleteOAuth(integrationID: String, attemptID: String, code: String, directory: String?) async throws {
        struct Body: Encodable { let code: String }
        try await sendNoContent(
            path: "/api/integration/\(try v2ConfigurationID(integrationID))/connect/oauth/\(try v2ConfigurationID(attemptID))/complete", method: "POST",
            queryItems: v2LocationQueryItems(directory: directory), body: Body(code: code))
    }

    func v2CancelOAuth(integrationID: String, attemptID: String, directory: String?) async throws {
        try await sendNoContent(
            path: "/api/integration/\(try v2ConfigurationID(integrationID))/connect/oauth/\(try v2ConfigurationID(attemptID))", method: "DELETE",
            queryItems: v2LocationQueryItems(directory: directory), directoryHeader: nil)
    }

    func v2RemoveCredential(credentialID: String, directory: String?) async throws {
        try await sendNoContent(path: "/api/credential/\(try v2ConfigurationID(credentialID))", method: "DELETE",
                                queryItems: v2LocationQueryItems(directory: directory), directoryHeader: nil)
    }

    private func v2ConfigurationID(_ id: String) throws -> String {
        // The shared URL builder escapes path text. Never pre-escape it (which double-encodes %).
        guard !id.isEmpty, id != ".", id != "..", !id.contains("/"), !id.contains("\\"),
              id.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw OpenCodeV2ConfigurationError.invalidIdentifier
        }
        return id
    }
}
