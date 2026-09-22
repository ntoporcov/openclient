import SwiftUI

struct ChatAppearanceSettingsView: View {
    @ObservedObject var store: AppCustomizationStore

    var body: some View {
        Form {
            Section {
                NavigationLink {
                    ComposerStyleSettingsView(store: store)
                } label: {
                    LabeledContent("Composer Style") {
                        Text(store.composerStyle.title)
                    }
                }
                .accessibilityIdentifier("chat.appearance.composer-style")
            }

            Section {
                Toggle("Show Chat Activity Shimmer", isOn: Binding(
                    get: { store.showsChatActivityShimmer },
                    set: { store.setShowsChatActivityShimmer($0) }
                ))
                .accessibilityIdentifier("configurations.chat-activity-shimmer")

                Toggle("Show Tool Calls", isOn: Binding(
                    get: { store.showsToolCalls },
                    set: { store.setShowsToolCalls($0) }
                ))
                .accessibilityIdentifier("configurations.show-tool-calls")

                Toggle("Show Reasoning Blocks", isOn: Binding(
                    get: { store.showsReasoningBlocks },
                    set: { store.setShowsReasoningBlocks($0) }
                ))
                .accessibilityIdentifier("configurations.show-reasoning-blocks")
            } footer: {
                Text("Shows an animated highlight at the top of a chat while the AI is active.")
            }
        }
        .navigationTitle("Appearance Settings")
        .opencodeInlineNavigationTitle()
    }
}

private struct ComposerStyleSettingsView: View {
    @ObservedObject var store: AppCustomizationStore

    var body: some View {
        Form {
            Section {
                Picker("Composer Style", selection: Binding(
                    get: { store.composerStyle },
                    set: { store.setComposerStyle($0) }
                )) {
                    ForEach(ComposerStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("configurations.composer-style")
            } footer: {
                Text("Choose the composer layout for iPhone. iPad always uses Assistant.")
            }

            Section("Preview") {
                ComposerStylePreview(style: store.composerStyle)
                    .listRowInsets(EdgeInsets(top: 18, leading: 16, bottom: 18, trailing: 16))
            }
        }
        .navigationTitle("Composer Style")
        .opencodeInlineNavigationTitle()
    }
}

struct ComposerStylePreview: View {
    let style: ComposerStyle
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var glassNamespace

    var body: some View {
        VStack(spacing: 22) {
            ComposerPreviewTranscript()

            composerContainer
                .frame(maxWidth: .infinity)
                .frame(minHeight: 108, alignment: .bottom)
        }
        .padding(.vertical, 4)
        .animation(reduceMotion ? nil : .snappy(duration: 0.38, extraBounce: 0.04), value: style)
        .allowsHitTesting(false)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(Text(previewDescription))
        .accessibilityIdentifier("chat.appearance.composer-preview")
    }

    @ViewBuilder
    private var composerContainer: some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: 4) {
                ComposerPreviewLayout(style: style, glassNamespace: glassNamespace)
            }
        } else {
            ComposerPreviewLayout(style: style, glassNamespace: glassNamespace)
        }
        #else
        ComposerPreviewLayout(style: style, glassNamespace: glassNamespace)
        #endif
    }

    private var previewDescription: LocalizedStringResource {
        switch style {
        case .messenger:
            "Messenger composer preview with a separate add button and pill-shaped message field."
        case .assistant:
            "Assistant composer preview with a large message field and controls in a lower row."
        }
    }
}

private struct ComposerPreviewTranscript: View {
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer(minLength: 54)
                VStack(alignment: .trailing, spacing: 7) {
                    Capsule().fill(.primary.opacity(0.18)).frame(width: 126, height: 8)
                    Capsule().fill(.primary.opacity(0.12)).frame(width: 86, height: 8)
                }
                .padding(14)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 24, height: 24)
                VStack(alignment: .leading, spacing: 7) {
                    Capsule().fill(.primary.opacity(0.20)).frame(maxWidth: 172).frame(height: 8)
                    Capsule().fill(.primary.opacity(0.14)).frame(maxWidth: 142).frame(height: 8)
                    Capsule().fill(.primary.opacity(0.10)).frame(maxWidth: 96).frame(height: 8)
                }
                .padding(.top, 4)
                Spacer(minLength: 24)
            }
        }
    }
}

private struct ComposerPreviewLayout: View {
    let style: ComposerStyle
    let glassNamespace: Namespace.ID

    var body: some View {
        if style == .messenger {
            HStack(alignment: .bottom, spacing: 7) {
                addControl

                HStack(spacing: 8) {
                    Text("Message")
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Image(systemName: "mic.fill")
                        .foregroundStyle(.secondary)
                }
                .padding(.leading, 16)
                .padding(.trailing, 12)
                .frame(height: 48)
                .opencodeGlassSurface(in: Capsule())
                .opencodeToolbarGlassID("composer-preview-input", in: glassNamespace)
                .opencodeMatchedGlassTransition()

                sendControl(size: 44)
            }
        } else {
            VStack(alignment: .leading, spacing: 5) {
                Text("Message")
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 12)

                HStack(spacing: 5) {
                    assistantAddControl
                    HStack(spacing: 5) {
                        Image(systemName: "sparkles")
                        Text(verbatim: "GPT-6 Astra")
                    }
                    .padding(.horizontal, 10)
                    .font(.caption.weight(.medium))
                    .lineLimit(1)
                    .foregroundStyle(.primary)
                    .frame(minHeight: 44)
                    Spacer()
                    sendControl(size: 32)
                        .frame(width: 44, height: 44)
                }
                .frame(height: 44)
                .padding(.horizontal, 5)
            }
            .frame(minHeight: 96)
            .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .opencodeToolbarGlassID("composer-preview-input", in: glassNamespace)
            .opencodeMatchedGlassTransition()
        }
    }

    private var addControl: some View {
        Image(systemName: "plus")
            .font(.body.weight(.semibold))
            .frame(width: 44, height: 44)
            .opencodeGlassSurface(in: Circle())
            .opencodeToolbarGlassID("composer-preview-add", in: glassNamespace)
            .opencodeMatchedGlassTransition()
    }

    private var assistantAddControl: some View {
        Image(systemName: "plus")
            .font(.body.weight(.semibold))
            .frame(width: 32, height: 32)
            .opencodeActionGlass(clear: true, tint: Color.primary.opacity(0.07), size: 32, in: Circle())
            .opencodeToolbarGlassID("composer-preview-add", in: glassNamespace)
            .opencodeMatchedGlassTransition()
            .frame(width: 44, height: 44)
    }

    private func sendControl(size: CGFloat) -> some View {
        Image(systemName: "arrow.up")
            .font(.body.weight(.semibold))
            .foregroundStyle(.white)
            .frame(width: size, height: size)
            .opencodeActionGlass(clear: true, tint: Color.accentColor.opacity(0.82), size: size, in: Circle())
            .opencodeToolbarGlassID("composer-preview-send", in: glassNamespace)
            .opencodeMatchedGlassTransition()
    }
}
