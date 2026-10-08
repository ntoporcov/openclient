import SwiftUI

struct OpenClientWhatsNewChatContinuity: View {
    let release: OpenClientReleaseNotes
    let store: AppCustomizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 32) {
            VStack(alignment: .leading, spacing: 8) {
                Text("NEW IN \(release.version)").font(.caption.bold()).foregroundStyle(.secondary)
                Text(verbatim: release.title).font(.largeTitle.bold())
                Text(verbatim: release.summary).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                WhatsNewStatusPillPreview()
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
                Text("Small pill. Big personality.").font(.title2.bold())
                Text("A new 3D status pill keeps you in the loop as the assistant thinks, reads, and gets things done.")
                    .foregroundStyle(.secondary)
                Text("Curious? Give the pill a long press. It has a playful side.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            WhatsNewChatComfortSection(store: store)

            VStack(alignment: .leading, spacing: 12) {
                Label("See what changed", systemImage: "doc.text.magnifyingglass").font(.title2.bold())
                Text("Tap a response, then the Changes button beside Copy to explore that turn’s file diffs. Unchanged lines start collapsed so the important bits stand out.")
                    .foregroundStyle(.secondary)
                Text("Per-turn changes require OpenCode v2 and recorded file snapshots.")
                    .font(.footnote).foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Scroll back. Yes, finally.", systemImage: "clock.arrow.circlepath").font(.title2.bold())
                Text("Older messages load as you scroll, while your place stays put. We’ve spent enough time chasing the scroll position. Now you can spend yours finding that thing the assistant said 200 messages ago.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Your projects, your names.", systemImage: "paintpalette").font(.title2.bold())
                Text("Rename OpenCode v2 projects and change their color or image from Project Settings or the project menu. Your project name now follows you into the navigation bar.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("More room for logos.", systemImage: "photo.on.rectangle").font(.title2.bold())
                Text("Browse a larger selection of project images, search by filename, and reveal more with Show More. Images appear in batches of 48.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Settings that stay on track.", systemImage: "slider.horizontal.3").font(.title2.bold())
                Text("Provider settings keep their place as you navigate back. Usage tracking loads provider credentials when you open it, with a retry option if discovery fails.")
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 12) {
                Label("Know your session.", systemImage: "chart.bar.xaxis").font(.title2.bold())
                Text("Explore recorded token usage, response timing, and model details from the context menu. Missing metrics are shown as unavailable, and totals clearly describe the loaded history.")
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("new-features.chat-continuity")
    }
}

private struct WhatsNewChatComfortSection: View {
    @ObservedObject var store: AppCustomizationStore

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Find your comfort level.", systemImage: "text.line.spacing")
                .font(.title2.bold())
            Text("Give your transcript a little breathing room. Try a line height below; your choice is saved for your chats. You can change it anytime in Chat Appearance.")
                .foregroundStyle(.secondary)

            Picker("Line Height", selection: Binding(
                get: { store.chatLineHeight },
                set: { store.setChatLineHeight($0) }
            )) {
                ForEach(ChatLineHeight.allCases) { height in
                    Text(height.title).tag(height)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("new-features.line-height")

            Text("Choose comfortable spacing\nbetween the lines of your chats.")
                .lineSpacing(3 + store.chatLineHeight.additionalSpacing)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(
                    OpenCodePlatformColor.secondaryGroupedBackground,
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous)
                )
                .accessibilityIdentifier("new-features.line-height-preview")
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("new-features.chat-comfort")
    }
}

private struct WhatsNewStatusPillPreview: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var statusIndex = 0
    @State private var showsPlayground = false

    private let statuses: [ThinkingPillStatus] = [
        .init(title: "Thinking", tint: .cyan),
        .init(title: "Reading", tint: .blue),
        .init(title: "Editing", tint: .orange),
        .init(title: "Working", tint: .green)
    ]

    private var cyclesStatuses: Bool { scenePhase == .active && !reduceMotion && !showsPlayground }

    var body: some View {
        let status = statuses[statusIndex]
        Group {
#if canImport(RealityKit) && canImport(UIKit)
            if #available(iOS 18.0, *) {
                GlassThinkingPill(title: status.title, tint: status.tint, isPaused: !cyclesStatuses, maximumDimension: 64)
                    .contentShape(Capsule())
                    .onLongPressGesture { showsPlayground = true }
                    .accessibilityAction(named: Text("Play")) { showsPlayground = true }
                    .sheet(isPresented: $showsPlayground) {
                        GlassThinkingPillPlayground(title: status.title, tint: status.tint, onClose: { showsPlayground = false })
                            .presentationDetents([.large])
                    }
            } else {
                fallback(status)
            }
#else
            fallback(status)
#endif
        }
        .accessibilityIdentifier("new-features.status-pill")
        .task(id: cyclesStatuses) {
            guard cyclesStatuses else { return }
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(3)) } catch { return }
                statusIndex = (statusIndex + 1) % statuses.count
            }
        }
    }

    private func fallback(_ status: ThinkingPillStatus) -> some View {
        Text(status.title)
            .font(.subheadline.weight(.medium))
            .padding(.horizontal, 24).padding(.vertical, 14)
            .background(status.tint.opacity(0.15), in: Capsule())
    }
}
