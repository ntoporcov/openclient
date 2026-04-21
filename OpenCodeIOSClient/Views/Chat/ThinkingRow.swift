import SwiftUI

struct ThinkingRow: View {
    @State private var phase = false

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
        .task {
            withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                phase.toggle()
            }
        }
    }
}
