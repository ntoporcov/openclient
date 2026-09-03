import SwiftUI

#if DEBUG
struct OpenClientDebugEntitlementControls: View {
    @ObservedObject var commerce: CommerceFacade

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug Entitlement")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Debug Entitlement", selection: Binding(
                get: { commerce.debugEntitlementOverride },
                set: { commerce.debugEntitlementOverride = $0 }
            )) {
                ForEach(OpenClientDebugEntitlementOverride.allCases) { option in
                    Text(debugEntitlementTitle(option)).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 14) {
                Button("Reset Usage") {
                    commerce.resetDebugUsageMeter()
                }

                Button("Show Paywall") {
                    commerce.presentPaywall(reason: .manual)
                }
            }
            .font(.caption.weight(.medium))
        }
    }
}

private func debugEntitlementTitle(_ option: OpenClientDebugEntitlementOverride) -> LocalizedStringResource {
    switch option {
    case .system: "System"
    case .free: "Free"
    case .monthly: "Monthly"
    case .unlocked: "Unlocked"
    case .limitReached: "Limit Reached"
    }
}
#endif
