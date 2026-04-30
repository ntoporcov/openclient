import SwiftUI
#if canImport(UIKit)
import UIKit
#endif
#if canImport(PhotosUI) && canImport(UIKit)
import Photos
import PhotosUI
import UniformTypeIdentifiers
#endif

struct MessageComposer: View {
    private enum AccessoryDestination: Hashable {
        case fork
        case mcp
    }

    @Binding var text: String
    @Binding var isAccessoryMenuOpen: Bool
    let commands: [OpenCodeCommand]
    let attachmentCount: Int
    let isBusy: Bool
    let canFork: Bool
    let forkableMessages: [OpenCodeForkableMessage]
    let mcpServers: [OpenCodeMCPServer]
    let connectedMCPServerCount: Int
    let isLoadingMCP: Bool
    let togglingMCPServerNames: Set<String>
    let mcpErrorMessage: String?
    let onInputFrameChange: (CGRect) -> Void
    let onFocusChange: (Bool) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onSelectCommand: (OpenCodeCommand) -> Void
    let onCompact: () -> Void
    let onForkMessage: (String) -> Void
    let onLoadMCP: () -> Void
    let onToggleMCP: (String) -> Void
    let onAddAttachments: ([OpenCodeComposerAttachment]) -> Void

    @State private var selectedCommandName: String?
    @State private var accessorySheetDetent: PresentationDetent = .height(315)
    @State private var accessoryNavigationPath: [AccessoryDestination] = []
    @Namespace private var accessoryGlassNamespace
#if canImport(PhotosUI) && canImport(UIKit)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
    @State private var recentPhotoAssets: [PHAsset] = []
    @State private var recentPhotoThumbnails: [String: UIImage] = [:]
    @State private var isShowingPhotosPicker = false
    @State private var isShowingFileImporter = false
#endif

    private var hasDraftContent: Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || attachmentCount > 0
    }

    private var showsSendAction: Bool {
        hasDraftContent || !isBusy
    }

    private var canSend: Bool {
        hasDraftContent
    }

    private var canStop: Bool {
        isBusy
    }

    private var canInsertCommandShortcut: Bool {
        text.isEmpty && attachmentCount == 0 && !isBusy
    }

    private var slashQuery: String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "/" else { return nil }
        let body = String(trimmed.dropFirst())
        guard !body.contains(where: { $0.isWhitespace }) else { return nil }
        return body
    }

    private var filteredCommands: [OpenCodeCommand] {
        guard let query = slashQuery else { return [] }
        if query.isEmpty {
            return commands.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        }

        return commands
            .filter { command in
                command.name.localizedCaseInsensitiveContains(query) ||
                    (command.description?.localizedCaseInsensitiveContains(query) ?? false)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    private var selectedCommand: OpenCodeCommand? {
        if let selectedCommandName {
            return filteredCommands.first(where: { $0.name == selectedCommandName })
        }
        return filteredCommands.first
    }

    private var showsCommandPicker: Bool {
        slashQuery != nil && !isBusy
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if showsCommandPicker {
                CommandPicker(
                    commands: filteredCommands,
                    selectedCommandName: selectedCommand?.name,
                    onSelect: { command in
                        onSelectCommand(command)
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            #if os(macOS)
            macComposer
            #else
            iosComposer
            #endif
        }
        .onAppear {
            syncSelectedCommand()
        }
        .onChange(of: text) { _, _ in
            syncSelectedCommand()
            if !text.isEmpty {
                isAccessoryMenuOpen = false
            }
        }
        .onChange(of: isBusy) { _, busy in
            if busy {
                isAccessoryMenuOpen = false
            }
        }
        .onChange(of: isAccessoryMenuOpen) { _, isOpen in
            if isOpen {
                accessorySheetDetent = .height(315)
                accessoryNavigationPath = []
            }
        }
        .onPreferenceChange(ComposerInputFramePreferenceKey.self) { frame in
            guard frame != .zero else { return }
            onInputFrameChange(frame)
        }
#if canImport(PhotosUI) && canImport(UIKit)
        .onChange(of: selectedPhotoItems) { _, _ in
            Task { await loadSelectedPhotoItems() }
        }
        .onChange(of: isAccessoryMenuOpen) { _, isOpen in
            guard isOpen else { return }
            Task { await loadRecentPhotosIfAllowed() }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importSelectedFiles(result)
        }
        .photosPicker(
            isPresented: $isShowingPhotosPicker,
            selection: $selectedPhotoItems,
            maxSelectionCount: 10,
            matching: .images
        )
#endif
        .animation(opencodeSelectionAnimation, value: filteredCommands.map(\.name).joined(separator: "|"))
        .animation(opencodeSelectionAnimation, value: isAccessoryMenuOpen)
    }

    #if os(macOS)
    private var macComposer: some View {
        HStack(alignment: .bottom, spacing: 12) {
            TextField("Message", text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.body)
                .lineLimit(1 ... 8)
                .padding(.horizontal, 16)
                .padding(.vertical, 13)
                .frame(minHeight: 46)
                .accessibilityIdentifier("chat.input")

            Button(action: showsSendAction ? onSend : onStop) {
                Image(systemName: showsSendAction ? "arrow.up" : "stop.fill")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(.white.opacity((showsSendAction ? canSend : canStop) ? 1 : 0.78))
                    .frame(width: 18, height: 18)
                    .frame(width: 40, height: 40)
                    .background {
                        Circle()
                            .fill(
                                LinearGradient(
                                    colors: [Color.accentColor.opacity(0.96), Color.accentColor.opacity(0.74)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                    .overlay {
                        Circle()
                            .strokeBorder(Color.white.opacity(0.18), lineWidth: 1)
                    }
                    .shadow(color: .black.opacity((showsSendAction ? canSend : canStop) ? 0.18 : 0.10), radius: 10, y: 4)
                    .opacity((showsSendAction ? canSend : canStop) ? 1 : 0.6)
            }
            .buttonStyle(.plain)
            .disabled(isBusy)
            .disabled(showsSendAction ? !canSend : !canStop)
            .accessibilityLabel(showsSendAction ? "Send" : "Stop")
            .accessibilityIdentifier(showsSendAction ? "chat.send" : "chat.stop")
        }
        .padding(6)
        .background(
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(Color.clear)
        )
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.10), radius: 16, y: 6)
        .animation(opencodeSelectionAnimation, value: isBusy)
        .animation(opencodeSelectionAnimation, value: canSend)
    }
    #endif

    private var iosComposer: some View {
        ZStack(alignment: .bottomLeading) {
            HStack(alignment: .bottom, spacing: 8) {
                Color.clear
                    .frame(width: 36, height: 34)

                #if canImport(UIKit)
                ComposerTextView(
                    text: $text,
                    placeholder: "Message",
                    maxLines: 6,
                    onFocusChange: onFocusChange
                )
                    .frame(minHeight: ComposerTextViewMetrics.minimumHeight)
                    .contentShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: ComposerInputFramePreferenceKey.self, value: geometry.frame(in: .named("chat-view-space")))
                        }
                    }
                    .accessibilityIdentifier("chat.input")
                #else
                TextField("Message", text: $text, axis: .vertical)
                    .lineLimit(1 ... 6)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                    .background {
                        GeometryReader { geometry in
                            Color.clear
                                .preference(key: ComposerInputFramePreferenceKey.self, value: geometry.frame(in: .named("chat-view-space")))
                        }
                    }
                    .accessibilityIdentifier("chat.input")
                    .simultaneousGesture(TapGesture().onEnded {
                        dismissAccessoryMenu()
                    })
                #endif

                Button(action: showsSendAction ? onSend : onStop) {
                    Image(systemName: showsSendAction ? "arrow.up" : "stop.fill")
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle((showsSendAction ? canSend : canStop) ? .primary : .secondary)
                        .frame(width: 32, height: 32)
                }
                .opencodePrimaryGlassButton()
                .disabled(showsSendAction ? !canSend : !canStop)
                .accessibilityLabel(showsSendAction ? "Send" : "Stop")
                .accessibilityIdentifier(showsSendAction ? "chat.send" : "chat.stop")
            }
            .zIndex(0)
            .shadow(color: .black.opacity(0.12), radius: 16, y: 5)

            accessoryContainer
                .zIndex(2)

        }
        .animation(opencodeSelectionAnimation, value: isBusy)
        .animation(opencodeSelectionAnimation, value: canSend)
        .animation(opencodeSelectionAnimation, value: isAccessoryMenuOpen)
        .sheet(isPresented: $isAccessoryMenuOpen) {
            NavigationStack(path: $accessoryNavigationPath) {
                accessorySheetContent
                    .navigationTitle("Message Tools")
                    .navigationBarTitleDisplayMode(.inline)
                    .navigationDestination(for: AccessoryDestination.self) { destination in
                        switch destination {
                        case .fork:
                            ComposerForkListView(
                                messages: forkableMessages,
                                onForkMessage: { messageID in
                                    isAccessoryMenuOpen = false
                                    onForkMessage(messageID)
                                }
                            )
                        case .mcp:
                            ComposerMCPListView(
                                servers: mcpServers,
                                connectedCount: connectedMCPServerCount,
                                isLoading: isLoadingMCP,
                                togglingServerNames: togglingMCPServerNames,
                                errorMessage: mcpErrorMessage,
                                onLoad: onLoadMCP,
                                onToggle: onToggleMCP
                            )
                        }
                    }
            }
            .presentationDetents([.height(315), .height(460), .large], selection: $accessorySheetDetent)
        }
    }

    private var accessoryContainer: some View {
        collapsedAccessoryButton
    }

    private func dismissAccessoryMenu() {
        if isAccessoryMenuOpen {
            withAnimation(opencodeSelectionAnimation) {
                isAccessoryMenuOpen = false
            }
        }
    }

    private var collapsedAccessoryButton: some View {
        Button {
            OpenCodeHaptics.impact(.soft)
            withAnimation(opencodeSelectionAnimation) {
                isAccessoryMenuOpen = true
            }
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 18, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 28, height: 28)
        }
        .composerPlusButtonStyle()
        .accessibilityLabel("Open composer menu")
        .accessibilityIdentifier("chat.composer.menu")
        .frame(width: 34, height: 34)
        .contentShape(Circle())
        .opencodeToolbarGlassID("composer-plus-menu", in: accessoryGlassNamespace)
        .shadow(color: .black.opacity(0.12), radius: 14, y: 4)
        .offset(y: -5)
    }

    private var expandedAccessoryMenu: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 10) {
#if canImport(PhotosUI) && canImport(UIKit)
                AccessorySectionTitle("Attachments")

                recentPhotosStrip

                HStack(spacing: 10) {
                    AccessoryMenuAction(
                        title: "Photos",
                        subtitle: "Add images",
                        systemImage: "photo.on.rectangle.angled",
                        tint: .pink,
                        isDisabled: isBusy,
                        accessibilityIdentifier: "chat.composer.photos",
                        action: {
                            isAccessoryMenuOpen = false
                            DispatchQueue.main.async {
                                isShowingPhotosPicker = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)

                    AccessoryMenuAction(
                        title: "Files",
                        subtitle: "Add files",
                        systemImage: "doc.badge.plus",
                        tint: .orange,
                        isDisabled: isBusy,
                        accessibilityIdentifier: "chat.composer.files",
                        action: {
                            isAccessoryMenuOpen = false
                            DispatchQueue.main.async {
                                isShowingFileImporter = true
                            }
                        }
                    )
                    .frame(maxWidth: .infinity)
                }
#endif

                AccessorySectionTitle("Utilities")

                AccessoryMenuAction(
                    title: "MCP",
                    subtitle: "Toggle servers",
                    systemImage: "server.rack",
                    tint: .indigo,
                    isDisabled: false,
                    accessibilityIdentifier: "chat.composer.mcp",
                    action: {
                        expandAccessorySheetForNestedContentIfNeeded()
                        accessoryNavigationPath.append(.mcp)
                    }
                )

                AccessoryMenuAction(
                    title: "Commands",
                    subtitle: "Insert slash command",
                    systemImage: "chevron.left.forwardslash.chevron.right",
                    tint: .blue,
                    isDisabled: !canInsertCommandShortcut,
                    action: insertSlashCommand
                )

                AccessoryMenuAction(
                    title: "Compact",
                    subtitle: "Summarize context",
                    systemImage: "rectangle.compress.vertical",
                    tint: .teal,
                    isDisabled: isBusy,
                    action: {
                        isAccessoryMenuOpen = false
                        onCompact()
                    }
                )

                AccessoryMenuAction(
                    title: "Fork",
                    subtitle: "Start from a message",
                    systemImage: "arrow.triangle.branch",
                    tint: .purple,
                    isDisabled: isBusy || !canFork,
                    action: {
                        expandAccessorySheetForNestedContentIfNeeded()
                        accessoryNavigationPath.append(.fork)
                    }
                )
            }
            .padding(.horizontal, 20)
            .padding(.top, 20)
            .padding(.bottom, 28)
        }
    }

#if canImport(PhotosUI) && canImport(UIKit)
    @ViewBuilder
    private var recentPhotosStrip: some View {
        if !recentPhotoAssets.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(recentPhotoAssets, id: \.localIdentifier) { asset in
                        Button {
                            attachRecentPhoto(asset)
                        } label: {
                            Group {
                                if let image = recentPhotoThumbnails[asset.localIdentifier] {
                                    Image(uiImage: image)
                                        .resizable()
                                        .scaledToFill()
                                } else {
                                    Rectangle()
                                        .fill(.regularMaterial)
                                        .overlay {
                                            Image(systemName: "photo")
                                                .font(.callout.weight(.semibold))
                                                .foregroundStyle(.secondary)
                                        }
                                }
                            }
                            .frame(width: 76, height: 76)
                            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                            .shadow(color: .black.opacity(0.08), radius: 8, y: 3)
                        }
                        .buttonStyle(.plain)
                        .disabled(isBusy)
                        .accessibilityLabel("Attach recent photo")
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 2)
            }
            .padding(.horizontal, -20)
            .padding(.bottom, 4)
        }
    }
#endif

    private var accessorySheetContent: some View {
        expandedAccessoryMenu
    }

    private func expandAccessorySheetForNestedContentIfNeeded() {
        if accessorySheetDetent == .height(315) {
            accessorySheetDetent = .height(460)
        }
    }

    private func syncSelectedCommand() {
        guard showsCommandPicker else {
            selectedCommandName = nil
            return
        }

        if let selectedCommandName,
           filteredCommands.contains(where: { $0.name == selectedCommandName }) {
            return
        }

        selectedCommandName = filteredCommands.first?.name
    }

    private func insertSlashCommand() {
        guard canInsertCommandShortcut else { return }
        text = "/"
        isAccessoryMenuOpen = false
    }

#if canImport(PhotosUI) && canImport(UIKit)
    private func loadRecentPhotosIfAllowed() async {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        let authorizedStatus: PHAuthorizationStatus

        if status == .notDetermined {
            authorizedStatus = await withCheckedContinuation { continuation in
                PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                    continuation.resume(returning: status)
                }
            }
        } else {
            authorizedStatus = status
        }

        guard authorizedStatus == .authorized || authorizedStatus == .limited else {
            recentPhotoAssets = []
            recentPhotoThumbnails = [:]
            return
        }

        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        options.fetchLimit = 12
        let result = PHAsset.fetchAssets(with: .image, options: options)
        var assets: [PHAsset] = []
        result.enumerateObjects { asset, _, _ in
            assets.append(asset)
        }

        recentPhotoAssets = assets
        await loadRecentPhotoThumbnails(for: assets)
    }

    private func loadRecentPhotoThumbnails(for assets: [PHAsset]) async {
        var thumbnails: [String: UIImage] = [:]

        for asset in assets {
            if let image = await requestThumbnail(for: asset) {
                thumbnails[asset.localIdentifier] = image
            }
        }

        recentPhotoThumbnails = thumbnails
    }

    private func requestThumbnail(for asset: PHAsset) async -> UIImage? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .opportunistic
            options.resizeMode = .fast
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImage(
                for: asset,
                targetSize: CGSize(width: 160, height: 160),
                contentMode: .aspectFill,
                options: options
            ) { image, info in
                if let isDegraded = info?[PHImageResultIsDegradedKey] as? Bool, isDegraded {
                    return
                }
                continuation.resume(returning: image)
            }
        }
    }

    private func attachRecentPhoto(_ asset: PHAsset) {
        guard !isBusy else { return }
        Task {
            guard let attachment = await makeAttachment(from: asset) else { return }
            onAddAttachments([attachment])
            isAccessoryMenuOpen = false
        }
    }

    private func makeAttachment(from asset: PHAsset) async -> OpenCodeComposerAttachment? {
        guard let (data, uti) = await requestImageData(for: asset), !data.isEmpty else { return nil }
        let type = uti.flatMap(UTType.init) ?? .jpeg
        let mime = type.preferredMIMEType ?? "image/jpeg"
        let fileExtension = type.preferredFilenameExtension ?? "jpg"
        let filename = "image-\(OpenCodeIdentifier.part()).\(fileExtension)"
        let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"

        return OpenCodeComposerAttachment(
            id: OpenCodeIdentifier.part(),
            kind: .image,
            filename: filename,
            mime: mime,
            dataURL: dataURL
        )
    }

    private func requestImageData(for asset: PHAsset) async -> (Data, String?)? {
        await withCheckedContinuation { continuation in
            let options = PHImageRequestOptions()
            options.deliveryMode = .highQualityFormat
            options.isNetworkAccessAllowed = true
            options.isSynchronous = false

            PHImageManager.default().requestImageDataAndOrientation(for: asset, options: options) { data, uti, _, _ in
                guard let data else {
                    continuation.resume(returning: nil)
                    return
                }
                continuation.resume(returning: (data, uti))
            }
        }
    }

    private func loadSelectedPhotoItems() async {
        guard !selectedPhotoItems.isEmpty else { return }

        var attachments: [OpenCodeComposerAttachment] = []

        for item in selectedPhotoItems {
            guard let data = try? await item.loadTransferable(type: Data.self), !data.isEmpty else { continue }

            let type = item.supportedContentTypes.first(where: { $0.conforms(to: .image) }) ?? .png
            let mime = type.preferredMIMEType ?? "image/png"
            let filename = "image-\(OpenCodeIdentifier.part()).\(type.preferredFilenameExtension ?? "png")"
            let dataURL = "data:\(mime);base64,\(data.base64EncodedString())"
            attachments.append(
                OpenCodeComposerAttachment(
                    id: OpenCodeIdentifier.part(),
                    kind: .image,
                    filename: filename,
                    mime: mime,
                    dataURL: dataURL
                )
            )
        }

        selectedPhotoItems = []
        guard !attachments.isEmpty else { return }

        onAddAttachments(attachments)
        isAccessoryMenuOpen = false
    }

    private func importSelectedFiles(_ result: Result<[URL], Error>) {
        guard case let .success(urls) = result, !urls.isEmpty else { return }

        var attachments: [OpenCodeComposerAttachment] = []

        for url in urls {
            let didAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }

            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }

            let values = try? url.resourceValues(forKeys: [.contentTypeKey])
            let type = values?.contentType ?? UTType(filenameExtension: url.pathExtension) ?? .data
            guard let mime = fileAttachmentMimeType(for: type, filename: url.lastPathComponent, data: data) else {
                continue
            }
            let attachment = OpenCodeComposerAttachment(
                id: OpenCodeIdentifier.part(),
                kind: mime.lowercased().hasPrefix("image/") ? .image : .file,
                filename: url.lastPathComponent,
                mime: mime,
                dataURL: "data:\(mime);base64,\(data.base64EncodedString())"
            )
            attachments.append(attachment)
        }

        guard !attachments.isEmpty else { return }

        onAddAttachments(attachments)
        isAccessoryMenuOpen = false
    }

    private func defaultMimeType(for type: UTType) -> String {
        if type.conforms(to: .pdf) { return "application/pdf" }
        if type.conforms(to: .image) { return "image/png" }
        return "application/octet-stream"
    }

    private func fileAttachmentMimeType(for type: UTType, filename: String, data: Data) -> String? {
        let mime = (type.preferredMIMEType ?? defaultMimeType(for: type)).lowercased()

        if mime.hasPrefix("image/") { return mime }
        if mime == "application/pdf" { return mime }
        if isTextLikeMime(mime) || type.conforms(to: .plainText) || type.conforms(to: .text) {
            return "text/plain"
        }
        if isTextLikeFilename(filename) || isProbablyText(data) {
            return "text/plain"
        }
        return nil
    }

    private func isTextLikeMime(_ mime: String) -> Bool {
        if mime.hasPrefix("text/") { return true }
        if mime.hasSuffix("+json") || mime.hasSuffix("+xml") { return true }
        return [
            "application/json",
            "application/ld+json",
            "application/toml",
            "application/x-toml",
            "application/x-yaml",
            "application/xml",
            "application/yaml",
        ].contains(mime)
    }

    private func isTextLikeFilename(_ filename: String) -> Bool {
        let ext = URL(fileURLWithPath: filename).pathExtension.lowercased()
        return [
            "c", "cc", "cjs", "conf", "cpp", "css", "csv", "cts", "env", "go", "gql", "graphql",
            "h", "hh", "hpp", "htm", "html", "ini", "java", "js", "json", "jsx", "log", "md",
            "mdx", "mjs", "mts", "py", "rb", "rs", "sass", "scss", "sh", "sql", "toml", "ts",
            "tsx", "txt", "xml", "yaml", "yml", "zsh",
        ].contains(ext)
    }

    private func isProbablyText(_ data: Data) -> Bool {
        if data.isEmpty { return true }
        let sample = data.prefix(4096)
        var controlByteCount = 0

        for byte in sample {
            if byte == 0 { return false }
            if byte < 9 || (byte > 13 && byte < 32) {
                controlByteCount += 1
            }
        }

        return Double(controlByteCount) / Double(sample.count) <= 0.3
    }
#endif
}

#if canImport(UIKit)
private enum ComposerTextViewMetrics {
    static let horizontalInset: CGFloat = 14
    static let verticalInset: CGFloat = 11
    static let maxLines = 6

    static var minimumHeight: CGFloat {
        let font = UIFont.preferredFont(forTextStyle: .body)
        return ceil(font.lineHeight + verticalInset * 2)
    }
}

private struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let maxLines: Int
    let onFocusChange: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    func makeUIView(context: Context) -> ComposerPlaceholderTextView {
        let textView = ComposerPlaceholderTextView()
        textView.backgroundColor = .clear
        textView.delegate = context.coordinator
        textView.font = UIFont.preferredFont(forTextStyle: .body)
        textView.adjustsFontForContentSizeCategory = true
        textView.textColor = .label
        textView.tintColor = .tintColor
        textView.textContainer.lineFragmentPadding = 0
        textView.textContainerInset = UIEdgeInsets(
            top: ComposerTextViewMetrics.verticalInset,
            left: ComposerTextViewMetrics.horizontalInset,
            bottom: ComposerTextViewMetrics.verticalInset,
            right: ComposerTextViewMetrics.horizontalInset
        )
        textView.returnKeyType = .default
        textView.keyboardDismissMode = .interactive
        textView.placeholder = placeholder
        textView.text = text
        textView.updatePlaceholderVisibility()
        textView.isEditable = true
        textView.isSelectable = true
        return textView
    }

    func updateUIView(_ textView: ComposerPlaceholderTextView, context: Context) {
        context.coordinator.parent = self
        var needsLayoutUpdate = false

        if textView.text != text {
            textView.text = text
            textView.updatePlaceholderVisibility()
            needsLayoutUpdate = true
        }

        if textView.placeholder != placeholder {
            textView.placeholder = placeholder
            needsLayoutUpdate = true
        }

        let bodyFont = UIFont.preferredFont(forTextStyle: .body)
        if textView.font != bodyFont {
            textView.font = bodyFont
            textView.updatePlaceholderFont()
            needsLayoutUpdate = true
        }

        if textView.maximumLineCount != maxLines {
            textView.maximumLineCount = maxLines
            needsLayoutUpdate = true
        }

        guard needsLayoutUpdate else { return }

        textView.updateScrolling(maxLines: maxLines)
        textView.invalidateIntrinsicContentSize()
        textView.setNeedsLayout()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView: ComposerPlaceholderTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width > 0 else { return nil }
        let height = uiView.fittedHeight(width: width, maxLines: maxLines)
        return CGSize(width: width, height: height)
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: ComposerTextView

        init(_ parent: ComposerTextView) {
            self.parent = parent
        }

        func textViewDidBeginEditing(_ textView: UITextView) {
            parent.onFocusChange(true)
        }

        func textViewDidEndEditing(_ textView: UITextView) {
            parent.onFocusChange(false)
        }

        func textViewDidChange(_ textView: UITextView) {
            if parent.text != textView.text {
                parent.text = textView.text
            }

            guard let textView = textView as? ComposerPlaceholderTextView else { return }
            textView.updatePlaceholderVisibility()
            textView.updateScrolling(maxLines: parent.maxLines)
            textView.invalidateIntrinsicContentSize()
        }
    }
}

private final class ComposerPlaceholderTextView: UITextView {
    private let placeholderLabel = UILabel()
    var maximumLineCount = ComposerTextViewMetrics.maxLines

    var placeholder: String = "" {
        didSet {
            placeholderLabel.text = placeholder
            updatePlaceholderVisibility()
        }
    }

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        setupPlaceholder()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let x = textContainerInset.left
        let y = textContainerInset.top
        let width = max(0, bounds.width - textContainerInset.left - textContainerInset.right)
        placeholderLabel.frame = CGRect(x: x, y: y, width: width, height: placeholderLabel.intrinsicContentSize.height)
    }

    func updatePlaceholderFont() {
        placeholderLabel.font = font
        setNeedsLayout()
    }

    func updatePlaceholderVisibility() {
        placeholderLabel.isHidden = !text.isEmpty
    }

    func fittedHeight(width: CGFloat, maxLines: Int) -> CGFloat {
        let target = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let measuredHeight = sizeThatFits(target).height
        let lineHeight = (font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let minHeight = ceil(lineHeight + textContainerInset.top + textContainerInset.bottom)
        let maxHeight = ceil(lineHeight * CGFloat(max(1, maxLines)) + textContainerInset.top + textContainerInset.bottom)
        return min(max(measuredHeight, minHeight), maxHeight)
    }

    func updateScrolling(maxLines: Int) {
        let width = bounds.width > 0 ? bounds.width : UIScreen.main.bounds.width - 110
        let target = CGSize(width: width, height: CGFloat.greatestFiniteMagnitude)
        let measuredHeight = sizeThatFits(target).height
        let lineHeight = (font ?? UIFont.preferredFont(forTextStyle: .body)).lineHeight
        let maxHeight = ceil(lineHeight * CGFloat(max(1, maxLines)) + textContainerInset.top + textContainerInset.bottom)
        isScrollEnabled = measuredHeight > maxHeight + 0.5
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        bounds.insetBy(dx: -8, dy: -8).contains(point)
    }

    private func setupPlaceholder() {
        placeholderLabel.textColor = .placeholderText
        placeholderLabel.font = font ?? UIFont.preferredFont(forTextStyle: .body)
        placeholderLabel.numberOfLines = 1
        placeholderLabel.isUserInteractionEnabled = false
        addSubview(placeholderLabel)
    }
}

#endif

private struct ComposerInputFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect = .zero

    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero {
            value = next
        }
    }
}

private struct CommandPicker: View {
    let commands: [OpenCodeCommand]
    let selectedCommandName: String?
    let onSelect: (OpenCodeCommand) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if commands.isEmpty {
                Text("No matching commands")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
            } else {
                ScrollView {
                    VStack(spacing: 6) {
                        ForEach(commands) { command in
                            Button {
                                onSelect(command)
                            } label: {
                                HStack(alignment: .firstTextBaseline, spacing: 10) {
                                    Text("/\(command.name)")
                                        .font(.subheadline.weight(.semibold))
                                        .foregroundStyle(.primary)

                                    if let description = command.description, !description.isEmpty {
                                        Text(description)
                                            .font(.subheadline)
                                            .foregroundStyle(.secondary)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .lineLimit(1)
                                    } else {
                                        Spacer(minLength: 0)
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 10)
                                .background(
                                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                                        .fill(command.name == selectedCommandName ? Color.primary.opacity(0.08) : Color.clear)
                                )
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("chat.command.\(command.name)")
                        }
                    }
                    .padding(8)
                }
                .frame(maxHeight: 220)
            }
        }
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }
}

private struct AccessoryMenuAction: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool
    var accessibilityIdentifier = "chat.composer.commands"
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccessoryMenuLabel(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint, isDisabled: isDisabled)
        }
        .accessoryOptionButtonStyle()
        .disabled(isDisabled)
        .accessibilityIdentifier(accessibilityIdentifier)
    }
}

private struct AccessorySectionTitle: View {
    let title: String

    init(_ title: String) {
        self.title = title
    }

    var body: some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
            .tracking(0.6)
            .padding(.top, 6)
            .padding(.horizontal, 2)
    }
}

private struct AccessoryMenuLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Image(systemName: systemImage)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(isDisabled ? .secondary : tint)
            }
            .frame(width: 28, height: 28)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(isDisabled ? .secondary : .primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .shadow(color: .black.opacity(isDisabled ? 0.02 : 0.07), radius: 8, y: 3)
        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct ComposerForkListView: View {
    let messages: [OpenCodeForkableMessage]
    let onForkMessage: (String) -> Void

    @State private var searchText = ""

    private var filteredMessages: [OpenCodeForkableMessage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return messages }
        return messages.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if filteredMessages.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No User Messages" : "No Matches",
                    systemImage: "arrow.triangle.branch",
                    description: Text(searchText.isEmpty ? "Send a message before forking this session." : "Try a different search.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(filteredMessages) { message in
                    Button {
                        onForkMessage(message.id)
                    } label: {
                        ComposerForkMessageRow(message: message)
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("chat.fork.message.\(message.id)")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .navigationTitle("Fork Session")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search messages")
    }
}

private struct ComposerForkMessageRow: View {
    let message: OpenCodeForkableMessage

    private var timeLabel: String {
        guard let created = message.created else { return "" }
        let date = Date(timeIntervalSince1970: created > 100_000_000_000 ? created / 1000 : created)
        return date.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.12), in: RoundedRectangle(cornerRadius: 9, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(message.text)
                    .font(.body)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if !timeLabel.isEmpty {
                    Text(timeLabel)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer(minLength: 0)

            Image(systemName: "arrow.triangle.branch")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.top, 4)
        }
        .padding(.vertical, 4)
    }
}

private struct ComposerMCPListView: View {
    let servers: [OpenCodeMCPServer]
    let connectedCount: Int
    let isLoading: Bool
    let togglingServerNames: Set<String>
    let errorMessage: String?
    let onLoad: () -> Void
    let onToggle: (String) -> Void

    @State private var searchText = ""

    private var filteredServers: [OpenCodeMCPServer] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return servers }
        return servers.filter { server in
            server.name.localizedCaseInsensitiveContains(query) || server.status.displayStatus.localizedCaseInsensitiveContains(query)
        }
    }

    var body: some View {
        List {
            Section {
                HStack(spacing: 12) {
                    Image(systemName: "server.rack")
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 36)
                        .background(Color.indigo, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(alignment: .leading, spacing: 2) {
                        Text("MCP Servers")
                            .font(.headline)
                        Text("\(connectedCount) of \(servers.count) enabled")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }

                    Spacer(minLength: 0)

                    if isLoading {
                        ProgressView()
                    }
                }
                .padding(.vertical, 4)
            }

            if let errorMessage, !errorMessage.isEmpty {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }

            Section("Servers") {
                if isLoading && servers.isEmpty {
                    ProgressView("Loading MCP servers")
                } else if filteredServers.isEmpty {
                    Text(servers.isEmpty ? "No configured MCP servers." : "No MCP servers match your search.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(filteredServers) { server in
                        ComposerMCPServerRow(
                            server: server,
                            isToggling: togglingServerNames.contains(server.name),
                            onToggle: { onToggle(server.name) }
                        )
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $searchText, prompt: "Search MCP servers")
        .navigationTitle("MCP")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            onLoad()
        }
        .animation(opencodeSelectionAnimation, value: servers.map(\.id).joined(separator: "|"))
        .animation(opencodeSelectionAnimation, value: togglingServerNames)
    }
}

private struct ComposerMCPServerRow: View {
    let server: OpenCodeMCPServer
    let isToggling: Bool
    let onToggle: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(server.name)
                        .font(.body.weight(.medium))
                        .lineLimit(1)

                    Text(server.status.displayStatus)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(statusColor.opacity(0.12), in: Capsule())
                }

                if let error = server.status.error, !error.isEmpty {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if isToggling {
                ProgressView()
            }

            Toggle("Enabled", isOn: Binding(
                get: { server.status.isConnected },
                set: { _ in onToggle() }
            ))
            .labelsHidden()
            .disabled(isToggling)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            guard !isToggling else { return }
            onToggle()
        }
    }

    private var statusColor: Color {
        switch server.status.status {
        case "connected":
            return .green
        case "failed", "needs_client_registration":
            return .red
        case "needs_auth":
            return .orange
        default:
            return .secondary
        }
    }
}

private extension View {
    @ViewBuilder
    func composerPlusButtonStyle() -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.1, *) {
            buttonStyle(.glass(.regular))
                .buttonBorderShape(.circle)
        } else {
            buttonStyle(.plain)
                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        #else
        buttonStyle(.plain)
            .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        #endif
    }

    @ViewBuilder
    func accessoryOptionButtonStyle() -> some View {
        #if os(iOS) || targetEnvironment(macCatalyst)
        if #available(iOS 26.1, *) {
            buttonStyle(.glass(.regular))
                .buttonBorderShape(.roundedRectangle(radius: 18))
        } else {
            buttonStyle(.bordered)
                .buttonBorderShape(.roundedRectangle(radius: 18))
        }
        #else
        buttonStyle(.bordered)
        #endif
    }
}
