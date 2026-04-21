import SwiftUI

struct MessageComposer: View {
    @Binding var text: String
    let isSending: Bool
    let onSend: () -> Void

    private var canSend: Bool {
        !isSending && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("Message", text: $text, axis: .vertical)
                .lineLimit(1 ... 6)
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .accessibilityIdentifier("chat.input")

            Button(action: onSend) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(canSend ? .primary : .secondary)
                    .frame(width: 32, height: 32)
            }
            .opencodePrimaryGlassButton()
            .disabled(!canSend)
            .accessibilityIdentifier("chat.send")
        }
        .shadow(color: .black.opacity(0.06), radius: 12, y: 3)
    }
}
