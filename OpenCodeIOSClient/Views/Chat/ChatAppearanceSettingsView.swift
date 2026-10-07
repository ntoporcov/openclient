import SwiftUI

struct ChatAppearanceSettingsView: View {
    @ObservedObject var store: AppCustomizationStore
    var isV2Connection = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            Section {
                AccentColorPicker(store: store)
            } header: {
                Text("Accent Color")
            } footer: {
                Text("Used throughout this connection for buttons, highlights, and chat bubbles.")
            }

            Section("Chat Bubbles") {
                Picker("Bubble Style", selection: Binding(
                    get: { store.chatBubbleStyle },
                    set: { store.setChatBubbleStyle($0) }
                )) {
                    ForEach(ChatBubbleStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("appearance.bubble-style")

                HStack {
                    Spacer(minLength: 24)
                    Text("Make yourself at home.")
                        .foregroundStyle(store.accentColor.foreground(in: colorScheme))
                        .padding(.leading, 14)
                        .padding(.trailing, 22)
                        .padding(.vertical, 10)
                        .background { ChatBubbleBackground() }
                }
                .padding(.vertical, 12)
                .accessibilityIdentifier("appearance.bubble-preview")
            }

            if OpenCodePlatformCapabilities.supportsComposerStyleChoice {
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
            }

            Section("Sessions") {
                Picker("Card Style", selection: Binding(
                    get: { store.sessionCardStyle },
                    set: { store.setSessionCardStyle($0) }
                )) {
                    ForEach(SessionCardStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .accessibilityIdentifier("appearance.session-card-style")

                Toggle("Show Last User Message", isOn: Binding(
                    get: { store.showsActivityLastUserMessage },
                    set: { store.setShowsActivityLastUserMessage($0) }
                ))
                .accessibilityIdentifier("appearance.last-user-message")

                Toggle("Minimize Todos", isOn: Binding(
                    get: { store.isTodoStripMinimized },
                    set: { store.setTodoStripMinimized($0) }
                ))
            }

            Section {
                Toggle("Show Tool Calls", isOn: Binding(
                    get: { store.showsToolCalls },
                    set: { store.setShowsToolCalls($0) }
                ))
                .accessibilityIdentifier("configurations.show-tool-calls")

                Toggle("Group Tool Calls", isOn: Binding(
                    get: { store.groupsToolCalls },
                    set: { store.setGroupsToolCalls($0) }
                ))
                .accessibilityIdentifier("configurations.group-tool-calls")

                Toggle("Show Reasoning Blocks", isOn: Binding(
                    get: { store.showsReasoningBlocks },
                    set: { store.setShowsReasoningBlocks($0) }
                ))
                .accessibilityIdentifier("configurations.show-reasoning-blocks")

                if isV2Connection {
                    Toggle("Show Context Changes", isOn: Binding(
                        get: { store.showsContextChanges },
                        set: { store.setShowsContextChanges($0) }
                    ))
                    .accessibilityIdentifier("configurations.show-context-changes")
                }
            } footer: {
                Text("Shows an animated highlight at the top of a chat while the AI is active.")
            }
        }
        .navigationTitle("Appearance Settings")
        .modifier(AppAppearanceModifier(store: store))
        .opencodeInlineNavigationTitle()
    }
}

struct AccentColorPicker: View {
    @ObservedObject var store: AppCustomizationStore
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 12)], spacing: 12) {
            ForEach(AppAccentColor.allCases) { accent in
                Button {
                    store.setAccentColor(accent)
                } label: {
                    HStack(spacing: 10) {
                        Circle()
                            .fill(accent == .clear ? Color.clear : accent.color(in: colorScheme))
                            .overlay { Circle().strokeBorder(.primary.opacity(accent == .clear ? 0.35 : 0), lineWidth: 1) }
                            .frame(width: 24, height: 24)
                        Text(accent.title)
                            .foregroundStyle(.primary)
                        Spacer(minLength: 0)
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                            .opacity(store.accentColor == accent ? 1 : 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(minHeight: 44)
                    .background(accent.color(in: colorScheme).opacity(store.accentColor == accent ? 0.14 : 0.04),
                                in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text(accent.title))
                .accessibilityAddTraits(store.accentColor == accent ? .isSelected : [])
                .accessibilityIdentifier("appearance.accent-color.\(accent.rawValue)")
            }
        }
        .padding(.vertical, 6)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("appearance.accent-color")
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
    @Environment(\.appAccentColor) private var appAccentColor
    var body: some View {
        VStack(spacing: 14) {
            HStack {
                Spacer(minLength: 54)
                VStack(alignment: .trailing, spacing: 7) {
                    Capsule().fill(.primary.opacity(0.18)).frame(width: 126, height: 8)
                    Capsule().fill(.primary.opacity(0.12)).frame(width: 86, height: 8)
                }
                .padding(14)
                .background(appAccentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            }

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "sparkles")
                    .foregroundStyle(appAccentColor)
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
    @Environment(\.appAccentForeground) private var appAccentForeground
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
            .foregroundStyle(appAccentForeground)
            .frame(width: size, height: size)
            .opencodeAccentActionGlass(size: size, in: Circle())
            .opencodeToolbarGlassID("composer-preview-send", in: glassNamespace)
            .opencodeMatchedGlassTransition()
    }
}
