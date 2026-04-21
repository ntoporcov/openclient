import SwiftUI

struct DetailTextBlock: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.system(.body, design: .monospaced))
            .textSelection(.enabled)
    }
}
