import SwiftUI

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

#if canImport(UIKit)
import UIKit
#endif

struct ConnectionView: View {
    @ObservedObject var viewModel: AppViewModel

    private var hasRecentServers: Bool {
        viewModel.recentServerConfigs.isEmpty == false
    }

    private var isScreenshotScene: Bool {
        ProcessInfo.processInfo.environment["OPENCLIENT_SCREENSHOT_SCENE"] != nil
    }

    var body: some View {
        List {
            if hasRecentServers {
                Section("Recent") {
                    ForEach(viewModel.recentServerConfigs, id: \.recentServerID) { serverConfig in
                        ZStack(alignment: .topTrailing) {
                            Button {
                                Task { await viewModel.connect(to: serverConfig) }
                            } label: {
                                RecentServerCard(serverConfig: serverConfig)
                            }
                            .buttonStyle(.plain)
                            .allowsHitTesting(!viewModel.isLoading)
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
                        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                            Button {
                                viewModel.prepareToEditRecentServer(serverConfig)
                            } label: {
                                Label("Edit", systemImage: "square.and.pencil")
                            }
                            .tint(.indigo)

                            Button("Remove", role: .destructive) {
                                viewModel.removeRecentServer(serverConfig)
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                    }
                }
                .listRowSeparator(.hidden)
#if !os(macOS)
                .listRowSpacing(0.0)
#endif
                .padding(.vertical,0)

                if viewModel.isLoading {
                    Section {
                        HStack(spacing: 10) {
                            ProgressView()
                            Text("Connecting to OpenCode...")
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else if let errorMessage = viewModel.errorMessage, !errorMessage.isEmpty {
                    Section("Connection Failed") {
                        Text(errorMessage)
                            .font(.footnote)
                            .foregroundStyle(.red)
                    }
                    .listRowBackground(Color.clear)
                }
            }

            if hasRecentServers == false {
                ServerConnectionSections(viewModel: viewModel)
            }

#if DEBUG
            if !isScreenshotScene {
                DebugEntitlementSection(viewModel: viewModel)
            }
#endif

            Section("Apple Intelligence") {
                Button {
                    viewModel.presentAppleIntelligenceFolderPicker()
                } label: {
                    AppleIntelligenceConnectionCard()
                }
                .buttonStyle(.plain)
                .disabled(!viewModel.canTryAppleIntelligence)
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)

                if let summary = viewModel.appleIntelligenceAvailabilitySummary, !viewModel.canTryAppleIntelligence {
                    Text(summary)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
            }

            Section("Help") {
                NavigationLink {
                    HelpView()
                } label: {
                    HelpNavigationRow()
                }
                .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                .listRowBackground(Color.clear)
                .listRowSeparator(.hidden)
            }

        }
        .connectionListStyle(hasRecentServers: hasRecentServers)
        .navigationTitle("OpenClient")
        .opencodeLargeNavigationTitle()
        .toolbar {
            if hasRecentServers {
                ToolbarItem(placement: .opencodeTrailing) {
                    Button {
                        viewModel.presentAddServerSheet()
                    } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Add Server")
                }
            }
        }
        .sheet(isPresented: $viewModel.isShowingAddServerSheet) {
            NavigationStack {
                List {
                    ServerConnectionSections(viewModel: viewModel)
                }
                .opencodeGroupedListStyle()
                .navigationTitle(viewModel.isEditingSavedServer ? "Edit Server" : "Server")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") {
                            viewModel.dismissAddServerSheet()
                        }
                    }

                    if viewModel.isEditingSavedServer {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Save") {
                                viewModel.saveEditedServer()
                            }
                            .disabled(!viewModel.canSaveEditedServer)
                        }
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
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

#if DEBUG
private struct DebugEntitlementSection: View {
    @ObservedObject var viewModel: AppViewModel

    var body: some View {
        Section {
            OpenClientDebugEntitlementControls(viewModel: viewModel)
                .padding(.vertical, 6)
        } header: {
            Text("Debug")
        } footer: {
            Text("Switch between free, StoreKit, unlocked, and limit-reached states while testing local builds.")
        }
    }
}
#endif

private struct ServerConnectionSections: View {
    private struct ConnectionIconOption: Identifiable {
        let symbolName: String
        let title: String

        var id: String { symbolName }
    }

    private static let iconOptions: [ConnectionIconOption] = [
        ConnectionIconOption(symbolName: "server.rack", title: "Server"),
        ConnectionIconOption(symbolName: "desktopcomputer", title: "Desktop"),
        ConnectionIconOption(symbolName: "laptopcomputer", title: "Laptop"),
        ConnectionIconOption(symbolName: "display", title: "Display"),
        ConnectionIconOption(symbolName: "iphone", title: "iPhone"),
        ConnectionIconOption(symbolName: "ipad.landscape", title: "iPad"),
        ConnectionIconOption(symbolName: "terminal", title: "Terminal"),
        ConnectionIconOption(symbolName: "network", title: "Network"),
        ConnectionIconOption(symbolName: "cloud.fill", title: "Cloud"),
        ConnectionIconOption(symbolName: "internaldrive", title: "Drive"),
        ConnectionIconOption(symbolName: "house", title: "Home"),
        ConnectionIconOption(symbolName: "cube.box.fill", title: "Lab"),
    ]

    @ObservedObject var viewModel: AppViewModel
    @State private var acknowledgesInsecureConnection = false

    private var requiresInsecureConnectionAcknowledgment: Bool {
        viewModel.config.usesInsecureHTTP
    }

    private var insecureConnectionMessage: String {
        switch viewModel.config.insecureConnectionKind {
        case .localNetwork:
            return "`http://` connections are not protected by HTTPS/TLS. This is often acceptable for local, LAN, or Tailscale-based self-hosted setups, but it is still less secure than HTTPS."
        case .nonLocal:
            return "`http://` connections are not protected by HTTPS/TLS. For non-local hosts, your credentials and traffic are better protected when the server is configured with HTTPS."
        case nil:
            return ""
        }
    }

    private var canConnect: Bool {
        !viewModel.isLoading && (!requiresInsecureConnectionAcknowledgment || acknowledgesInsecureConnection)
    }

    var body: some View {
        Group {
            Section {
                TextField("Name", text: $viewModel.config.name)
                    .accessibilityIdentifier("connection.name")

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

                if requiresInsecureConnectionAcknowledgment {
                    Toggle("I understand this connection is insecure", isOn: $acknowledgesInsecureConnection)
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("connection.insecureAck")
                }
            } header: {
                Text("Server")
            } footer: {
                if viewModel.isEditingSavedServer {
                    Text("Save changes to keep this connection handy, or connect now to verify it immediately.")
                } else if requiresInsecureConnectionAcknowledgment {
                    Text(insecureConnectionMessage)
                }
            }

            Section("Icon") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(Self.iconOptions) { option in
                            connectionIconButton(for: option)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 4)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
            }

            Section {
                Button(viewModel.isLoading ? "Connecting..." : "Connect to OpenCode") {
                    Task { await viewModel.connect() }
                }
                .frame(maxWidth: .infinity, alignment: .center)
                .disabled(!canConnect)
                .accessibilityIdentifier("connection.connect")
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .onChange(of: viewModel.config.trimmedBaseURL) { _, _ in
            acknowledgesInsecureConnection = false
        }
    }

    @ViewBuilder
    private func connectionIconButton(for option: ConnectionIconOption) -> some View {
        let isSelected = viewModel.config.displayIconName == option.symbolName

        Button {
            viewModel.config.iconName = option.symbolName
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .fill(isSelected ? Color.accentColor.opacity(0.16) : OpenCodePlatformColor.secondaryGroupedBackground)

                    Image(systemName: option.symbolName)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.accentColor : .primary)
                }
                .frame(height: 54)
                .overlay {
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(isSelected ? Color.accentColor : Color.primary.opacity(0.08), lineWidth: isSelected ? 1.5 : 1)
                }

                Text(option.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(width: 76)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("connection.icon.\(option.symbolName)")
        .accessibilityLabel(option.title)
    }
}

private struct ConnectionListStyleModifier: ViewModifier {
    let hasRecentServers: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
#if os(macOS)
        content.listStyle(.inset)
#else
        if hasRecentServers {
            content
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .background(OpenCodePlatformColor.groupedBackground)
        } else {
            content.listStyle(.insetGrouped)
        }
#endif
    }
}

private extension View {
    func connectionListStyle(hasRecentServers: Bool) -> some View {
        modifier(ConnectionListStyleModifier(hasRecentServers: hasRecentServers))
    }
}

private struct HelpNavigationRow: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.88), Color.blue.opacity(0.78)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "book.closed.fill")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(.white)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                Text("Help & Getting Started")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Learn what OpenCode is, how the app works, and how to connect securely.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer()
        }
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct AppleIntelligenceConnectionCard: View {
    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [Color.purple.opacity(0.22), Color.blue.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Image(systemName: "sparkles")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.purple)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text("Try with Apple Intelligence")
                    .font(.headline)
                    .foregroundStyle(.primary)

                Text("Try a local workspace with on-device Apple Intelligence")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 16)

            Image(systemName: "arrow.up.right.circle.fill")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
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

                Image(systemName: serverConfig.displayIconName)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            .frame(width: 48, height: 48)

            VStack(alignment: .leading, spacing: 4) {
                Text(serverConfig.displayName)
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
        .frame(maxWidth: .infinity, alignment: .leading)
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
