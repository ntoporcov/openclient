import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct OpenClientPaywallView: View {
    @ObservedObject var commerce: CommerceFacade
    let reason: OpenClientPaywallReason

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 22) {
                    PaywallAppIcon()

                    PaywallHeader(title: reasonTitle, message: reasonMessage)

                    PaywallBenefits()

                    PaywallPurchaseOptions(
                        lifetimePrice: lifetimePrice,
                        monthlyPrice: monthlyPrice,
                        isPurchasing: purchaseControlsAreDisabled,
                        showsLaunchPricingNotice: isScreenshotScene || OpenClientCommercePricing.isLifetimeLaunchPriceActive(),
                        purchaseLifetime: { Task { await commerce.purchasePro(.lifetime) } },
                        purchaseMonthly: { Task { await commerce.purchasePro(.monthly) } }
                    )

                    Button("Restore Purchases") {
                        Task { await commerce.restorePurchases() }
                    }
                    .font(.subheadline.weight(.medium))
                    .disabled(purchaseControlsAreDisabled)

                    PaywallSubscriptionDisclosure(
                        hasActiveMonthlySubscription: !isScreenshotScene && commerce.storeKitHasProMonthlyUnlock
                    )

                    if !isScreenshotScene, let error = commerce.purchaseError {
                        Text(error)
                            .font(.footnote)
                            .foregroundStyle(.red)
                            .multilineTextAlignment(.center)
                    }

#if DEBUG
                    if !isScreenshotScene {
                        OpenClientDebugEntitlementControls(commerce: commerce)
                            .padding(.top, 4)
                    }
#endif
                }
                .frame(maxWidth: 560)
                .padding(24)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle("OpenClient Pro")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Done") {
                        commerce.dismissPaywall()
                    }
                }
            }
            .onChange(of: commerce.storeKitHasProUnlock) { _, unlocked in
                if unlocked {
                    commerce.dismissPaywall()
                }
            }
            .onChange(of: commerce.storeKitHasProLifetimeUnlock) { _, unlocked in
                if unlocked, !commerce.storeKitHasProMonthlyUnlock {
                    commerce.dismissPaywall()
                }
            }
        }
    }

    private var lifetimePrice: String {
        if isScreenshotScene {
            return "$19.99"
        }
        if commerce.isLoadingProducts {
            return String(localized: "Loading...")
        }
        return commerce.proLifetimeDisplayPrice ?? String(localized: "Unavailable")
    }

    private var monthlyPrice: String {
        if isScreenshotScene {
            return "$4.99"
        }
        if commerce.isLoadingProducts {
            return String(localized: "Loading...")
        }
        return commerce.proMonthlyDisplayPrice ?? String(localized: "Unavailable")
    }

    private var isScreenshotScene: Bool {
        ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] == "paywall"
    }

    private var purchaseControlsAreDisabled: Bool {
        !isScreenshotScene && commerce.isPurchaseOperationInProgress
    }

    private var reasonTitle: LocalizedStringResource {
        switch reason {
        case .promptLimit: "Daily Prompt Limit Reached"
        case .sessionLimit: "Create Unlimited Sessions"
        case .actions: "Unlock Actions"
        case .manual: "OpenClient Pro"
        }
    }

    private var reasonMessage: LocalizedStringResource {
        switch reason {
        case .promptLimit:
            "Upgrade to send unlimited prompts and support continued development of the open-source app."
        case .sessionLimit:
            "Free users can create one session. Upgrade for unlimited sessions and prompts."
        case .actions:
            "Actions run project commands in temporary sessions and only surface when they need your attention."
        case .manual:
            "Unlock unlimited prompts and sessions, plus support the signed App Store build."
        }
    }

}

private struct PaywallHeader: View {
    let title: LocalizedStringResource
    let message: LocalizedStringResource

    var body: some View {
        VStack(spacing: 10) {
            Text(title)
                .font(.title2.weight(.bold))
                .multilineTextAlignment(.center)

            Text(message)
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}

private struct PaywallBenefits: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            PaywallBenefitRow(
                title: "Unlimited prompts",
                systemImage: "paperplane.fill",
                tint: .blue
            )
            PaywallBenefitRow(
                title: "Unlimited sessions",
                systemImage: "bubble.left.and.bubble.right.fill",
                tint: .purple
            )
            PaywallBenefitRow(
                title: "Project Actions",
                systemImage: "bolt.fill",
                tint: .orange
            )
            PaywallBenefitRow(
                title: "Supports the open-source app",
                systemImage: "heart.fill",
                tint: .pink
            )
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct PaywallPurchaseOptions: View {
    let lifetimePrice: String
    let monthlyPrice: String
    let isPurchasing: Bool
    let showsLaunchPricingNotice: Bool
    let purchaseLifetime: () -> Void
    let purchaseMonthly: () -> Void

    var body: some View {
        VStack(spacing: 10) {
            PaywallPurchaseOptionButton(
                title: "Pro Lifetime",
                detail: "One-time purchase + Pro Life icon",
                price: lifetimePrice,
                badge: "BEST VALUE",
                isProminent: true,
                action: purchaseLifetime
            )

            PaywallPurchaseOptionButton(
                title: "Pro Monthly",
                detail: "Renews monthly",
                price: monthlyPrice,
                badge: nil,
                isProminent: false,
                action: purchaseMonthly
            )

            if showsLaunchPricingNotice {
                Text("Lifetime launch price increases September 30. The regular price is US$29.99 or the local equivalent.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)
            }
        }
        .disabled(isPurchasing)
    }
}

private struct PaywallPurchaseOptionButton: View {
    let title: LocalizedStringResource
    let detail: LocalizedStringResource
    let price: String
    let badge: LocalizedStringResource?
    let isProminent: Bool
    let action: () -> Void

    @ViewBuilder
    var body: some View {
        if isProminent {
            purchaseButton
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        } else {
            purchaseButton
                .buttonStyle(.bordered)
                .controlSize(.large)
        }
    }

    private var purchaseButton: some View {
        Button(action: action) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(title)
                            .font(.headline)

                        if let badge {
                            Text(badge)
                                .font(.caption2.weight(.bold))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 3)
                                .background(.white.opacity(0.2), in: Capsule())
                        }
                    }

                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(isProminent ? .white.opacity(0.82) : .secondary)
                }

                Spacer(minLength: 8)

                Text(price)
                    .font(.headline.monospacedDigit())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 6)
        }
    }
}

private struct PaywallSubscriptionDisclosure: View {
    private static let privacyURL = URL(string: "https://open-client.com/privacy/")!
    private static let termsURL = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!
    private static let manageSubscriptionsURL = URL(string: "https://apps.apple.com/account/subscriptions")!

    let hasActiveMonthlySubscription: Bool

    var body: some View {
        VStack(spacing: 8) {
            if hasActiveMonthlySubscription {
                Text("Buying Pro Lifetime does not cancel Pro Monthly. Cancel Pro Monthly to avoid future renewals.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)

                Link("Manage Pro Monthly", destination: Self.manageSubscriptionsURL)
                    .font(.caption.weight(.semibold))
            }

            Text("Monthly subscriptions automatically renew unless canceled at least 24 hours before the end of the current period.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            HStack(spacing: 18) {
                Link("Terms of Use", destination: Self.termsURL)
                Link("Privacy Policy", destination: Self.privacyURL)
            }
            .font(.caption.weight(.medium))
        }
    }
}

private struct PaywallBenefitRow: View {
    let title: LocalizedStringResource
    let systemImage: String
    let tint: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 32, height: 32)
                .background(tint.opacity(0.14), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(tint.opacity(0.16), lineWidth: 1)
                }

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
        }
    }
}

private struct PaywallAppIcon: View {
    var body: some View {
        Group {
            if let image = Self.appIconImage {
                image
                    .resizable()
                    .scaledToFit()
            } else {
                Image(systemName: "sparkles.rectangle.stack.fill")
                    .resizable()
                    .scaledToFit()
                    .foregroundStyle(.tint)
                    .padding(14)
            }
        }
        .frame(width: 82, height: 82)
        .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
        .shadow(color: .black.opacity(0.14), radius: 18, y: 8)
        .accessibilityHidden(true)
    }

    private static var appIconImage: Image? {
        let names = iconNames
        for name in names {
#if canImport(UIKit)
            if let image = UIImage(named: name) {
                return Image(uiImage: image)
            }
#elseif canImport(AppKit)
            if let image = NSImage(named: name) {
                return Image(nsImage: image)
            }
#endif
        }
        return nil
    }

    private static var iconNames: [String] {
        var names: [String] = []
        if let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String {
            names.append(iconName)
        }

        if let icons = Bundle.main.object(forInfoDictionaryKey: "CFBundleIcons") as? [String: Any],
           let primary = icons["CFBundlePrimaryIcon"] as? [String: Any],
           let files = primary["CFBundleIconFiles"] as? [String] {
            names.append(contentsOf: files.reversed())
        }

        names.append(contentsOf: ["AppIcon", "ios-1024", "mac-1024"])
        return Array(NSOrderedSet(array: names)) as? [String] ?? names
    }
}
