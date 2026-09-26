import Foundation
import XCTest

struct OpenCodeV2LiveFixture {
    static let version = "2.0.16"
    static let baseURL = "http://127.0.0.1:14097"

    let root: URL
    let workspace: URL
    let gitRoot: URL
    let worktreeDestinationParent: URL
    let providerURL: URL
    let username: String
    let password: String
    let controlToken: String

    static func load() throws -> Self {
        guard let path = ProcessInfo.processInfo.environment["OPENCODE_V2_TEST_MANIFEST_PATH"], !path.isEmpty else {
            throw XCTSkip("Set TEST_RUNNER_OPENCODE_V2_TEST_MANIFEST_PATH to a running scripts/acceptance fixture")
        }
        guard let hostRootPath = ProcessInfo.processInfo.environment["OPENCODE_V2_TEST_HOST_ROOT"],
              hostRootPath.hasPrefix("/") else {
            throw OpenCodeV2LiveFixtureError("Explicit v2 fixture host root required")
        }
        let manifestURL = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
        let root = manifestURL.deletingLastPathComponent().standardizedFileURL
        let approvedParent = URL(fileURLWithPath: hostRootPath)
            .resolvingSymlinksInPath().standardizedFileURL
        guard manifestURL.lastPathComponent == "manifest.json",
              root.deletingLastPathComponent().path == approvedParent.path,
              root.lastPathComponent.hasPrefix("acceptance-v2_0_16-") else {
            throw OpenCodeV2LiveFixtureError("Unapproved v2 fixture manifest location")
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: manifestURL.path)
        guard (attributes[.posixPermissions] as? Int ?? 0) & 0o077 == 0 else {
            throw OpenCodeV2LiveFixtureError("V2 fixture manifest must be private")
        }
        let value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        let runID = try XCTUnwrap(value["run_id"] as? String)
        let marker = try String(contentsOf: root.appendingPathComponent(".acceptance-root"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let workspace = URL(fileURLWithPath: try XCTUnwrap(value["workspace"] as? String)).resolvingSymlinksInPath()
        let gitRoot = URL(fileURLWithPath: try XCTUnwrap(value["git_root"] as? String)).resolvingSymlinksInPath()
        let destination = URL(fileURLWithPath: try XCTUnwrap(value["worktree_destination_parent"] as? String)).resolvingSymlinksInPath()
        let providerURL = try XCTUnwrap(URL(string: try XCTUnwrap(value["provider_url"] as? String)))
        let manifestHostRoot = canonicalPath(try XCTUnwrap(value["host_root"] as? String))
        guard marker == runID,
              manifestHostRoot == approvedParent.path,
              value["version"] as? String == version,
              value["base_url"] as? String == baseURL,
              providerURL.absoluteString == "http://127.0.0.1:14098",
              workspace.path == canonicalPath(root.appendingPathComponent("workspace").path),
              gitRoot.path == canonicalPath(root.appendingPathComponent("git-fixture").path),
              destination.path == canonicalPath(root.appendingPathComponent("copies").path) else {
            throw OpenCodeV2LiveFixtureError("V2 fixture manifest identity rejected")
        }
        let username = try XCTUnwrap(value["username"] as? String)
        let password = try XCTUnwrap(value["password"] as? String)
        let controlToken = try XCTUnwrap(value["control_token"] as? String)
        guard !username.isEmpty, !password.isEmpty, !controlToken.isEmpty else {
            throw OpenCodeV2LiveFixtureError("V2 fixture credentials are incomplete")
        }
        return .init(root: root, workspace: workspace, gitRoot: gitRoot,
                      worktreeDestinationParent: destination,
                      providerURL: providerURL,
                      username: username, password: password, controlToken: controlToken)
    }

    func owns(_ url: URL) -> Bool {
        let normalized = url.resolvingSymlinksInPath().standardizedFileURL.path
        return normalized == root.path || normalized.hasPrefix(root.path + "/")
    }

    private static func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

private struct OpenCodeV2LiveFixtureError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}
