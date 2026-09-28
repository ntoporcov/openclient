import SwiftUI

struct OpenClientVisualImageLoadingID: Hashable, Sendable {
    let sessionID: String
    let messageID: String
    let partID: String
}

struct OpenClientVisualImageActivity: Equatable {
    let id: OpenClientVisualImageLoadingID
    let payload: OpenClientVisualImagePayload

    init(payload: OpenClientVisualImagePayload) {
        id = OpenClientVisualImageLoadingID(
            sessionID: "preview",
            messageID: "preview",
            partID: payload.resourceID
        )
        self.payload = payload
    }

    init?(part: OpenCodePart, sessionID: String? = nil, messageID: String? = nil) {
        guard part.type == "tool",
              part.tool == "openclient_execute_tool",
              let state = part.state,
              state.input?.toolID == OpenClientVisualImageContract.toolID,
              state.metadata?.renderer == OpenClientVisualImageContract.rendererID,
              let payloadValue = state.metadata?.payload,
              let data = try? JSONEncoder().encode(payloadValue),
              let decoded = try? JSONDecoder().decode(OpenClientVisualImagePayload.self, from: data),
              let payload = try? decoded.validated() else {
            return nil
        }

        id = OpenClientVisualImageLoadingID(
            sessionID: part.sessionID ?? sessionID ?? "unknown-session",
            messageID: part.messageID ?? messageID ?? "unknown-message",
            partID: part.id?.openClientNilIfBlank ?? part.callID?.openClientNilIfBlank ?? payload.resourceID
        )
        self.payload = payload
    }
}

struct OpenClientVisualImageView: View {
    let activity: OpenClientVisualImageActivity
    @ObservedObject var loading: OpenClientVisualImageLoadingController
    let coordinator: OpenClientImageContentCoordinator?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            OpenClientVisualImageHeader(payload: activity.payload)
                .padding(12)
            Divider()

            switch loading.phase {
            case .idle:
                Button {
                    loading.load(activity: activity, coordinator: coordinator)
                } label: {
                    OpenClientVisualImagePreview(
                        payload: activity.payload,
                        mode: .idle,
                        onRetry: {}
                    )
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Load \(activity.payload.displayTitle)")
            case .loading:
                OpenClientVisualImagePreview(
                    payload: activity.payload,
                    mode: .loading,
                    onRetry: {}
                )
            case .loaded(let image):
                OpenClientAdaptiveMediaLayout(aspectRatio: activity.payload.displayAspectRatio) {
                    openClientPlatformImage(image.platformImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityLabel(activity.payload.accessibilityLabel ?? activity.payload.displayTitle)
                        .accessibilityIdentifier("chat.tool.visual-image.content")
                }
            case .failed(let message):
                OpenClientVisualImagePreview(
                    payload: activity.payload,
                    mode: .failed(message),
                    onRetry: {
                        loading.retry(coordinator: coordinator)
                    }
                )
            }
        }
        .background(OpenCodePlatformColor.secondaryGroupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.quaternary, lineWidth: 0.5)
        }
        .accessibilityIdentifier("chat.tool.visual-image")
    }
}

@MainActor
final class OpenClientImageLoadingStore {
    private static let controllerLimit = 8
    private var controllers: [OpenClientVisualImageLoadingID: OpenClientVisualImageLoadingController] = [:]
    private var controllerRecency: [OpenClientVisualImageLoadingID] = []

    func controller(for activity: OpenClientVisualImageActivity) -> OpenClientVisualImageLoadingController {
        if let controller = controllers[activity.id] {
            markRecentlyUsed(activity.id)
            controller.adopt(payload: activity.payload)
            return controller
        }
        let controller = OpenClientVisualImageLoadingController(id: activity.id, payload: activity.payload)
        controllers[activity.id] = controller
        markRecentlyUsed(activity.id)
        while controllers.count > Self.controllerLimit, let evictedID = controllerRecency.first {
            controllerRecency.removeFirst()
            controllers.removeValue(forKey: evictedID)?.cancel()
        }
        return controller
    }

    func cancelAll() {
        controllers.values.forEach { $0.cancel() }
        controllers.removeAll()
        controllerRecency.removeAll()
    }

    private func markRecentlyUsed(_ id: OpenClientVisualImageLoadingID) {
        controllerRecency.removeAll { $0 == id }
        controllerRecency.append(id)
    }
}

@MainActor
final class OpenClientVisualImageLoadingController: ObservableObject {
    enum Phase: Equatable {
        case idle
        case loading
        case loaded(OpenClientLoadedImage)
        case failed(String)
    }

    let id: OpenClientVisualImageLoadingID
    @Published private(set) var phase: Phase

    private var payload: OpenClientVisualImagePayload
    private var coordinator: OpenClientImageContentCoordinator?
    private var task: Task<Void, Never>?

    init(
        id: OpenClientVisualImageLoadingID,
        payload: OpenClientVisualImagePayload,
        initialImage: OpenClientLoadedImage? = nil
    ) {
        self.id = id
        self.payload = payload
        phase = initialImage.map(Phase.loaded) ?? .idle
    }

    func adopt(payload: OpenClientVisualImagePayload) {
        guard self.payload.resourceID != payload.resourceID else {
            self.payload = payload
            return
        }
        cancel()
        self.payload = payload
    }

    func load(activity: OpenClientVisualImageActivity, coordinator: OpenClientImageContentCoordinator?) {
        adopt(payload: activity.payload)
        self.coordinator = coordinator
        beginLoading()
    }

    func retry(coordinator: OpenClientImageContentCoordinator?) {
        self.coordinator = coordinator
        beginLoading()
    }

    func cancel() {
        task?.cancel()
        task = nil
        phase = .idle
    }

    private func beginLoading() {
        task?.cancel()
        guard let coordinator else {
            phase = .failed(OpenClientImageContentError.unavailable.localizedDescription)
            return
        }

        let payload = payload
        phase = .loading
        task = Task { @MainActor [weak self] in
            do {
                let image = try await coordinator.load(payload: payload)
                try Task.checkCancellation()
                guard self?.payload.resourceID == payload.resourceID else { return }
                self?.phase = .loaded(image)
            } catch is CancellationError {
                return
            } catch {
                guard self?.payload.resourceID == payload.resourceID else { return }
                self?.phase = .failed(error.localizedDescription)
            }
        }
    }
}

func openClientPlatformImage(_ image: OpenClientPlatformImage) -> Image {
    #if canImport(UIKit)
    Image(uiImage: image)
    #elseif canImport(AppKit)
    Image(nsImage: image)
    #endif
}

struct OpenClientAdaptiveMediaLayout: Layout {
    let aspectRatio: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 320
        let naturalHeight = width / max(0.1, aspectRatio)
        return CGSize(width: width, height: min(naturalHeight, 560))
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        subviews.first?.place(at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(bounds.size))
    }
}

private struct OpenClientVisualImagePreview: View {
    enum Mode {
        case idle
        case loading
        case failed(String)
    }

    let payload: OpenClientVisualImagePayload
    let mode: Mode
    let onRetry: () -> Void

    var body: some View {
        OpenClientAdaptiveMediaLayout(aspectRatio: payload.displayAspectRatio) {
            ZStack {
                OpenCodePlatformColor.secondaryGroupedBackground

                openClientPlatformImage(payload.preview.platformImage)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .blur(radius: 7)
                    .scaleEffect(1.04)
                    .clipped()

                Color.black.opacity(overlayOpacity)

                OpenClientVisualImagePreviewOverlay(mode: mode, onRetry: onRetry)
                    .padding(16)
            }
            .clipped()
        }
    }

    private var overlayOpacity: Double {
        switch mode {
        case .idle:
            0.18
        case .loading:
            0.36
        case .failed:
            0.5
        }
    }
}

private struct OpenClientVisualImagePreviewOverlay: View {
    let mode: OpenClientVisualImagePreview.Mode
    let onRetry: () -> Void

    @ViewBuilder
    var body: some View {
        switch mode {
        case .idle:
            Label("Load", systemImage: "arrow.down.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 18)
                .padding(.vertical, 11)
                .background(.indigo, in: Capsule())
        case .loading:
            VStack(spacing: 10) {
                ProgressView()
                    .tint(.white)
                Text("Loading Image")
                    .font(.subheadline.weight(.semibold))
                Text("Fetching the original from the OpenCode host")
                    .font(.caption)
                    .multilineTextAlignment(.center)
            }
            .foregroundStyle(.white)
        case .failed(let message):
            VStack(spacing: 10) {
                Label("Image Unavailable", systemImage: "exclamationmark.triangle")
                    .font(.subheadline.weight(.semibold))
                Text(message)
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .modifier(AppAccentActionModifier())
                    .controlSize(.small)
            }
            .foregroundStyle(.white)
        }
    }
}

private struct OpenClientVisualImageHeader: View {
    let payload: OpenClientVisualImagePayload

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "photo.fill")
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(.indigo)
                .frame(width: 38, height: 38)
                .background(.indigo.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(payload.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
                Text("\(payload.file.name) · \(payload.file.sizeBytes.formatted(.byteCount(style: .file)))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 8)
        }
    }
}

private extension String {
    var openClientNilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
