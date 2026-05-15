import SwiftUI

struct ThinkingRow: View {
    var animateEntry = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pulsePhase = 0.0

    private let shape = RoundedRectangle(cornerRadius: 20, style: .continuous)

    var body: some View {
        thinkingRow(phase: reduceMotion ? 0 : pulsePhase)
        .onAppear {
            startPulseAnimationIfNeeded()
        }
        .onChange(of: reduceMotion) { _, _ in
            startPulseAnimationIfNeeded()
        }
        .onDisappear {
            pulsePhase = 0
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
