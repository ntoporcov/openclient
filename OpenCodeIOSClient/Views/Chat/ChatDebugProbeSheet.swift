import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ChatDebugProbeSheet: View {
    @ObservedObject var viewModel: AppViewModel
    @Binding var copiedDebugLog: Bool

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run a streaming probe on this chat. It will auto-send a test prompt and collect a timestamped log you can copy back.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button(viewModel.isRunningDebugProbe ? "Running..." : "Start Probe") {
                            Task { await viewModel.startDebugProbe() }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(viewModel.isRunningDebugProbe)

                        Button(copiedDebugLog ? "Copied" : "Copy Log") {
                            OpenCodeClipboard.copy(debugText)
                            copiedDebugLog = true
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("debugProbe.copy")
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                ScrollView {
                    Text(debugText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("debugProbe.log")
                }
                .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Debug Probe")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Close") {
                        viewModel.isShowingDebugProbe = false
                    }
                }
            }
        }
        .onChange(of: viewModel.debugProbeLog.count) { _, _ in
            copiedDebugLog = false
        }
    }

    private var debugText: String {
        let probe = viewModel.debugProbeLog.isEmpty ? "No probe log yet." : viewModel.copyDebugProbeLog()
        let breadcrumbs = viewModel.chatBreadcrumbs.isEmpty ? "No chat breadcrumbs yet." : viewModel.copyChatBreadcrumbs()
        return ["Probe Log", probe, "", "Chat Breadcrumbs", breadcrumbs].joined(separator: "\n")
    }
}
