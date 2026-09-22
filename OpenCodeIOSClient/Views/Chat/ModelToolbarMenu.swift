import SwiftUI

struct ChatToolbarWidthBudget {
    let header: CGFloat
    let model: CGFloat
    let spacing: CGFloat
    let assistantHeader: CGFloat
    let assistantHeaderWithTrailingItem: CGFloat

    init(containerWidth: CGFloat) {
        // The leading pill includes the fixed context target; the trailing pill is model-only.
        let pillSpace = min(400, max(196, containerWidth - 124))
        spacing = containerWidth < 360 ? 0 : 4
        model = (pillSpace * 0.48).rounded() - 10
        header = pillSpace - model

        // The phone Assistant group is trailing-anchored, leaving Back, the native
        // inter-item gap, and the native 20-point trailing margin outside this width.
        assistantHeader = max(92, containerWidth - 104)
        // A separate trailing control needs its 44-point target plus native item spacing.
        assistantHeaderWithTrailingItem = max(92, assistantHeader - 56)
    }
}

struct ModelToolbarMenu: View {
    let modelTitle: String
    var modelReference: OpenCodeModelReference?
    var providerName: String?
    let providerGroups: [ChatFacade.ToolbarProviderGroup]
    let reasoningVariants: [ChatFacade.ToolbarReasoningVariant]
    let reasoningTitle: String
    let glassNamespace: Namespace.ID
    let onSelectModel: (OpenCodeModelReference) -> Void
    let onSelectReasoningVariant: ((String) -> Void)?
    var maximumWidth: CGFloat? = nil
    var contentAlignment: HorizontalAlignment = .trailing
    var accessibilityIdentifier = "chat.toolbar.model"
    var providerAccessibilityIdentifier = "chat.toolbar.providerLogo"
    var usesGlassCapsule = false

    var body: some View {
        StablePickerMenu(
            elements: menuElements,
            accessibilityLabel: String(localized: "Model"),
            accessibilityValue: accessibilityValue,
            accessibilityIdentifier: accessibilityIdentifier,
            onSelect: select
        ) {
            modelLabel
        }
        .help(Text(verbatim: providerName ?? modelTitle))
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private var modelLabel: some View {
        if usesGlassCapsule {
            modelLabelContent
                .padding(.horizontal, 10)
                .frame(minWidth: 44, minHeight: 44)
                .opencodeGlassSurface(isInteractive: true, in: Capsule())
                .opencodeToolbarGlassID("composer-model-selector", in: glassNamespace)
                .opencodeMatchedGlassTransition()
        } else {
            modelLabelContent
                .opencodeToolbarGlassID("model-toolbar", in: glassNamespace)
        }
    }

    private var modelLabelContent: some View {
        HStack(spacing: maximumWidth == nil ? 4 : 0) {
            if maximumWidth != nil {
                Spacer(minLength: 0)
            }
            if maximumWidth == nil, let providerID = modelReference?.providerID, !providerID.isEmpty {
                ProviderIcon(providerID: providerID)
                    .foregroundStyle(.primary.opacity(0.72))
            }
            if let reasoningSubtitle {
                VStack(alignment: contentAlignment, spacing: 0) {
                    Text(modelTitle)
                        .font(.caption)
                        .truncationMode(.head)
                        .accessibilityIdentifier("\(accessibilityIdentifier).title")
                    Text(reasoningSubtitle)
                        .font(.caption2)
                        .foregroundStyle(.primary.opacity(0.72))
                        .accessibilityIdentifier("\(accessibilityIdentifier).reasoning")
                }
            } else {
                Text(modelTitle)
                    .font(.caption)
                    .truncationMode(.head)
            }
            if let maximumWidth, let providerID = modelReference?.providerID, !providerID.isEmpty {
                ProviderIcon(providerID: providerID, size: maximumWidth < 80 ? 16 : 24)
                    .foregroundStyle(.primary.opacity(0.72))
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(Text(verbatim: providerName ?? providerID))
                    .accessibilityIdentifier(providerAccessibilityIdentifier)
                    .accessibilityHidden(false)
                    .padding(.leading, 4)
                    .fixedSize()
                    .layoutPriority(1)
            }
        }
        .lineLimit(contentAlignment == .leading || maximumWidth != nil ? 1 : nil)
        .truncationMode(.tail)
        .padding(.trailing, usesGlassCapsule ? 0 : maximumWidth == nil ? 12 : 6)
        .frame(
            minWidth: contentAlignment == .leading ? 44 : maximumWidth == nil ? (modelReference == nil ? 72 : 108) : 44,
            idealWidth: maximumWidth,
            maxWidth: maximumWidth,
            minHeight: contentAlignment == .leading || maximumWidth != nil ? 44 : nil,
            alignment: .leading
        )
    }

    private var reasoningSubtitle: String? {
        guard onSelectReasoningVariant != nil, !reasoningVariants.isEmpty else { return nil }
        return reasoningTitle
    }

    private var accessibilityValue: String {
        [providerName, modelTitle, reasoningSubtitle].compactMap { $0 }.joined(separator: ", ")
    }

    private var menuElements: [StablePickerMenuElement] {
        var elements = [StablePickerMenuElement.submenu(
            id: "models",
            title: String(localized: "Model"),
            children: providerGroups.map { provider in
                .submenu(
                    id: "provider:\(provider.id)",
                    title: provider.name,
                    children: provider.models.map { model in
                        .action(
                            id: modelActionID(providerID: provider.id, modelID: model.id),
                            title: model.name,
                            systemImage: nil,
                            isSelected: modelReference == OpenCodeModelReference(providerID: provider.id, modelID: model.id)
                        )
                    }
                )
            }
        )]

        if onSelectReasoningVariant != nil, !reasoningVariants.isEmpty {
            elements.append(.submenu(
                id: "reasoning",
                title: String(localized: "Reasoning"),
                children: reasoningVariants.map { variant in
                    .action(
                        id: reasoningActionID(variant.id),
                        title: variant.title,
                        systemImage: nil,
                        isSelected: variant.title == reasoningTitle
                    )
                }
            ))
        }
        return elements
    }

    private func select(_ actionID: String) {
        if actionID.hasPrefix("reasoning:"), let onSelectReasoningVariant {
            let variantID = String(actionID.dropFirst("reasoning:".count))
            onSelectReasoningVariant(variantID)
            return
        }

        for provider in providerGroups {
            if let model = provider.models.first(where: {
                modelActionID(providerID: provider.id, modelID: $0.id) == actionID
            }) {
                onSelectModel(OpenCodeModelReference(providerID: provider.id, modelID: model.id))
                return
            }
        }
    }

    private func modelActionID(providerID: String, modelID: String) -> String {
        "model:\(providerID):\(modelID)"
    }

    private func reasoningActionID(_ variantID: String) -> String {
        "reasoning:\(variantID)"
    }
}
