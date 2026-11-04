import SwiftUI

/// The loading view owns only the current round. The best result persists locally.
struct DesktopLoadingGame: View {
    @StateObject private var records: DesktopReactionRecordStore
    @Environment(\.scenePhase) private var scenePhase
    @State private var playing = false
    @State private var round = 0
    @State private var appearedAt: ContinuousClock.Instant?
    @State private var position = UnitPoint.center
    @State private var lastMilliseconds: Int?

    init(defaults: UserDefaults = .standard) {
        _records = StateObject(wrappedValue: DesktopReactionRecordStore(defaults: defaults))
    }

    var body: some View {
        GeometryReader { geometry in
            let landscape = geometry.size.width > geometry.size.height
            ZStack {
                VStack(spacing: 12) {
                    ProgressView("Connecting to desktop…")
                    if landscape {
                        if let best = records.bestMilliseconds {
                            Text("Best: \(best) ms").monospacedDigit()
                                .accessibilityIdentifier("remote-desktop.game.best")
                        }
                        if let lastMilliseconds {
                            Text("Last: \(lastMilliseconds) ms").monospacedDigit()
                                .accessibilityIdentifier("remote-desktop.game.last")
                        }
                        if playing {
                            Text("Tap the icon as soon as it appears.")
                        } else {
                            Button("Play while connecting") { playing = true; round += 1 }
                                .buttonStyle(.bordered)
                                .accessibilityIdentifier("remote-desktop.game.start")
                        }
                    }
                }
                .padding()
                .allowsHitTesting(!playing)
                if landscape, playing, appearedAt != nil {
                    Button(action: hitTarget) {
                        Image(systemName: "bolt.circle.fill")
                            .font(.system(size: 48))
                            .frame(width: 64, height: 64)
                            .background(.regularMaterial, in: Circle())
                            .contentShape(Circle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Tap the target")
                    .accessibilityIdentifier("remote-desktop.game.target")
                    .position(
                        x: 40 + max(0, geometry.size.width - 80) * position.x,
                        y: 40 + max(0, geometry.size.height - 80) * position.y
                    )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .task(id: round) {
                guard playing, landscape, scenePhase == .active else { return }
                do { try await Task.sleep(for: .milliseconds(Int.random(in: 500...1_500))) }
                catch { return }
                guard !Task.isCancelled else { return }
                position = UnitPoint(x: Double.random(in: 0...1), y: Double.random(in: 0...1))
                appearedAt = .now
            }
            .onChange(of: landscape) { _, _ in stop() }
            .onChange(of: scenePhase) { _, phase in if phase != .active { stop() } }
        }
        .foregroundStyle(.white)
        .tint(.white)
    }

    private func hitTarget() {
        guard let appearedAt else { return }
        let elapsed = appearedAt.duration(to: .now).components
        let milliseconds = Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)
        self.appearedAt = nil
        lastMilliseconds = milliseconds
        records.record(milliseconds: milliseconds)
        round += 1
    }

    private func stop() {
        playing = false
        appearedAt = nil
        round += 1
    }
}
