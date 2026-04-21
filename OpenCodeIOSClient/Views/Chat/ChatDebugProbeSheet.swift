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
                            #if canImport(UIKit)
                            UIPasteboard.general.string = viewModel.copyDebugProbeLog()
                            #endif
                            copiedDebugLog = true
                        }
                        .buttonStyle(.bordered)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                ScrollView {
                    Text(viewModel.debugProbeLog.isEmpty ? "No probe log yet." : viewModel.copyDebugProbeLog())
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                }
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Debug Probe")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
}
