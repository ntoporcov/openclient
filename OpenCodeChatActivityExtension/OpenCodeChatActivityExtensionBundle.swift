import SwiftUI
import WidgetKit

@main
struct OpenCodeChatActivityExtensionBundle: WidgetBundle {
    var body: some Widget {
        OpenCodeChatActivityWidget()
        OpenCodeTalkActivityWidget()
        OpenCodeRecentSessionsWidget()
        OpenCodePinnedSessionsWidget()
        OpenCodeActionShortcutWidget()
        OpenCodeNewSessionShortcutWidget()
        if #available(iOS 18.0, *) {
            OpenCodeActionControlWidget()
            OpenCodeNewSessionControlWidget()
        }
    }
}
