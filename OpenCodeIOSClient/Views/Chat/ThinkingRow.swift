import SwiftUI

struct ThinkingRow: View {
    var animateEntry = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var entryOffset: CGFloat = 0
    @State private var entryOpacity: Double = 1
    @State private var entryScale: CGFloat = 1
    @State private var hasRunEntryAnimation = false
    @State private var entryAnimationTask: Task<Void, Never>?

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30.0, paused: reduceMotion)) { context in
            thinkingRow(phase: pulsePhase(at: context.date))
        }
        .onAppear {
            runEntryAnimationIfNeeded()
        }
        .onChange(of: animateEntry) { _, _ in
            runEntryAnimationIfNeeded()
        }
        .onDisappear {
            entryAnimationTask?.cancel()
            entryAnimationTask = nil
        }
    }

    private func thinkingRow(phase: Double) -> some View {
        HStack {
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
        .offset(y: entryOffset)
        .opacity(entryOpacity)
        .scaleEffect(entryScale, anchor: .bottomLeading)
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

    private func runEntryAnimationIfNeeded() {
        guard animateEntry, !hasRunEntryAnimation else { return }

        hasRunEntryAnimation = true
        var transaction = Transaction()
        transaction.animation = nil

        withTransaction(transaction) {
            entryOffset = 220
            entryOpacity = 0.001
            entryScale = 0.985
        }

        entryAnimationTask?.cancel()
        entryAnimationTask = Task { @MainActor in
            await Task.yield()
            guard !Task.isCancelled else { return }
            withAnimation(.spring(response: 0.46, dampingFraction: 0.86)) {
                entryOffset = 0
                entryOpacity = 1
                entryScale = 1
            }
            entryAnimationTask = nil
        }
    }
}
