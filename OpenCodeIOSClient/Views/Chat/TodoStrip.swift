import SwiftUI

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
import AppKit
#elseif canImport(UIKit)
import UIKit
#endif

struct TodoStrip: View {
    let todos: [OpenCodeTodo]
    let onTapCard: () -> Void
    var onMinimize: () -> Void = {}

    private var focusTodoID: String? {
        let index = todos.firstIndex(where: { $0.isInProgress })
            ?? todos.firstIndex(where: { !$0.isComplete })
        return index.map { todoPresentationID(index: $0, todo: todos[$0]) }
    }

    private var todoIDs: String {
        todos.enumerated().map { todoPresentationID(index: $0.offset, todo: $0.element) }.joined(separator: "|")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(Array(todos.enumerated()), id: \.offset) { index, todo in
                        TodoCard(todo: todo)
                        .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                        .onTapGesture(perform: onTapCard)
                        .accessibilityAddTraits(.isButton)
                        .id(todoPresentationID(index: index, todo: todo))
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
            .onAppear {
                scrollToFocus(with: proxy, animated: false)
            }
            .onChange(of: focusTodoID) { _, _ in
                scrollToFocus(with: proxy, animated: true)
            }
            .animation(opencodeSelectionAnimation, value: todoIDs)
        }
        .modifier(TodoMinimizeGestureModifier(onMinimize: onMinimize))
        .accessibilityIdentifier("chat.todos.expanded")
    }

    private func scrollToFocus(with proxy: ScrollViewProxy, animated: Bool) {
        guard let focusTodoID else { return }
        let action = {
            proxy.scrollTo(focusTodoID, anchor: .leading)
        }
        if animated {
            withAnimation(opencodeSelectionAnimation, action)
        } else {
            action()
        }
    }

    private func todoPresentationID(index: Int, todo: OpenCodeTodo) -> String {
        "\(index):\(todo.id)"
    }
}

enum ComposerAccessoryExpansion: Equatable {
    case collapsed
    case expanded(focus: Focus)

    enum Focus: String, Equatable {
        case todos
        case attachments
    }

    var focus: Focus? {
        if case let .expanded(focus) = self {
            return focus
        }
        return nil
    }

    var isExpanded: Bool {
        focus != nil
    }
}

struct ComposerAccessoryArea: View {
    let todos: [OpenCodeTodo]
    let attachments: [OpenCodeComposerAttachment]
    @Binding var expansion: ComposerAccessoryExpansion
    let isTodoStripMinimized: Bool
    let onSetTodoStripMinimized: (Bool) -> Void
    let onTapTodo: () -> Void
    let onTapAttachment: (OpenCodeComposerAttachment) -> Void
    let onRemoveAttachment: (OpenCodeComposerAttachment) -> Void
    @Namespace private var accessoryCardNamespace

    private let todoSectionID = "composer-accessories-todos"
    private let attachmentSectionID = "composer-accessories-attachments"

    private var activeTodos: [OpenCodeTodo] {
        todos.filter { !$0.isComplete }
    }

    private var hasBothKinds: Bool {
        !activeTodos.isEmpty && !attachments.isEmpty
    }

    private var attachmentIDs: String {
        attachments.map(\.id).joined(separator: "|")
    }

    var body: some View {
        Group {
            if activeTodos.isEmpty && attachments.isEmpty {
                EmptyView()
            } else if !activeTodos.isEmpty && isTodoStripMinimized {
                minimizedTodos
            } else if hasBothKinds {
                if expansion.isExpanded {
                    expandedRail
                } else {
                    collapsedStacks
                }
            } else if !activeTodos.isEmpty {
                TodoStrip(
                    todos: activeTodos,
                    onTapCard: onTapTodo,
                    onMinimize: minimizeTodos
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            } else {
                AttachmentStrip(
                    attachments: attachments,
                    allowsRemoval: true,
                    onTapAttachment: onTapAttachment,
                    onRemoveAttachment: onRemoveAttachment
                )
            }
        }
        .animation(opencodeSelectionAnimation, value: attachmentIDs)
        .animation(.snappy(duration: 0.32, extraBounce: 0.04), value: isTodoStripMinimized)
    }

    private var minimizedTodos: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(alignment: .bottom, spacing: 10) {
                TodoProgressPill(
                    completedCount: todos.filter(\.isComplete).count,
                    totalCount: todos.count,
                    onRestore: restoreTodos
                )

                ForEach(attachments) { attachment in
                    AttachmentCard(
                        attachment: attachment,
                        allowsRemoval: true,
                        onTap: { onTapAttachment(attachment) },
                        onRemove: { onRemoveAttachment(attachment) }
                    )
                    .transition(.composerAttachmentEntry)
                }
            }
            .padding(.horizontal, 1)
        }
        .scrollClipDisabled()
        .padding(.horizontal, -6)
        .transition(.scale(scale: 0.82, anchor: .bottom).combined(with: .opacity))
    }

    private var collapsedStacks: some View {
        GeometryReader { geometry in
            let stackWidth = max(0, (geometry.size.width - 14) / 2)

            HStack(spacing: 14) {
                AccessoryStackSummary(
                    focus: .todos,
                    expansion: $expansion
                ) {
                    ForEach(Array(activeTodos.prefix(3).enumerated()).reversed(), id: \.offset) { entry in
                        let todo = entry.element
                        StackTodoCard(todo: todo, showsContent: entry.offset == 0)
                            .matchedGeometryEffect(id: todoCardGeometryID("\(entry.offset):\(todo.id)"), in: accessoryCardNamespace)
                            .rotationEffect(.degrees(summaryRotation(index: entry.offset)))
                            .offset(x: CGFloat(entry.offset) * 5, y: CGFloat(entry.offset) * -2)
                    }
                }
                .modifier(TodoMinimizeGestureModifier(onMinimize: minimizeTodos))
                .frame(width: stackWidth)

                AccessoryStackSummary(
                    focus: .attachments,
                    expansion: $expansion
                ) {
                    ForEach(Array(attachments.prefix(3).enumerated()).reversed(), id: \.element.id) { entry in
                        let attachment = entry.element
                        StackAttachmentCard(attachment: attachment, showsContent: entry.offset == 0)
                            .matchedGeometryEffect(id: attachmentCardGeometryID(attachment.id), in: accessoryCardNamespace)
                            .rotationEffect(.degrees(summaryRotation(index: entry.offset)))
                            .offset(x: CGFloat(entry.offset) * 5, y: CGFloat(entry.offset) * -2)
                            .transition(.composerAttachmentEntry)
                    }
                }
                .frame(width: stackWidth)
            }
            .frame(width: geometry.size.width, alignment: .leading)
        }
        .frame(height: 104)
    }

    private var expandedRail: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 16) {
                    accessorySection {
                        HStack(spacing: 10) {
                            ForEach(Array(activeTodos.enumerated()), id: \.offset) { index, todo in
                                TodoCard(todo: todo)
                                    .matchedGeometryEffect(id: todoCardGeometryID("\(index):\(todo.id)"), in: accessoryCardNamespace)
                                    .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                                    .onTapGesture(perform: onTapTodo)
                                    .accessibilityAddTraits(.isButton)
                            }
                        }
                    }
                    .modifier(TodoMinimizeGestureModifier(onMinimize: minimizeTodos))
                    .id(todoSectionID)

                    accessorySection {
                        HStack(spacing: 10) {
                            ForEach(attachments) { attachment in
                                AttachmentCard(
                                    attachment: attachment,
                                    allowsRemoval: true,
                                    onTap: { onTapAttachment(attachment) },
                                    onRemove: { onRemoveAttachment(attachment) }
                                )
                                .matchedGeometryEffect(id: attachmentCardGeometryID(attachment.id), in: accessoryCardNamespace)
                                .transition(.composerAttachmentEntry)
                            }
                        }
                    }
                    .id(attachmentSectionID)
                }
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
            .onAppear {
                scrollExpandedRail(with: proxy, animated: false)
            }
            .onChange(of: expansion) { _, _ in
                scrollExpandedRail(with: proxy, animated: true)
            }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func accessorySection<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            content()
        }
    }

    private func todoCardGeometryID(_ id: String) -> String {
        "composer-accessory-todo-\(id)"
    }

    private func attachmentCardGeometryID(_ id: String) -> String {
        "composer-accessory-attachment-\(id)"
    }

    private func scrollExpandedRail(with proxy: ScrollViewProxy, animated: Bool) {
        guard let focus = expansion.focus else { return }
        let targetID = focus == .todos ? todoSectionID : attachmentSectionID
        let action = {
            proxy.scrollTo(targetID, anchor: .leading)
        }
        if animated {
            withAnimation(opencodeSelectionAnimation, action)
        } else {
            action()
        }
    }

    private func summaryRotation(index: Int) -> Double {
        switch index {
        case 0: return -4
        case 1: return 2
        default: return 5
        }
    }

    private func minimizeTodos() {
        OpenCodeHaptics.impact(.soft)
        withAnimation(.snappy(duration: 0.3, extraBounce: 0.04)) {
            expansion = .collapsed
            onSetTodoStripMinimized(true)
        }
    }

    private func restoreTodos() {
        OpenCodeHaptics.impact(.soft)
        withAnimation(.snappy(duration: 0.34, extraBounce: 0.05)) {
            onSetTodoStripMinimized(false)
        }
    }
}

private struct TodoProgressPill: View {
    let completedCount: Int
    let totalCount: Int
    let onRestore: () -> Void

    var body: some View {
        Button(action: onRestore) {
            HStack(spacing: 7) {
                Image(systemName: "checklist")
                    .foregroundStyle(.blue)

                Text("\(completedCount) of \(totalCount)")
                    .monospacedDigit()

                Image(systemName: "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .font(.caption.weight(.semibold))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Capsule())
            .opencodeGlassSurface(isInteractive: true, in: Capsule())
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44, alignment: .bottom)
        .contentShape(Rectangle())
        .accessibilityLabel("Todos")
        .accessibilityValue("\(completedCount) of \(totalCount)")
        .accessibilityIdentifier("chat.todos.minimized")
    }
}

private struct TodoMinimizeGestureModifier: ViewModifier {
    let onMinimize: () -> Void
    @GestureState private var downwardTranslation: CGFloat = 0

    private var progress: CGFloat {
        min(downwardTranslation / 72, 1)
    }

    func body(content: Content) -> some View {
        content
            .offset(y: min(downwardTranslation, 40))
            .scaleEffect(
                x: 1 - progress * 0.06,
                y: 1 - progress * 0.12,
                anchor: .bottom
            )
            .opacity(1 - Double(progress) * 0.38)
            .simultaneousGesture(
                DragGesture(minimumDistance: 12)
                    .updating($downwardTranslation) { value, translation, _ in
                        let distance = value.translation
                        guard distance.height > 0,
                              distance.height > abs(distance.width) else {
                            return
                        }
                        translation = distance.height
                    }
                    .onEnded { value in
                        let translation = value.translation
                        let projected = value.predictedEndTranslation
                        let verticalDistance = max(translation.height, projected.height)
                        let horizontalDistance = max(abs(translation.width), abs(projected.width))
                        guard verticalDistance >= 44,
                              verticalDistance > horizontalDistance else {
                            return
                        }
                        onMinimize()
                    }
            )
    }
}

struct AttachmentStrip: View {
    let attachments: [OpenCodeComposerAttachment]
    let allowsRemoval: Bool
    let onTapAttachment: (OpenCodeComposerAttachment) -> Void
    let onRemoveAttachment: (OpenCodeComposerAttachment) -> Void

    private var attachmentIDs: String {
        attachments.map { $0.id }.joined(separator: "|")
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(attachments) { attachment in
                        AttachmentCard(
                            attachment: attachment,
                            allowsRemoval: allowsRemoval,
                            onTap: { onTapAttachment(attachment) },
                            onRemove: { onRemoveAttachment(attachment) }
                        )
                        .id(attachment.id)
                        .transition(.composerAttachmentEntry)
                    }
                }
                .padding(.horizontal, 1)
            }
            .scrollClipDisabled()
            .onAppear {
                scrollToLastAttachment(with: proxy, animated: false)
            }
            .onChange(of: attachmentIDs) { _, _ in
                scrollToLastAttachment(with: proxy, animated: true)
            }
            .animation(opencodeSelectionAnimation, value: attachmentIDs)
        }
    }

    private func scrollToLastAttachment(with proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = attachments.last?.id else { return }
        let action = {
            proxy.scrollTo(lastID, anchor: .trailing)
        }
        if animated {
            withAnimation(opencodeSelectionAnimation, action)
        } else {
            action()
        }
    }
}

struct AttachmentCard: View {
    let attachment: OpenCodeComposerAttachment
    let allowsRemoval: Bool
    let onTap: () -> Void
    let onRemove: () -> Void

    var body: some View {
        ZStack(alignment: .topTrailing) {
            Button(action: onTap) {
                cardContent
            }
            .buttonStyle(.plain)

            if allowsRemoval {
                Button(action: onRemove) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 22)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(8)
            }
        }
    }

    @ViewBuilder
    private var cardContent: some View {
        if attachment.isImage {
            let size = AttachmentCardLayout.fittedImageSize(sourceSize: imageDimensions(for: attachment))
            AttachmentThumbnail(attachment: attachment, contentMode: .fit)
                .frame(width: size.width, height: size.height)
                .background(OpenCodePlatformColor.secondaryGroupedBackground)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        } else {
            VStack(alignment: .leading, spacing: 8) {
                AttachmentThumbnail(attachment: attachment)
                    .frame(height: 78)

                VStack(alignment: .leading, spacing: 4) {
                    Text(attachment.filename)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    attachmentLabel
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .padding(10)
            .frame(width: 140, alignment: .leading)
            .background(OpenCodePlatformColor.secondaryGroupedBackground)
            .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
    }

    private var attachmentLabel: Text {
        if attachment.isImage { return Text("Image") }
        if attachment.mime == "application/pdf" { return Text("PDF") }
        if attachment.mime.lowercased().contains("text") { return Text("Text File") }
        if attachment.filename.lowercased().hasSuffix(".txt") { return Text("Text File") }
        return Text(attachment.mime)
    }
}

enum AttachmentCardLayout {
    static let maximumImageSize = CGSize(width: 220, height: 140)
    static let minimumImageEdge: CGFloat = 72

    static func fittedImageSize(sourceSize: CGSize?) -> CGSize {
        guard let sourceSize, sourceSize.width > 0, sourceSize.height > 0 else {
            return CGSize(width: 140, height: 140)
        }

        let scale = min(
            maximumImageSize.width / sourceSize.width,
            maximumImageSize.height / sourceSize.height
        )
        return CGSize(
            width: max(minimumImageEdge, floor(sourceSize.width * scale)),
            height: max(minimumImageEdge, floor(sourceSize.height * scale))
        )
    }
}

struct AttachmentPreviewSheet: View {
    let attachment: OpenCodeComposerAttachment

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if attachment.isImage {
                    AttachmentThumbnail(attachment: attachment, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .frame(height: 320)
                        .background(OpenCodePlatformColor.secondaryGroupedBackground)
                        .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: fileSymbol(for: attachment))
                            .font(.system(size: 42, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(attachment.filename)
                            .font(.headline)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 36)
                    .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                }

                VStack(alignment: .leading, spacing: 10) {
                    attachmentDetailRow(title: "Name", value: attachment.filename)
                    attachmentDetailRow(title: "Type", value: attachment.mime)
                }
                .padding(16)
                .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            }
            .padding(20)
        }
        .background(OpenCodePlatformColor.groupedBackground)
        .navigationTitle(attachment.isImage ? "" : attachment.filename)
        .opencodeInlineNavigationTitle()
    }

    private func attachmentDetailRow(title: LocalizedStringResource, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.body)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
        }
    }
}

struct AttachmentThumbnail: View {
    let attachment: OpenCodeComposerAttachment
    var contentMode: ContentMode = .fill

    var body: some View {
        Group {
            if attachment.isImage, let image = image(for: attachment) {
                image
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                VStack(spacing: 8) {
                    Image(systemName: fileSymbol(for: attachment))
                        .font(.system(size: 28, weight: .semibold))
                    Text(shortFileLabel(for: attachment))
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(OpenCodePlatformColor.groupedBackground)
            }
        }
        .background(OpenCodePlatformColor.groupedBackground)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

private struct AccessoryStackSummary<Cards: View>: View {
    let focus: ComposerAccessoryExpansion.Focus
    @Binding var expansion: ComposerAccessoryExpansion
    @ViewBuilder let cards: () -> Cards

    var body: some View {
        Button {
            withAnimation(opencodeSelectionAnimation) {
                expansion = .expanded(focus: focus)
            }
        } label: {
            ZStack(alignment: .topLeading) {
                cards()
            }
            .padding(.top, 8)
            .padding(.trailing, 14)
            .frame(maxWidth: .infinity, minHeight: 104, alignment: .topLeading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct StackTodoCard: View {
    let todo: OpenCodeTodo
    var showsContent = true

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(OpenCodePlatformColor.secondaryGroupedBackground)
            .frame(height: 86)
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .overlay(alignment: .topLeading) {
                if showsContent {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(todo.content)
                            .font(.subheadline.weight(.medium))
                            .lineLimit(2)
                        TodoStatusLabel(status: todo.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .padding(12)
                }
            }
    }
}

private struct StackAttachmentCard: View {
    let attachment: OpenCodeComposerAttachment
    var showsContent = true

    var body: some View {
        RoundedRectangle(cornerRadius: 18, style: .continuous)
            .fill(OpenCodePlatformColor.secondaryGroupedBackground)
            .frame(height: 86)
            .shadow(color: .black.opacity(0.08), radius: 8, y: 4)
            .overlay {
                if showsContent {
                    HStack(spacing: 10) {
                        AttachmentThumbnail(attachment: attachment)
                            .frame(width: 48, height: 48)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(attachment.filename)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                            Group {
                                if attachment.isImage {
                                    Text("Image")
                                } else {
                                    Text("Attachment")
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .clipped()
                    }
                    .padding(12)
                }
            }
    }
}

private func fileSymbol(for attachment: OpenCodeComposerAttachment) -> String {
    if attachment.isImage { return "photo" }
    if attachment.mime == "application/pdf" { return "doc.richtext" }
    if attachment.mime.lowercased().contains("text") { return "doc.text" }
    return "doc"
}

private func shortFileLabel(for attachment: OpenCodeComposerAttachment) -> LocalizedStringResource {
    if attachment.isImage { return "Image" }
    if attachment.mime == "application/pdf" { return "PDF" }
    if attachment.mime.lowercased().contains("text") { return "TXT" }
    if attachment.filename.lowercased().hasSuffix(".txt") { return "TXT" }
    return "FILE"
}

private func image(for attachment: OpenCodeComposerAttachment) -> Image? {
    guard let data = dataPayload(from: attachment.dataURL) else { return nil }

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    guard let platformImage = NSImage(data: data) else { return nil }
    return Image(nsImage: platformImage)
#elseif canImport(UIKit)
    guard let platformImage = UIImage(data: data) else { return nil }
    return Image(uiImage: platformImage)
#else
    return nil
#endif
}

private func imageDimensions(for attachment: OpenCodeComposerAttachment) -> CGSize? {
    guard let data = dataPayload(from: attachment.dataURL) else { return nil }

#if canImport(AppKit) && !targetEnvironment(macCatalyst)
    return NSImage(data: data)?.size
#elseif canImport(UIKit)
    return UIImage(data: data)?.size
#else
    return nil
#endif
}

private func dataPayload(from dataURL: String) -> Data? {
    guard let commaIndex = dataURL.firstIndex(of: ",") else { return nil }
    let payload = dataURL[dataURL.index(after: commaIndex)...]
    return Data(base64Encoded: String(payload))
}

private extension AnyTransition {
    static var composerAttachmentEntry: AnyTransition {
        .asymmetric(
            insertion: .scale(scale: 0.86, anchor: .bottomLeading)
                .combined(with: .offset(x: 18, y: 8))
                .combined(with: .opacity),
            removal: .scale(scale: 0.96, anchor: .center)
                .combined(with: .opacity)
        )
    }
}
