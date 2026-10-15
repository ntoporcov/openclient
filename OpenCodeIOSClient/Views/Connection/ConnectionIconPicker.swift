import SwiftUI

struct ConnectionIconPicker: View {
    @Binding var selection: String
    @Environment(\.appAccentColor) private var accent

    private struct Option: Identifiable {
        let id: String
        let title: LocalizedStringResource
    }

    private static let options: [Option] = [
        .init(id: "server.rack", title: "Server"),
        .init(id: "desktopcomputer", title: "Desktop"),
        .init(id: "laptopcomputer", title: "Laptop"),
        .init(id: "display", title: "Display"),
        .init(id: "iphone", title: "iPhone"),
        .init(id: "ipad.landscape", title: "iPad"),
        .init(id: "terminal", title: "Terminal"),
        .init(id: "network", title: "Network"),
        .init(id: "cloud.fill", title: "Cloud"),
        .init(id: "internaldrive", title: "Drive"),
        .init(id: "house", title: "Home"),
        .init(id: "cube.box.fill", title: "Lab")
    ]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 12) {
                ForEach(Self.options) { option in
                    Button { selection = option.id } label: {
                        VStack(spacing: 8) {
                            Image(systemName: option.id)
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(selection == option.id ? accent : .primary)
                                .frame(width: 76, height: 54)
                                .background(selection == option.id ? accent.opacity(0.16) : OpenCodePlatformColor.secondaryGroupedBackground,
                                            in: RoundedRectangle(cornerRadius: 14))
                                .overlay {
                                    RoundedRectangle(cornerRadius: 14)
                                        .stroke(selection == option.id ? accent : Color.primary.opacity(0.08),
                                                lineWidth: selection == option.id ? 1.5 : 1)
                                }
                            Text(option.title).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        }
                        .frame(width: 76)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(Text(option.title))
                    .accessibilityAddTraits(selection == option.id ? .isSelected : [])
                    .accessibilityIdentifier("connection.icon.\(option.id)")
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 4)
        }
    }
}
