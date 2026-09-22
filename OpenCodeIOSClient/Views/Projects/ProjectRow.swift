import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

struct ProjectRow: View {
    let title: String
    let subtitle: String
    let systemImage: String
    var icon: OpenCodeProject.Icon? = nil
    var usesSystemImageFallback = false
    let isSelected: Bool
    var isPreparing = false
    var subtitleLineLimit = 1

    var body: some View {
        HStack(spacing: 12) {
            ProjectAvatar(title: title, systemImage: systemImage, icon: icon, usesSystemImageFallback: usesSystemImageFallback, isSelected: isSelected)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(subtitleLineLimit)
            }

            Spacer()

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .accessibilityLabel("Opening \(title)")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .animation(opencodeSelectionAnimation, value: isSelected)
    }
}

struct ProjectAvatar: View {
    let title: String
    let systemImage: String
    let icon: OpenCodeProject.Icon?
    let usesSystemImageFallback: Bool
    let isSelected: Bool
    var size: CGFloat = 30

    var body: some View {
        ZStack {
            if let source = iconImageSource {
                ProjectAvatarImage(source: source, fallback: fallbackAvatar)
            } else {
                fallbackAvatar
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.27, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: size * 0.27, style: .continuous)
                .strokeBorder(borderColor, lineWidth: isSelected ? 2 : 1)
        }
    }

    private var iconImageSource: String? {
        [icon?.override, icon?.url]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty }
    }

    private var fallbackAvatar: some View {
        let colors = ProjectAvatarColors.colors(for: icon?.color)
        return ZStack {
            colors.background
            if usesSystemImageFallback || title == "Global" {
                Image(systemName: systemImage)
                    .font(.system(size: size * 0.47, weight: .semibold))
                    .foregroundStyle(colors.foreground)
            } else {
                Text(projectInitial)
                    .font(.system(size: size * 0.43, weight: .bold, design: .rounded))
                    .foregroundStyle(colors.foreground)
            }
        }
    }

    private var projectInitial: String {
        title.trimmingCharacters(in: .whitespacesAndNewlines).first.map { String($0).uppercased() } ?? "?"
    }

    private var borderColor: Color {
        if isSelected { return .accentColor.opacity(0.75) }
        return ProjectAvatarColors.colors(for: icon?.color).background.opacity(0.28)
    }
}

struct ProjectSelectionCard: View {
    let project: OpenCodeProject
    let title: String
    let isSelected: Bool
    var compact = false

    var body: some View {
        VStack(spacing: compact ? 6 : 10) {
            ProjectAvatar(
                title: title,
                systemImage: project.id == "global" ? "globe" : "folder.fill",
                icon: project.icon,
                usesSystemImageFallback: project.id == "global",
                isSelected: isSelected,
                size: compact ? 36 : 48
            )
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(compact ? 1 : 2)
                .truncationMode(.tail)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: compact ? 76 : 116)
        .padding(compact ? 9 : 12)
        .contentShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .opencodeConcentricGlassSurface(
            isInteractive: !compact,
            minimumCornerRadius: 20,
            in: RoundedRectangle(cornerRadius: 20, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(Color.accentColor.opacity(isSelected ? 0.82 : 0), lineWidth: 2)
        }
        .animation(opencodeSelectionAnimation, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

private struct ProjectAvatarImage<Fallback: View>: View {
    let source: String
    let fallback: Fallback

    var body: some View {
        if let image = platformImage(from: source) {
            platformImageView(image)
                .resizable()
                .scaledToFill()
        } else if let url = URL(string: source), url.scheme?.hasPrefix("http") == true {
            AsyncImage(url: url) { phase in
                switch phase {
                case let .success(image):
                    image.resizable().scaledToFill()
                default:
                    fallback
                }
            }
        } else {
            fallback
        }
    }
}

private enum ProjectAvatarColors {
    static func colors(for value: String?) -> (background: Color, foreground: Color) {
        switch value?.lowercased() {
        case "pink":
            return (Color(red: 0.96, green: 0.45, blue: 0.70), .white)
        case "mint":
            return (Color(red: 0.25, green: 0.82, blue: 0.62), Color.black.opacity(0.78))
        case "orange":
            return (Color(red: 0.98, green: 0.57, blue: 0.24), .white)
        case "purple":
            return (Color(red: 0.58, green: 0.45, blue: 0.86), .white)
        case "cyan":
            return (Color(red: 0.13, green: 0.79, blue: 0.89), Color.black.opacity(0.78))
        case "lime":
            return (Color(red: 0.62, green: 0.82, blue: 0.20), Color.black.opacity(0.78))
        case let hex?:
            if let color = Color(hexString: hex) {
                return (color, .white)
            }
            fallthrough
        default:
            return (.blue.opacity(0.16), .blue)
        }
    }
}

private extension Color {
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = Int(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255.0,
            green: Double((value >> 8) & 0xFF) / 255.0,
            blue: Double(value & 0xFF) / 255.0
        )
    }
}

#if canImport(UIKit)
private func platformImage(from dataURL: String) -> UIImage? {
    guard let comma = dataURL.firstIndex(of: ","), dataURL[..<comma].contains("base64") else { return nil }
    let payload = String(dataURL[dataURL.index(after: comma)...])
    guard let data = Data(base64Encoded: payload) else { return nil }
    return UIImage(data: data)
}

private func platformImageView(_ image: UIImage) -> Image {
    Image(uiImage: image)
}
#elseif canImport(AppKit)
private func platformImage(from dataURL: String) -> NSImage? {
    guard let comma = dataURL.firstIndex(of: ","), dataURL[..<comma].contains("base64") else { return nil }
    let payload = String(dataURL[dataURL.index(after: comma)...])
    guard let data = Data(base64Encoded: payload) else { return nil }
    return NSImage(data: data)
}

private func platformImageView(_ image: NSImage) -> Image {
    Image(nsImage: image)
}
#else
private func platformImage(from dataURL: String) -> Never? { nil }
#endif
