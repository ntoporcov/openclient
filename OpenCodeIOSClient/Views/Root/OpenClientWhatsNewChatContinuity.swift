import SwiftUI

struct OpenClientWhatsNewChatContinuity: View {
    let release: OpenClientReleaseNotes

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
        }
        .accessibilityIdentifier("new-features.chat-continuity")
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
