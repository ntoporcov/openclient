#if DEBUG || DSH_CLIENT
import Foundation

/// Opt-in composition for the native spike. Supply a tokenized DSH launch URL
/// through the process environment; never commit it into a scheme or source file.
@MainActor
struct DSHPrototypeFactory: BackendFactory {
    let launchURL: String

    static func fromEnvironment(_ environment: [String: String] = ProcessInfo.processInfo.environment) -> DSHPrototypeFactory? {
        environment["OPENCLIENT_DSH_URL"].map { .init(launchURL: $0) }
    }

    func connect() async throws -> BackendConnection {
        guard let url = URL(string: launchURL) else { throw URLError(.badURL) }
        return try await DSHBackendFactory(configuration: DSHConfiguration(url: url)).connect()
    }
}
#endif
