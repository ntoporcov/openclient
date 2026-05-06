import SwiftUI

struct ThinkingRow: View {
    var animateEntry = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var entryAnimationStartDate: Date?
    @State private var hasRunEntryAnimation = false
    @State private var entryAnimationStartTask: Task<Void, Never>?
    @State private var entryAnimationTask: Task<Void, Never>?

    private static let entryStartOffset: CGFloat = 600
    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            thinkingRow(phase: pulsePhase(at: context.date), date: context.date)
        }
        .onAppear {
            scheduleEntryAnimationIfNeeded()
        }
        .onChange(of: animateEntry) { _, _ in
            scheduleEntryAnimationIfNeeded()
        }
        .onDisappear {
            finishEntryAnimation()
            hasRunEntryAnimation = false
        }
    }

    private func thinkingRow(phase: Double, date: Date) -> some View {
        let entryProgress = entryAnimationStartDate.map { entryAnimationProgress(at: date, startDate: $0) }
        let isWaitingForEntryAnimation = animateEntry && !hasRunEntryAnimation

        return HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .scaleEffect(0.72 + (phase * 0.73))
                        .opacity(1 - (phase * 0.8))
                    Text("Thinking")
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
        .offset(y: entryProgress.map { Self.entryStartOffset * (1 - $0) } ?? (isWaitingForEntryAnimation ? Self.entryStartOffset : 0))
        .opacity(entryProgress.map { 0.72 + 0.28 * $0 } ?? (isWaitingForEntryAnimation ? 0.72 : 1))
        .scaleEffect(entryProgress.map { 0.94 + 0.06 * $0 } ?? (isWaitingForEntryAnimation ? 0.94 : 1), anchor: .bottomLeading)
    }

    private func breathingGlassGlow(phase: Double) -> some View {
        shape
            .fill(
                LinearGradient(
                    colors: [
                        .white.opacity(0.04 + (phase * 0.14)),
                        .clear,
                        .white.opacity(0.02 + (phase * 0.06))
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay {
                shape
                    .strokeBorder(.white.opacity(0.08 + (phase * 0.18)), lineWidth: 1)
            }
            .blendMode(.screen)
            .opacity(reduceMotion ? 0.14 : 1)
            .allowsHitTesting(false)
    }

    private func pulsePhase(at date: Date) -> Double {
        guard !reduceMotion else { return 0 }
        let cycleDuration = 1.64
        let progress = date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: cycleDuration) / cycleDuration
        return (1 - cos(progress * 2 * .pi)) / 2
    }

    private func scheduleEntryAnimationIfNeeded() {
        guard animateEntry, !hasRunEntryAnimation else { return }
        guard entryAnimationStartTask == nil else { return }

        entryAnimationStartTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(120))
            guard !Task.isCancelled else { return }
            startEntryAnimationIfNeeded()
        }
    }

    private func startEntryAnimationIfNeeded() {
        guard animateEntry, !hasRunEntryAnimation else { return }

        hasRunEntryAnimation = true
        entryAnimationStartTask?.cancel()
        entryAnimationStartTask = nil
        entryAnimationStartDate = Date()

        entryAnimationTask?.cancel()
        entryAnimationTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(560))
            guard !Task.isCancelled else { return }
            finishEntryAnimation()
        }
    }

    private func entryAnimationProgress(at date: Date, startDate: Date) -> CGFloat {
        guard !reduceMotion else { return 1 }
        let elapsed = max(0, date.timeIntervalSince(startDate))
        let duration = 0.48
        let linear = min(1, elapsed / duration)
        return CGFloat(1 - pow(1 - linear, 3))
    }

    private func finishEntryAnimation() {
        entryAnimationStartTask?.cancel()
        entryAnimationStartTask = nil
        entryAnimationTask?.cancel()
        entryAnimationTask = nil
        entryAnimationStartDate = nil
    }
}
