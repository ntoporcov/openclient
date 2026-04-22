import SwiftUI

struct ConfigurationsSheet: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section("New Session Defaults") {
                    NavigationLink {
                        AgentDefaultSelectionView(viewModel: viewModel)
                    } label: {
                        configurationRow(title: "Agent", value: viewModel.configurationAgentTitle)
                    }

                    NavigationLink {
                        ModelDefaultSelectionView(viewModel: viewModel)
                    } label: {
                        configurationRow(title: "Model", value: viewModel.configurationModelTitle)
                    }

                    NavigationLink {
                        ReasoningDefaultSelectionView(viewModel: viewModel)
                    } label: {
                        configurationRow(title: "Reasoning", value: viewModel.configurationReasoningTitle)
                    }
                    .disabled(viewModel.configurationReasoningVariants.isEmpty)
                }

                Section {
                    Text("Used when starting a new session on this server. Changes made in a chat only affect that session.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Configurations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        viewModel.isShowingConfigurationsSheet = false
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func configurationRow(title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }
}

private struct AgentDefaultSelectionView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.setNewSessionDefaultAgent(nil as String?)
                } label: {
                    selectionRow(title: "Use System Default", isSelected: viewModel.newSessionDefaults.agentName == nil)
                }
                .buttonStyle(.plain)
            }

            Section("Options") {
                ForEach(viewModel.selectableAgents) { agent in
                    Button {
                        viewModel.setNewSessionDefaultAgent(agent.name)
                    } label: {
                        selectionRow(title: agent.name.capitalized, isSelected: viewModel.newSessionDefaults.agentName == agent.name)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Agent")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ModelDefaultSelectionView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.setNewSessionDefaultModel(nil as OpenCodeModelReference?)
                } label: {
                    selectionRow(title: "Use System Default", isSelected: viewModel.newSessionDefaultModelReference() == nil)
                }
                .buttonStyle(.plain)
            }

            ForEach(viewModel.sortedProviders) { provider in
                Section(provider.name) {
                    ForEach(provider.models.values.sorted(by: { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }), id: \.id) { model in
                        let reference = OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                        Button {
                            viewModel.setNewSessionDefaultModel(reference)
                        } label: {
                            selectionRow(title: model.name, isSelected: viewModel.newSessionDefaultModelReference() == reference)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .navigationTitle("Model")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct ReasoningDefaultSelectionView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            Section {
                Button {
                    viewModel.setNewSessionDefaultReasoning(nil as String?)
                } label: {
                    selectionRow(title: "Use System Default", isSelected: viewModel.newSessionDefaults.reasoningVariant == nil)
                }
                .buttonStyle(.plain)
            }

            Section("Options") {
                ForEach(viewModel.configurationReasoningVariants, id: \.self) { variant in
                    Button {
                        viewModel.setNewSessionDefaultReasoning(variant)
                    } label: {
                        selectionRow(
                            title: viewModel.formattedVariantTitle(variant),
                            isSelected: viewModel.newSessionDefaults.reasoningVariant == variant
                        )
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Reasoning")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private func selectionRow(title: String, isSelected: Bool) -> some View {
    HStack {
        if isSelected {
            Image(systemName: "checkmark")
                .foregroundStyle(.tint)
        } else {
            Image(systemName: "checkmark")
                .foregroundStyle(.clear)
        }

        Text(title)
            .foregroundStyle(.primary)
        Spacer()
    }
    .contentShape(Rectangle())
}
