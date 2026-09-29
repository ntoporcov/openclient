import SwiftUI

enum SideQuestionAppearance {
    static let symbolName = "questionmark.bubble"
}

struct SideQuestionSheet: View {
    @ObservedObject var store: SideQuestionStore
    let coordinator: SideQuestionCoordinator
    @Environment(\.dismiss) private var dismiss
    @FocusState private var isQuestionFocused: Bool

    var body: some View {
        let requestID = store.request?.id
        NavigationStack {
            GeometryReader { sheetGeometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 20) {
                        if store.isGenerating || store.answer != nil || store.errorMessage != nil {
                            Text(verbatim: store.prompt.trimmingCharacters(in: .whitespacesAndNewlines))
                                .font(.title2.bold())
                                .textSelection(.enabled)
                                .accessibilityAddTraits(.isHeader)
                                .accessibilityIdentifier("chat.sideQuestion.question")
                        } else {
                            TextField("Your question", text: $store.prompt)
                                .font(.title2.bold())
                                .focused($isQuestionFocused)
                                .submitLabel(.send)
                                .onSubmit {
                                    guard store.canAsk else { return }
                                    isQuestionFocused = false
                                    store.ask()
                                }
                                .accessibilityIdentifier("chat.sideQuestion.input")
                        }

                        SideQuestionResult(store: store, sheetHeight: sheetGeometry.size.height)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
                }
            }
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("chat.sideQuestion.done")
                }
            }
        }
        .task(id: requestID) {
            guard let requestID, store.request?.id == requestID else { return }
            await coordinator.answer(store: store)
        }
        .onAppear {
            if store.canAsk { store.ask() }
            isQuestionFocused = !store.isGenerating && store.answer == nil && store.errorMessage == nil
        }
        .onDisappear { store.cancel() }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

private struct SideQuestionResult: View {
    @ObservedObject var store: SideQuestionStore
    let sheetHeight: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var revealProgress: CGFloat = 0
    @State private var roundness: CGFloat = 0
    @State private var answerHeight: CGFloat = 248
    @State private var hasFinished = false

    var body: some View {
        result
            .task(id: store.answer) {
                revealProgress = 0
                roundness = 0
                hasFinished = false
                guard store.answer != nil else { return }
                if reduceMotion {
                    revealProgress = 1
                    hasFinished = true
                    return
                }
                do {
                    // Lay out the hidden answer, then stretch the same glass
                    // surface into the leading edge of its reveal mask.
                    try await Task.sleep(for: .milliseconds(60))
                    withAnimation(.easeInOut(duration: 0.45)) { roundness = 1 }
                    try await Task.sleep(for: .milliseconds(450))
                    let duration = min(3, max(1.2, Double(min(answerHeight, sheetHeight)) / 140))
                    withAnimation(.linear(duration: duration)) { revealProgress = 1 }
                    try await Task.sleep(for: .seconds(duration))
                    withAnimation(.easeOut(duration: 0.2)) { hasFinished = true }
                } catch { return }
            }
    }

    @ViewBuilder
    private var result: some View {
        if let error = store.errorMessage {
            Text(verbatim: error)
                .foregroundStyle(.red)
                .accessibilityIdentifier("chat.sideQuestion.error")
            Button("Retry") { store.ask() }
                .accessibilityIdentifier("chat.sideQuestion.retry")
        } else if store.isGenerating || store.answer != nil {
            ZStack(alignment: .topLeading) {
                if let answer = store.answer {
                    VStack(alignment: .leading, spacing: 12) {
                        MarkdownMessageText(text: answer, isUser: false, style: .standard)
                            .textSelection(.enabled)
                            .accessibilityIdentifier("chat.sideQuestion.answer")
                        Button {
                            OpenCodeClipboard.copy(answer)
                        } label: {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                        .accessibilityIdentifier("chat.sideQuestion.copy")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { answerHeight = $0 }
                    .modifier(SideQuestionSweepReveal(progress: revealProgress))
                }
            }
            .frame(maxWidth: .infinity, minHeight: 248, alignment: .topLeading)
            .overlay {
                if !hasFinished {
                    GeometryReader { geometry in
                        SideQuestionGlassBlob(roundness: roundness)
                            .frame(width: 160 + (geometry.size.width - 160) * roundness,
                                   height: 160 - 152 * roundness)
                            .position(x: geometry.size.width / 2,
                                      y: 108 * (1 - roundness) + (answerHeight + 28) * revealProgress)
                        Text("Answering side question...")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .position(x: geometry.size.width / 2, y: 216)
                            .opacity(1 - roundness)
                            .accessibilityHidden(!store.isGenerating)
                            .accessibilityIdentifier("chat.sideQuestion.loading")
                    }
                    .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct SideQuestionSweepReveal: ViewModifier, Animatable {
    nonisolated var progress: CGFloat

    nonisolated var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func body(content: Content) -> some View {
        content
            .mask {
                GeometryReader { geometry in
                    // Opaque above the pill, with one line-height of fading
                    // immediately behind it. Nothing below the pill is shown.
                    let edge = (geometry.size.height + 28) * progress
                    VStack(spacing: 0) {
                        Color.white.frame(height: max(0, edge - 28))
                        LinearGradient(colors: [.white, .clear], startPoint: .top, endPoint: .bottom)
                            .frame(height: min(28, edge))
                    }
                }
            }
    }
}

private struct SideQuestionGlassBlob: View {
    var roundness: CGFloat
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 30, paused: reduceMotion || roundness == 1)) { timeline in
            let time = reduceMotion ? 0 : timeline.date.timeIntervalSinceReferenceDate
                .truncatingRemainder(dividingBy: 20 * .pi)
            let shape = SideQuestionBlobShape(phase: time * 0.8, roundness: roundness)
            Color.clear
                .opencodeGlassSurface(clear: true, in: shape)
        }
        .accessibilityHidden(true)
    }
}

/// Two radial waves form a smoothly closed, slowly changing glass surface.
/// TimelineView supplies time directly; no per-frame observable state is needed.
private struct SideQuestionBlobShape: Shape {
    let phase: Double
    nonisolated var roundness: CGFloat

    nonisolated var animatableData: CGFloat {
        get { roundness }
        set { roundness = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let count = 16
        let radius = min(rect.width, rect.height) * 0.39
        if roundness >= 1 {
            return Capsule().path(in: rect)
        }
        let horizontalRadius = radius + (rect.width / 2 - radius) * roundness
        let verticalRadius = radius + (rect.height / 2 - radius) * roundness
        let points = (0..<count).map { index -> CGPoint in
            let angle = Double(index) * 2 * .pi / Double(count)
            let wave = 1 + (1 - roundness) * (0.12 * sin(3 * angle + phase) + 0.07 * sin(2 * angle - phase * 1.25))
            return CGPoint(x: rect.midX + horizontalRadius * wave * cos(angle),
                           y: rect.midY + verticalRadius * wave * sin(angle))
        }
        var path = Path()
        path.move(to: points[0])
        for index in 0..<count {
            let previous = points[(index + count - 1) % count]
            let start = points[index]
            let end = points[(index + 1) % count]
            let next = points[(index + 2) % count]
            path.addCurve(
                to: end,
                control1: CGPoint(x: start.x + (end.x - previous.x) / 6,
                                  y: start.y + (end.y - previous.y) / 6),
                control2: CGPoint(x: end.x - (next.x - start.x) / 6,
                                  y: end.y - (next.y - start.y) / 6)
            )
        }
        path.closeSubpath()
        return path
    }
}
