import SwiftUI

struct PermissionActionStack: View {
    let permissions: [OpenCodePermission]
    let onDismiss: (OpenCodePermission) -> Void
    let onRespond: (OpenCodePermission, String) -> Void

    var body: some View {
        VStack(spacing: 10) {
            ForEach(permissions) { permission in
                PermissionCard(permission: permission, onDismiss: onDismiss, onRespond: onRespond)
            }
        }
    }
}
