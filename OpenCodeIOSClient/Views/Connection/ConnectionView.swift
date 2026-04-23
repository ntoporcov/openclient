import SwiftUI

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
import UIKit
#endif

struct ConnectionView: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        List {
            if viewModel.showSavedServerPrompt {
                Section("Recent") {
                    ForEach(viewModel.recentServerConfigs, id: \.recentServerID) { serverConfig in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                Task { await viewModel.connect(to: serverConfig) }
                            } label: {
                                RecentServerCard(serverConfig: serverConfig)
                            }
                            .buttonStyle(.plain)
                            .disabled(viewModel.isLoading)
                            .contextMenu {
                                Button {
                                    viewModel.prepareToEditRecentServer(serverConfig)
                                } label: {
                                    Label("Edit", systemImage: "square.and.pencil")
                                }

                                Button(role: .destructive) {
                                    viewModel.removeRecentServer(serverConfig)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                            Button("Remove", role: .destructive) {
                                viewModel.removeRecentServer(serverConfig)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 0, bottom: 6, trailing: 0))
                        .listRowBackground(Color.clear)
                    }
                }
                .listRowSeparator(.hidden)
#if !os(macOS)
                .listRowSpacing(0.0)
#endif
                .padding(.horizontal,1)
                .padding(.vertical,0)
            }

            Section("Server") {
                TextField("Base URL", text: $viewModel.config.baseURL)
                    .opencodeDisableTextAutocapitalization()
                    .autocorrectionDisabled()
                    .opencodeURLKeyboardType()
                    .accessibilityIdentifier("connection.baseURL")

                TextField("Username", text: $viewModel.config.username)
                    .opencodeDisableTextAutocapitalization()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("connection.username")

                SecureField("Password", text: $viewModel.config.password)
                    .accessibilityIdentifier("connection.password")
            }

            Section {
                Button(viewModel.isLoading ? "Connecting..." : "Connect to OpenCode") {
                    Task { await viewModel.connect() }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(viewModel.isLoading)
                .accessibilityIdentifier("connection.connect")
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Apple Intelligence") {
                Button {
                    viewModel.presentAppleIntelligenceFolderPicker()
                } label: {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Try with Apple Intelligence")
                            .font(.headline)
                        Text("Don't have OpenCode? You can try some of our functionality with on-device Apple Intelligence")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .disabled(!viewModel.canTryAppleIntelligence)

                if let summary = viewModel.appleIntelligenceAvailabilitySummary, !viewModel.canTryAppleIntelligence {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .opencodeGroupedListStyle()
        .opencodeLargeNavigationTitle()
        .sheet(isPresented: $viewModel.isShowingAppleIntelligenceFolderPicker) {
#if canImport(UIKit) && canImport(UniformTypeIdentifiers)
            AppleIntelligenceFolderPicker { url in
                viewModel.isShowingAppleIntelligenceFolderPicker = false
                guard let url else { return }
                Task { await viewModel.createAppleIntelligenceWorkspace(from: url) }
            }
#else
            Text("Folder picking is unavailable on this platform.")
                .presentationDetents([.medium])
#endif
        }
    }
}

#if canImport(UIKit) && canImport(UniformTypeIdentifiers)
private struct AppleIntelligenceFolderPicker: UIViewControllerRepresentable {
    let onPick: (URL?) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onPick: onPick)
    }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [UTType.folder], asCopy: false)
        picker.delegate = context.coordinator
        picker.allowsMultipleSelection = false
        picker.shouldShowFileExtensions = true
        return picker
    }

    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: (URL?) -> Void

        init(onPick: @escaping (URL?) -> Void) {
            self.onPick = onPick
        }

        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls.first)
        }

        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onPick(nil)
        }
    }
}
#endif

private struct RecentServerCard: View {
    let serverConfig: OpenCodeServerConfig

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.accentColor.opacity(0.22), Color.accentColor.opacity(0.08)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "server.rack")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(serverConfig.displayHost)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text(serverConfig.trimmedBaseURL)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                Text(serverConfig.trimmedUsername)
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Spacer(minLength: 52)

            Image(systemName: "arrow.up.right.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(OpenCodePlatformColor.secondaryGroupedBackground)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}
