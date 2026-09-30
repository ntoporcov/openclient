import SwiftUI

struct OpenClientWhatsNewChatControls: View {
    let release: OpenClientReleaseNotes
    @Binding var delivery: OpenCodePromptDelivery
    @ObservedObject var store: AppCustomizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NEW IN \(release.version)").font(.caption.bold()).foregroundStyle(.secondary)
                Text(release.title).font(.largeTitle.bold())
                Text(release.summary).foregroundStyle(.secondary)
            }
            WhatsNewDeliverySection(delivery: $delivery)
            WhatsNewSideQuestionSection()
            WhatsNewAppearanceSection(store: store)
            VStack(alignment: .leading, spacing: 12) {
                Label("Commands and skills in v2", systemImage: "terminal").font(.title2.bold())
                Text("Type / to find and run your OpenCode v2 commands and skills, including those configured for your project.")
                    .foregroundStyle(.secondary)
            }
            Text("You can change these choices later in Settings. Queue, Steer, and Side Question require OpenCode v2.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .modifier(AppAppearanceModifier(store: store))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-features.chat-controls")
    }
}

#if DEBUG
struct WhatsNewChatControlsFixture: View {
    @State private var delivery = OpenCodePromptDelivery.queue
    @StateObject private var store: AppCustomizationStore

    init() {
        let defaults = UserDefaults(suiteName: "WhatsNewChatControlsFixture")!
        defaults.removePersistentDomain(forName: "WhatsNewChatControlsFixture")
        _store = StateObject(wrappedValue: AppCustomizationStore(defaults: defaults))
    }

    var body: some View {
        ScrollView {
            Group {
            if ProcessInfo.processInfo.environment["OPENCLIENT_GALLERY"] == "1" {
                WhatsNewAppearanceSection(store: store)
                    .modifier(AppAppearanceModifier(store: store))
            } else {
            OpenClientWhatsNewChatControls(release: OpenClientReleaseNotesCatalog.releases.last!, delivery: $delivery, store: store)
            }
            }
                .padding(20)
                .frame(maxWidth: 600)
                .frame(maxWidth: .infinity)
        }
    }
}
#endif

private struct WhatsNewDeliverySection: View {
    @Binding var delivery: OpenCodePromptDelivery

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Keep the conversation moving", systemImage: "arrow.triangle.branch").font(.title2.bold())
            Text("Choose what Send does while the assistant is working.").foregroundStyle(.secondary)
            Picker("While streaming", selection: $delivery) {
                Text("Queue").tag(OpenCodePromptDelivery.queue)
                Text("Steer").tag(OpenCodePromptDelivery.steer)
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("new-features.streaming-delivery")
            Text(delivery == .queue
                 ? LocalizedStringResource("Queue saves your message for the next turn.")
                 : LocalizedStringResource("Steer redirects the assistant during its current turn."))
                .font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

private struct WhatsNewSideQuestionSection: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Side Question", systemImage: "questionmark.bubble").font(.title2.bold())
            Text("Ask a quick question without adding it to the conversation or interrupting the work.")
                .foregroundStyle(.secondary)
            Text("Hold Send to choose Queue, Steer, or Side Question for a single message.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

private struct WhatsNewChatPreview: View {
    @ObservedObject var store: AppCustomizationStore
    @State private var expanded = false

    private var activities: some View {
        VStack(spacing: 8) {
            ActivityRow(style: .init(title: .localized("Read files"), subtitle: .verbatim("README.md"), icon: "doc.text",
                                    tint: .blue, isRunning: false, showsDisclosure: false, shimmerTitle: false))
            ActivityRow(style: .init(title: .localized("Edited files"), subtitle: .verbatim("Theme.swift"), icon: "pencil",
                                    tint: .orange, isRunning: false, showsDisclosure: false, shimmerTitle: false))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            WhatsNewUserBubble(text: "Add a dark mode, too.")
                .accessibilityIdentifier("new-features.bubble-preview")
            VStack(alignment: .leading, spacing: 8) {
                if store.groupsToolCalls {
                    Button { expanded.toggle() } label: {
                        ContextToolGroupHeader(style: .init(title: .localized("Read files"), subtitle: .localized("\(2) tool calls"),
                            icon: "", tint: .blue, isRunning: false, showsDisclosure: true, shimmerTitle: false), expanded: expanded)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("new-features.group-preview")
                    if expanded { activities }
                } else {
                    activities
                }
            }
        }
    }
}

private struct WhatsNewAppearanceSection: View {
    @ObservedObject var store: AppCustomizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Make it yours", systemImage: "paintpalette").font(.title2.bold())
            Picker("Bubble Style", selection: Binding(get: { store.chatBubbleStyle }, set: { store.setChatBubbleStyle($0) })) {
                ForEach(ChatBubbleStyle.allCases) { style in Text(style.title).tag(style) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("new-features.bubble-style")
            Text("Accent Color").font(.headline)
            AccentColorPicker(store: store)
            Toggle("Group Tool Calls", isOn: Binding(get: { store.groupsToolCalls }, set: { store.setGroupsToolCalls($0) }))
                .accessibilityIdentifier("new-features.group-tools")
            Text("Combine tools, reasoning, and context between replies into an expandable summary.")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Example").font(.caption).foregroundStyle(.secondary)
            WhatsNewChatPreview(store: store)
                .padding(16)
                .background(OpenCodePlatformColor.secondaryGroupedBackground.opacity(0.45), in: RoundedRectangle(cornerRadius: 18))
        }
    }
}

private struct WhatsNewUserBubble: View {
    let text: LocalizedStringResource
    @Environment(\.appAccentForeground) private var foreground

    var body: some View {
        HStack {
            Spacer(minLength: 24)
            Text(text)
                .foregroundStyle(foreground)
                .padding(.leading, 14).padding(.trailing, 22).padding(.vertical, 10)
                .background { ChatBubbleBackground() }
        }
    }
}
