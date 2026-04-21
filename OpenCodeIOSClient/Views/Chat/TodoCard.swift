import SwiftUI

struct TodoCard: View {
    let todo: OpenCodeTodo

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: iconName)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 22, height: 22)

            VStack(alignment: .leading, spacing: 4) {
                Text(todo.content)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(todo.status.replacingOccurrences(of: "_", with: " ").capitalized)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 220, alignment: .leading)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(borderColor, lineWidth: todo.isInProgress ? 1.2 : 0.8)
        }
    }

    private var iconName: String {
        if todo.isComplete { return "checkmark.circle.fill" }
        if todo.isInProgress { return "clock.badge" }
        return "circle"
    }

    private var iconColor: Color {
        if todo.isComplete { return .green }
        if todo.isInProgress { return .blue }
        return .secondary
    }

    private var borderColor: Color {
        if todo.isInProgress { return .blue.opacity(0.35) }
        if todo.isComplete { return .green.opacity(0.25) }
        return Color.black.opacity(0.06)
    }
}
