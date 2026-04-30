import SwiftUI

#if DEBUG
struct OpenClientDebugEntitlementControls: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Debug Entitlement")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)

            Picker("Debug Entitlement", selection: $viewModel.debugEntitlementOverride) {
                ForEach(OpenClientDebugEntitlementOverride.allCases) { option in
                    Text(option.title).tag(option)
                }
            }
            .pickerStyle(.segmented)

            HStack(spacing: 14) {
                Button("Reset Usage") {
                    viewModel.resetDebugUsageMeter()
                }

                Button("Show Paywall") {
                    viewModel.presentPaywall(reason: .manual)
                }
            }
            .font(.caption.weight(.medium))
        }
    }
}
#endif
