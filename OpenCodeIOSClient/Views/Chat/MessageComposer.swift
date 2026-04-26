import SwiftUI
#if canImport(PhotosUI)
import PhotosUI
import UniformTypeIdentifiers
#endif

struct MessageComposer: View {
    @Binding var text: String
    @Binding var isAccessoryMenuOpen: Bool
    let commands: [OpenCodeCommand]
    let attachmentCount: Int
    let isBusy: Bool
    let canFork: Bool
    let onInputFrameChange: (CGRect) -> Void
    let onSend: () -> Void
    let onStop: () -> Void
    let onSelectCommand: (OpenCodeCommand) -> Void
    let onOpenFork: () -> Void
    let onAddAttachments: ([OpenCodeComposerAttachment]) -> Void

    @State private var selectedCommandName: String?
    @Namespace private var accessoryGlassNamespace
#if canImport(PhotosUI)
    @State private var selectedPhotoItems: [PhotosPickerItem] = []
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
        .onPreferenceChange(ComposerInputFramePreferenceKey.self) { frame in
            guard frame != .zero else { return }
            onInputFrameChange(frame)
        }
#if canImport(PhotosUI)
        .onChange(of: selectedPhotoItems) { _, _ in
            Task { await loadSelectedPhotoItems() }
        }
        .fileImporter(
            isPresented: $isShowingFileImporter,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            importSelectedFiles(result)
        }
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
            HStack(alignment: .bottom, spacing: 10) {
                Color.clear
                    .frame(width: 44, height: 44)

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
                        if isAccessoryMenuOpen {
                            withAnimation(opencodeSelectionAnimation) {
                                isAccessoryMenuOpen = false
                            }
                        }
                    })

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
            .shadow(color: .black.opacity(0.06), radius: 12, y: 3)

            accessoryContainer
                .zIndex(2)

        }
        .animation(opencodeSelectionAnimation, value: isBusy)
        .animation(opencodeSelectionAnimation, value: canSend)
        .animation(opencodeSelectionAnimation, value: isAccessoryMenuOpen)
    }

    private var accessoryContainer: some View {
        ZStack(alignment: .bottomLeading) {
            if isAccessoryMenuOpen {
                expandedAccessoryMenu
                    .transition(.identity)
            } else {
                collapsedAccessoryButton
                    .transition(.identity)
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
                .font(.system(size: 21, weight: .regular))
                .foregroundStyle(.primary)
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open composer menu")
        .accessibilityIdentifier("chat.composer.menu")
        .frame(width: 44, height: 44)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opencodeToolbarGlassID("composer-plus-menu", in: accessoryGlassNamespace)
        .shadow(color: .black.opacity(0.06), radius: 10, y: 3)
    }

    private var expandedAccessoryMenu: some View {
        VStack(alignment: .leading, spacing: 8) {
#if canImport(PhotosUI)
            PhotosPicker(selection: $selectedPhotoItems, maxSelectionCount: 10, matching: .images) {
                AccessoryMenuLabel(
                    title: "Photos",
                    subtitle: "Add an image",
                    systemImage: "photo.on.rectangle.angled",
                    tint: .pink,
                    isDisabled: isBusy
                )
            }
            .buttonStyle(.plain)

            AccessoryMenuAction(
                title: "Files",
                subtitle: "Attach a file",
                systemImage: "doc.badge.plus",
                tint: .orange,
                isDisabled: isBusy,
                action: {
                    isShowingFileImporter = true
                }
            )
#endif

            AccessoryMenuAction(
                title: "Commands",
                subtitle: "Insert slash command",
                systemImage: "chevron.left.forwardslash.chevron.right",
                tint: .blue,
                isDisabled: !canInsertCommandShortcut,
                action: insertSlashCommand
            )

            AccessoryMenuAction(
                title: "Fork",
                subtitle: "Start from a message",
                systemImage: "arrow.triangle.branch",
                tint: .purple,
                isDisabled: isBusy || !canFork,
                action: {
                    isAccessoryMenuOpen = false
                    onOpenFork()
                }
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 272, alignment: .leading)
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .opencodeToolbarGlassID("composer-plus-menu", in: accessoryGlassNamespace)
        .shadow(color: .black.opacity(0.12), radius: 18, y: 6)
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

#if canImport(PhotosUI)
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
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            AccessoryMenuLabel(title: title, subtitle: subtitle, systemImage: systemImage, tint: tint, isDisabled: isDisabled)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityIdentifier("chat.composer.commands")
    }
}

private struct AccessoryMenuLabel: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let tint: Color
    let isDisabled: Bool

    var body: some View {
        HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(tint.opacity(isDisabled ? 0.12 : 0.22))

                Image(systemName: systemImage)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(isDisabled ? .secondary : tint)
            }
            .frame(width: 44, height: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)

                Text(subtitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 0)
        }
        .foregroundStyle(isDisabled ? .secondary : .primary)
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
