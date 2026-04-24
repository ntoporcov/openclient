import SwiftUI

#if canImport(UniformTypeIdentifiers)
import UniformTypeIdentifiers
#endif

struct SessionListView: View {
    @ObservedObject var viewModel: AppViewModel
    @Namespace private var sessionRowNamespace
    let onSessionChosen: () -> Void

    var body: some View {
        let sessionIDs = viewModel.sessions.map(\.id).joined(separator: "|")
        let pinnedSessionIDs = viewModel.pinnedRootSessions.map(\.id).joined(separator: "|")

        List {
            Section {
                if viewModel.pinnedRootSessions.isEmpty {
                    EmptyPinnedDropArea { sessionID in
                        viewModel.insertPinnedSession(withID: sessionID, at: 0)
                    }
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
                } else {
                    ForEach(viewModel.pinnedRootSessions) { session in
                        pinnedSessionRow(for: session)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                    .onMove(perform: movePinnedSessions)
                    .onInsert(of: dropTypes, perform: insertPinnedSessions)
                }
            } header: {
                SessionSectionHeader(
                    title: "Pinned",
                    systemImage: viewModel.pinnedRootSessions.isEmpty ? "pin" : "pin.fill",
                    accessory: viewModel.pinnedRootSessions.isEmpty ? "Drag a chat here or use the menu" : "\(viewModel.pinnedRootSessions.count)"
                )
            }

            Section {
                if viewModel.unpinnedRootSessions.isEmpty {
                    Text(viewModel.sessions.isEmpty ? "Create a session to start chatting." : "All visible sessions are pinned.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } else {
                    ForEach(viewModel.unpinnedRootSessions) { session in
                        sessionRow(for: session)
                            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
            } header: {
                SessionSectionHeader(title: "Sessions", systemImage: "bubble.left.and.bubble.right")
            }

            if let errorMessage = viewModel.errorMessage {
                Section {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                        .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                } header: {
                    SessionSectionHeader(title: "Error", systemImage: "exclamationmark.triangle.fill")
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(OpenCodePlatformColor.groupedBackground)
        .opencodeInteractiveKeyboardDismiss()
        .sheet(isPresented: $viewModel.isShowingCreateSessionSheet) {
            CreateSessionSheet(viewModel: viewModel)
        }
        .animation(opencodeSelectionAnimation, value: viewModel.selectedSession?.id)
        .animation(opencodeSelectionAnimation, value: sessionIDs)
        .animation(opencodeSelectionAnimation, value: pinnedSessionIDs)
        .animation(opencodeSelectionAnimation, value: viewModel.errorMessage ?? "")
    }

    private func pinnedSessionRow(for session: OpenCodeSession) -> some View {
        sessionRow(for: session, showsPinnedBadge: true)
    }

    private func movePinnedSessions(from offsets: IndexSet, to destination: Int) {
        withAnimation(opencodeSelectionAnimation) {
            viewModel.movePinnedSessions(fromOffsets: offsets, toOffset: destination)
        }
    }

    private func insertPinnedSessions(at index: Int, providers: [NSItemProvider]) {
        _ = loadDroppedSessionID(from: providers) { sessionID in
            withAnimation(opencodeSelectionAnimation) {
                viewModel.insertPinnedSession(withID: sessionID, at: index)
            }
        }
    }

    private func sessionRow(
        for session: OpenCodeSession,
        showsPinnedBadge: Bool = false,
        style: SessionRow.Style = .regular
    ) -> some View {
        SessionRow(
            viewModel: viewModel,
            session: session,
            isSelected: viewModel.selectedSession?.id == session.id,
            showsPinnedBadge: showsPinnedBadge,
            style: style
        )
        .matchedGeometryEffect(id: session.id, in: sessionRowNamespace)
        .contentShape(Rectangle())
        .onTapGesture {
            Task {
                await viewModel.selectSession(session)
                withAnimation(opencodeSelectionAnimation) {
                    onSessionChosen()
                }
            }
        }
        .contextMenu {
            if viewModel.isSessionPinned(session) {
                Button {
                    withAnimation(opencodeSelectionAnimation) {
                        viewModel.unpinSession(session)
                    }
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
            } else {
                Button {
                    withAnimation(opencodeSelectionAnimation) {
                        viewModel.pinSession(session)
                    }
                } label: {
                    Label("Pin", systemImage: "pin")
                }
            }

            Button(role: .destructive) {
                Task { await viewModel.deleteSession(session) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
        .onDrag {
            NSItemProvider(object: session.id as NSString)
        } preview: {
            SessionDragOverlay(title: session.title ?? "Untitled Session")
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if viewModel.isSessionPinned(session) {
                Button {
                    withAnimation(opencodeSelectionAnimation) {
                        viewModel.unpinSession(session)
                    }
                } label: {
                    Label("Unpin", systemImage: "pin.slash")
                }
                .tint(.gray)
            } else {
                Button {
                    withAnimation(opencodeSelectionAnimation) {
                        viewModel.pinSession(session)
                    }
                } label: {
                    Label("Pin", systemImage: "pin")
                }
                .tint(.orange)
            }

            Button(role: .destructive) {
                Task { await viewModel.deleteSession(session) }
            } label: {
                Label("Delete", systemImage: "trash")
            }
        }
    }
}

private struct SessionDragOverlay: View {
    let title: String

    var body: some View {
        HStack(spacing: 12) {
            SessionAvatar(title: title)

            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(1)

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: 240, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }
}

private struct SessionSectionHeader: View {
    let title: String
    let systemImage: String
    var accessory: String?

    var body: some View {
        HStack(spacing: 8) {
            Label(title, systemImage: systemImage)
                .font(.headline)

            Spacer(minLength: 8)

            if let accessory, !accessory.isEmpty {
                Text(accessory)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
        }
        .textCase(nil)
    }
}

private struct EmptyPinnedDropArea: View {
    let onDropSession: @MainActor (String) -> Void
    @State private var isTargeted = false

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: "pin.circle")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(isTargeted ? Color.blue : .secondary)

            Text("Pin chats here")
                .font(.subheadline.weight(.semibold))

            Text("Hold and drag a chat into this area, or use the Pin action from the context menu.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 24)
        .frame(maxWidth: .infinity)
        .background(background, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 20, style: .continuous)
                .strokeBorder(border, style: StrokeStyle(lineWidth: 1.5, dash: [7, 6]))
        }
        .onDrop(of: dropTypes, isTargeted: $isTargeted) { providers in
            loadDroppedSessionID(from: providers) { sessionID in
                withAnimation(opencodeSelectionAnimation) {
                    onDropSession(sessionID)
                }
            }
        }
    }

    private var background: Color {
        isTargeted ? Color.blue.opacity(0.10) : Color.primary.opacity(0.03)
    }

    private var border: Color {
        isTargeted ? Color.blue.opacity(0.55) : Color.primary.opacity(0.12)
    }
}

private let dropTypes: [UTType] = [
    .plainText,
    .text,
]

@discardableResult
private func loadDroppedSessionID(from providers: [NSItemProvider], perform: @MainActor @Sendable @escaping (String) -> Void) -> Bool {
    guard let provider = providers.first(where: { $0.canLoadObject(ofClass: NSString.self) }) else {
        return false
    }

    provider.loadObject(ofClass: NSString.self) { object, _ in
        guard let sessionID = object as? NSString else { return }
        let resolvedSessionID = String(sessionID)
        Task { @MainActor in
            perform(resolvedSessionID)
        }
    }

    return true
}
