import SwiftUI

struct ThinkingRow: View {
    var animateEntry = false

    @State private var phase = false
    @State private var entryOffset: CGFloat = 0
    @State private var entryOpacity: Double = 1
    @State private var entryScale: CGFloat = 1
    @State private var hasRunEntryAnimation = false
    @State private var entryAnimationTask: Task<Void, Never>?

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Circle()
                        .fill(.secondary)
                        .frame(width: 6, height: 6)
                        .opacity(phase ? 0.35 : 1)
                    Text("Thinking")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))

            Spacer(minLength: 44)
        }
        .frame(maxWidth: .infinity)
        .offset(y: entryOffset)
        .opacity(entryOpacity)
        .scaleEffect(entryScale, anchor: .bottomLeading)
        .onAppear {
            runEntryAnimationIfNeeded()
            guard !phase else { return }
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase = true
            }
        }
        .onChange(of: animateEntry) { _, _ in
            runEntryAnimationIfNeeded()
        }
        .onDisappear {
            entryAnimationTask?.cancel()
            entryAnimationTask = nil
            phase = false
        }
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
