import SwiftUI

struct MarkdownMessageText: View {
    enum Style {
        case standard
        case reasoning
    }

    let text: String
    let isUser: Bool
    let style: Style

    var body: some View {
        switch style {
        case .standard:
            content
                .padding(.vertical, isUser ? 0 : 10)
        case .reasoning:
            content
        }
    }

    private var content: some View {
        if let attributed = try? AttributedString(
            markdown: text,
            options: AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) {
            Text(attributed)
                .font(textFont)
                .foregroundStyle(textForegroundStyle)
                .lineSpacing(textLineSpacing)
                .textSelection(.enabled)
        } else {
            Text(text)
                .font(textFont)
                .foregroundStyle(textForegroundStyle)
                .lineSpacing(textLineSpacing)
                .textSelection(.enabled)
        }
    }

    private var textFont: Font {
        switch style {
        case .standard:
            return .body
        case .reasoning:
            return .caption
        }
    }

    private var textForegroundStyle: Color {
        if isUser {
            return .white
        }

        switch style {
        case .standard:
            return .primary
        case .reasoning:
            return .secondary
        }
    }

    private var textLineSpacing: CGFloat {
        switch style {
        case .standard:
            return isUser ? 1 : 3
        case .reasoning:
            return 2
        }
    }
}
