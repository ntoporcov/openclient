import SwiftUI

#if os(iOS) && !targetEnvironment(macCatalyst)
struct ChatHeaderMenu: View {
    @ObservedObject var facade: ChatFacade
    let session: OpenCodeSession
    let containerWidth: CGFloat
    let containerHeight: CGFloat
    let glassNamespace: Namespace.ID
    var maximumWidth: CGFloat = 220
    @State private var scope: ChatFacade.HeaderScope?

    var body: some View {
        let current = facade.selectedSession?.id == session.id ? facade.selectedSession ?? session : session
        let title = facade.headerSnapshot(for: current).navigationTitle
        let toolbar = facade.toolbarSnapshot(for: current)
        Button {
            scope = facade.headerScope(for: current)
        } label: {
            VStack(alignment: .leading, spacing: 0) {
                Text(verbatim: title).font(.caption)
                Text(verbatim: toolbar.agentTitle)
                    .font(.caption2).foregroundStyle(.primary.opacity(0.72))
            }
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 8)
            .frame(minWidth: maximumWidth, idealWidth: maximumWidth, maxWidth: maximumWidth, minHeight: 44, alignment: .leading)
            .contentShape(Capsule())
            .opencodeToolbarGlassID("chat-header", in: glassNamespace)
        }
        .buttonStyle(.plain)
        .frame(minHeight: 44)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityIdentifier("chat.header")
        .popover(item: $scope, attachmentAnchor: .rect(.bounds), arrowEdge: .top) { scope in
            ChatHeaderPopover(facade: facade, scope: scope)
                .frame(width: max(1, containerWidth - 32), height: min(600, max(1, containerHeight - 16)))
                .presentationCompactAdaptation(.popover)
        }
        .onChange(of: facade.promptContextID) { scope = nil }
        .onChange(of: facade.selectedSession?.id) { scope = nil }
        .onChange(of: facade.promptConnectionID) { scope = nil }
        .onChange(of: facade.connectionStore.isConnected) { if !facade.connectionStore.isConnected { scope = nil } }
    }
}

private struct ChatHeaderPopover: View {
    @ObservedObject var facade: ChatFacade
    let scope: ChatFacade.HeaderScope
    @Environment(\.dismiss) private var dismiss
    @State private var title: String
    @State private var saving = false
    @State private var changingLiveActivity = false

    init(facade: ChatFacade, scope: ChatFacade.HeaderScope) {
        self.facade = facade
        self.scope = scope
        _title = State(initialValue: scope.session.title ?? "")
    }

    var body: some View {
        let session = facade.selectedSession ?? scope.session
        let snapshot = facade.toolbarSnapshot(for: session)
        let allowsAgentSelection = facade.allowsHeaderAgentSelection(scope)
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 8) {
                        TextField("Title", text: animatedTitleBinding, axis: .vertical)
                            .font(.headline)
                            .lineLimit(1...2)
                            .submitLabel(.done)
                            .onSubmit(saveTitle)
                            .accessibilityIdentifier("chat.header.rename.title")
                        if canSaveTitle {
                            Button(action: saveTitle) {
                                Image(systemName: "checkmark")
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.borderedProminent)
                            .buttonBorderShape(.circle)
                            .accessibilityLabel("Save")
                            .accessibilityIdentifier("chat.header.rename.save")
                            .transition(.scale(scale: 0.8).combined(with: .opacity))
                        }
                    }
                }
                if facade.supportsHeaderLiveActivity(scope) {
                    Section {
                        Toggle(isOn: liveActivityBinding) {
                            Label("Live Activity", systemImage: "waveform")
                        }
                        .disabled(changingLiveActivity)
                        .accessibilityIdentifier("chat.header.liveActivity")
                    }
                }
                Section("Agents") {
                    ForEach(snapshot.selectableAgents, id: \.name) { agent in
                        Button {
                            facade.selectHeaderAgent(named: agent.name, scope: scope)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(verbatim: agent.name)
                                        .font(.body)
                                    if let description = agent.description, !description.isEmpty {
                                        Text(verbatim: description)
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .lineLimit(2)
                                    }
                                }
                                Spacer()
                                if agent.name == snapshot.agentTitle {
                                    Image(systemName: "checkmark")
                                }
                            }
                            .foregroundStyle(.primary)
                            .frame(minHeight: 44)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .disabled(!allowsAgentSelection)
                        .accessibilityIdentifier("chat.header.agent.\(agent.name)")
                        .accessibilityAddTraits(agent.name == snapshot.agentTitle ? .isSelected : [])
                    }
                }
                if let error = facade.presentationErrorMessage {
                    Text(verbatim: error).foregroundStyle(.red)
                }
            }
            .accessibilityIdentifier("chat.header.list")
            .navigationTitle("Chat")
            .navigationBarTitleDisplayMode(.inline)
        }
        .accessibilityIdentifier("chat.header.popover")
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }

    private var animatedTitleBinding: Binding<String> {
        Binding(get: { title }, set: { newValue in
            withAnimation(.snappy(duration: 0.2)) { title = newValue }
        })
    }

    private var canSaveTitle: Bool {
        !saving && !trimmedTitle.isEmpty && trimmedTitle != (facade.selectedSession ?? scope.session).title
            && facade.allowsHeaderActions(scope)
    }

    private var liveActivityBinding: Binding<Bool> {
        Binding(get: { facade.isHeaderLiveActivityActive(scope) }, set: { isActive in
            guard isActive != facade.isHeaderLiveActivityActive(scope), !changingLiveActivity else { return }
            changingLiveActivity = true
            Task {
                await facade.toggleHeaderLiveActivity(scope)
                guard facade.isCurrentHeaderScope(scope) else { return }
                changingLiveActivity = false
            }
        })
    }

    private func saveTitle() {
        guard canSaveTitle else { return }
        withAnimation(.snappy(duration: 0.2)) { saving = true }
        let submittedTitle = trimmedTitle
        Task {
            await facade.renameHeaderSession(scope, title: submittedTitle)
            guard facade.isCurrentHeaderScope(scope) else { return }
            withAnimation(.snappy(duration: 0.2)) { saving = false }
            if facade.selectedSession?.title == submittedTitle { dismiss() }
        }
    }
}
#endif
