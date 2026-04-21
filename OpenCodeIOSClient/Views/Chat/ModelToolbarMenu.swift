import SwiftUI

struct ModelToolbarMenu: View {
    @ObservedObject var viewModel: AppViewModel
    let session: OpenCodeSession
    let glassNamespace: Namespace.ID

    var body: some View {
        Menu {
            Menu("Model") {
                ForEach(viewModel.sortedProviders) { provider in
                    let models = provider.models.values.sorted {
                        $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
                    }
                    Menu(provider.name) {
                        ForEach(models, id: \.id) { model in
                            Button(model.name) {
                                viewModel.selectModel(
                                    OpenCodeModelReference(providerID: provider.id, modelID: model.id),
                                    for: session
                                )
                            }
                        }
                    }
                }
            }

            let reasoningVariants = viewModel.reasoningVariants(for: session)
            if !reasoningVariants.isEmpty {
                Menu("Reasoning") {
                    ForEach(reasoningVariants, id: \.self) { variant in
                        Button(viewModel.formattedVariantTitle(variant)) {
                            viewModel.selectVariant(variant, for: session)
                        }
                    }
                }
            }
        } label: {
            Group {
                if let reasoningSubtitle {
                    VStack(alignment: .trailing, spacing: 0) {
                        Text(viewModel.modelToolbarTitle(for: session))
                            .font(.caption)
                        Text(reasoningSubtitle)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(viewModel.modelToolbarTitle(for: session))
                        .font(.caption)
                }
            }
            .opencodeToolbarGlassID("model-toolbar", in: glassNamespace)
        }
    }

    private var reasoningSubtitle: String? {
        let variants = viewModel.reasoningVariants(for: session)
        guard !variants.isEmpty else { return nil }
        return viewModel.reasoningToolbarTitle(for: session)
    }
}
