import SwiftUI

enum ThinkingEntryMotion {
    static let duration = 0.32

    static func progress(elapsed: TimeInterval, animateEntry: Bool, reduceMotion: Bool) -> Double {
        guard animateEntry, !reduceMotion else { return 1 }
        let fraction = min(1, max(0, elapsed / duration))
        return 1 - pow(1 - fraction, 3)
    }
}

struct ThinkingRow: View {
    var animateEntry = false
    var tint: Color = .secondary
    var title: LocalizedStringResource = "Thinking"

    @Environment(\.accessibilityReduceMotion) private var systemReduceMotion

    private var reduceMotion: Bool {
        #if DEBUG && canImport(UIKit)
        if TranscriptContinuityDiagnostics.enabled, TranscriptContinuityDiagnostics.reducesMotion { return true }
        #endif
        return systemReduceMotion
    }

    @State private var pulsePhase = 0.0
    @State private var entryStart: Date?
    @State private var entryFinished = false

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        // A bounded clock also animates inside transcript cells that disable implicit animations.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: entryFinished || !animateEntry || reduceMotion)) { timeline in
            let progress = ThinkingEntryMotion.progress(
                elapsed: entryFinished ? ThinkingEntryMotion.duration : entryStart.map { timeline.date.timeIntervalSince($0) } ?? 0,
                animateEntry: animateEntry, reduceMotion: reduceMotion)
            thinkingRow(phase: reduceMotion ? 0 : pulsePhase)
                .offset(y: 8 * (1 - progress))
                .scaleEffect(0.96 + 0.04 * progress, anchor: .bottomLeading)
                .opacity(0.3 + 0.7 * progress)
                #if DEBUG && canImport(UIKit)
                .onChange(of: progress, initial: true) { _, progress in
                    TranscriptContinuityDiagnostics.thinkingFrame(progress)
                }
                #endif
        }
        .onAppear {
            #if DEBUG && canImport(UIKit)
            if TranscriptContinuityDiagnostics.enabled {
                TranscriptContinuityDiagnostics.thinkingVisible = true
                TranscriptContinuityDiagnostics.thinkingEvents.append("appear animate=\(animateEntry) reduce=\(reduceMotion) finished=\(entryFinished)")
            }
            #endif
            if entryStart == nil { entryStart = .now }
            startPulseAnimationIfNeeded()
        }
        .task {
            guard !entryFinished else { return }
            if animateEntry, !reduceMotion {
                try? await Task.sleep(for: .seconds(ThinkingEntryMotion.duration))
            }
            guard !Task.isCancelled else { return }
            entryFinished = true
        }
        .onChange(of: reduceMotion) { _, _ in
            startPulseAnimationIfNeeded()
        }
        .onDisappear {
            #if DEBUG && canImport(UIKit)
            if TranscriptContinuityDiagnostics.enabled { TranscriptContinuityDiagnostics.thinkingVisible = false }
            #endif
            pulsePhase = 0
        }
    }

    private func thinkingRow(phase: Double) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(tint)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.72 + (phase * 0.73))
                        .opacity(1 - (phase * 0.8))
                    Text(title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                        .opacity(1 - (phase * 0.28))
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .opencodeGlassSurface(in: shape)
            .overlay {
                breathingGlassGlow(phase: phase)
            }
            .scaleEffect(0.994 + (phase * 0.02), anchor: .leading)

            Spacer(minLength: 44)
        }
        .frame(maxWidth: .infinity)
    }

    private func breathingGlassGlow(phase: Double) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [
                        tint.opacity(0.04 + (phase * 0.14)),
                        .clear,
                        tint.opacity(0.02 + (phase * 0.06))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                shape
                    .strokeBorder(tint.opacity(0.08 + (phase * 0.18)), lineWidth: 1)
            }
            .blendMode(.screen)
            .opacity(reduceMotion ? 0.14 : 1)
            .allowsHitTesting(false)
    }

    private func startPulseAnimationIfNeeded() {
        guard !reduceMotion else {
            pulsePhase = 0
            return
        }

        pulsePhase = 0
        withAnimation(.easeInOut(duration: 0.82).repeatForever(autoreverses: true)) {
            pulsePhase = 1
        }
    }
}
