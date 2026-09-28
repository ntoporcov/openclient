import SwiftUI

struct PermissionCard: View {
    let permission: OpenCodePermission
    let onDismiss: (OpenCodePermission) -> Void
    let onRespond: (OpenCodePermission, String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "hand.raised.fill")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.orange)

                VStack(alignment: .leading, spacing: 4) {
                    Text(permission.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)

                    Text(permission.summary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }

            VStack(spacing: 8) {
                Button {
                    onRespond(permission, "always")
                } label: {
                    Text("Always")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .modifier(AppAccentActionModifier())
                .opencodePrimaryGlassButton()
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)

                Button {
                    onRespond(permission, "allow")
                } label: {
                    Text("Once")
                        .frame(maxWidth: .infinity)
                }
                .controlSize(.large)
                .buttonStyle(.bordered)
                .tint(.primary)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 44)

                HStack(spacing: 8) {
                    Button {
                        onRespond(permission, "deny")
                    } label: {
                        HStack {
                            Spacer()
                            Text("Reject")
                            Spacer()
                        }
                        .padding(.vertical, 7)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)

                    Button {
                        onDismiss(permission)
                    } label: {
                        HStack {
                            Spacer()
                            Text("Later")
                            Spacer()
                        }
                        .padding(.vertical, 7)
                    }
                    .frame(maxWidth: .infinity)
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(14)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
