import SwiftUI

struct OpenClientPaywallView: View {
    @ObservedObject var viewModel: AppViewModel
    @ObservedObject var purchaseManager: OpenClientPurchaseManager
    let reason: OpenClientPaywallReason

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer(minLength: 12)

                Image(systemName: "sparkles.rectangle.stack.fill")
                    .font(.system(size: 52, weight: .semibold))
                    .foregroundStyle(.tint)

                VStack(spacing: 10) {
                    Text(reason.title)
                        .font(.title2.weight(.bold))
                        .multilineTextAlignment(.center)

                    Text(reason.message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(alignment: .leading, spacing: 12) {
                    Label("Unlimited prompts", systemImage: "paperplane.fill")
                    Label("Unlimited sessions", systemImage: "bubble.left.and.bubble.right.fill")
                    Label("Supports the open-source app", systemImage: "heart.fill")
                }
                .font(.subheadline.weight(.medium))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(18)
                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))

                VStack(spacing: 10) {
                    Button {
                        Task { await viewModel.purchaseProUnlock() }
                    } label: {
                        Text(purchaseButtonTitle)
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                    Button("Restore Purchases") {
                        Task { await viewModel.restoreProUnlock() }
                    }
                    .font(.subheadline.weight(.medium))

                    if !isScreenshotScene, let error = purchaseManager.purchaseError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }
                }

#if DEBUG
                if !isScreenshotScene {
                    OpenClientDebugEntitlementControls(viewModel: viewModel)
                        .padding(.top, 4)
                }
#endif

                Spacer(minLength: 0)
            }
            .padding(24)
            .navigationTitle("OpenClient Pro")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Done") {
                        viewModel.paywallReason = nil
                    }
                }
            }
            .onChange(of: purchaseManager.hasProUnlock) { _, unlocked in
                if unlocked {
                    viewModel.paywallReason = nil
                }
            }
        }
    }

    private var purchaseButtonTitle: String {
        if isScreenshotScene {
            return "Unlock for $9.99"
        }
        if purchaseManager.isLoadingProducts {
            return "Loading..."
        }
        if let price = purchaseManager.proProduct?.displayPrice {
            return "Unlock for \(price)"
        }
        return "Unlock Pro"
    }

    private var isScreenshotScene: Bool {
        ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] == "paywall"
    }

}
