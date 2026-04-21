import SwiftUI

struct PermissionCard: View {
    let permission: OpenCodePermission
    let onDismiss: (OpenCodePermission) -> Void
    let onRespond: (OpenCodePermission, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "hand.raised.fill")
                    .foregroundStyle(.orange)
                Text(permission.title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)
            }

            Text(permission.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)

            VStack(spacing: 8) {
                Button("Allow") {
                    onRespond(permission, "allow")
                }
                .opencodePrimaryGlassButton()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                HStack(spacing: 8) {
                    Button("Deny") {
                        onRespond(permission, "deny")
                    }
                    .opencodeGlassButton(clear: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))

                    Button("Later") {
                        onDismiss(permission)
                    }
                    .opencodeGlassButton(clear: true)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 12)
        .frame(width: 260, alignment: .leading)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 20, style: .continuous))
    }
}
