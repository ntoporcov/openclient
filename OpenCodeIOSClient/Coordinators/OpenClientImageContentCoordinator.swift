import Foundation
import Observation

@MainActor @Observable
final class TranscriptReadImageLoader {
    private(set) var asset: TranscriptImageAsset?
    var image: OpenClientDecodedPlatformImage? { asset?.image }
    private(set) var error: String?

    func load(path: String, using load: (String) async throws -> Data) async {
        guard image == nil else { return }
        error = nil
        do {
            let data = try await load(path)
            let decoded = await Task.detached(priority: .utility) {
                TranscriptImageAsset(data: data, path: path)
            }.value
            try Task.checkCancellation()
            guard let decoded else { throw OpenCodeAPIError.invalidResponse }
            asset = decoded
        } catch is CancellationError {
            return
        } catch {
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class OpenClientImageContentCoordinator {
    private let bridgeStore: OpenClientBridgeStore
    private let transport: any OpenClientImageContentTransport

    init(
        bridgeStore: OpenClientBridgeStore,
        transport: any OpenClientImageContentTransport = OpenClientImageContentClient()
    ) {
        self.bridgeStore = bridgeStore
        self.transport = transport
    }

    func load(payload: OpenClientVisualImagePayload) async throws -> OpenClientLoadedImage {
        guard case .connected = bridgeStore.phase,
              let endpoint = bridgeStore.endpoint else {
            throw OpenClientImageContentError.unavailable
        }
        return try await transport.load(payload: payload, endpoint: endpoint)
    }
}
