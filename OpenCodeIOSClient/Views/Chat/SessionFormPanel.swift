import SwiftUI

/// A bounded editor in the composer area. Permissions retain priority in ChatView.
struct SessionFormPanel: View {
    let forms: [BackendForm]
    let store: SessionFormStore
    let contextID: String
    let allowsActions: Bool
    let submit: (BackendForm) async -> Void
    let cancel: (BackendForm) async -> Void
    let refresh: (BackendForm) async -> Void

    var body: some View {
        if let form = forms.first {
            SessionFormCard(form: form, pendingCount: forms.count, store: store, contextID: contextID,
                allowsActions: allowsActions, submit: { await submit(form) },
                cancel: { await cancel(form) }, refresh: { await refresh(form) })
                .id(form.key)
        }
    }
}

private struct SessionFormCard: View {
    let form: BackendForm
    let pendingCount: Int
    let store: SessionFormStore
    let contextID: String
    let allowsActions: Bool
    let submit: () async -> Void
    let cancel: () async -> Void
    let refresh: () async -> Void
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        let state = store.state(for: form.key)
        let fields = form.contract.activeFields(values: state.draft)
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(form.title).font(.headline)
                Spacer()
                if state.phase.isBusy { ProgressView() }
            }
            if let message = form.metadata?["message"]?.literalStringValue {
                Text(message).font(.subheadline).foregroundStyle(.secondary)
            }
            if pendingCount > 1 {
                Text("\(pendingCount) pending forms").font(.caption).foregroundStyle(.secondary)
            }
            if form.contract.isSupported() {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        ForEach(fields) { field in
                            VStack(alignment: .leading, spacing: 4) {
                                HStack {
                                    if field.required { Text("Required") } else { Text("Optional") }
                                    if state.draft[field.id] == nil && field.raw["default"] != nil { Text("Default") }
                                }
                                .font(.caption).foregroundStyle(.secondary)
                                BackendFormFieldEditor(field: field, value: Binding(
                                    get: {
                                        let value = state.draft[field.id] ?? field.raw["default"]
                                        return value == .null ? nil : value
                                    },
                                    set: { store.setValue($0, fieldID: field.id, for: form.key) }
                                ))
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 280)
                .fixedSize(horizontal: false, vertical: true)
                .disabled(!allowsActions || state.phase.isBusy || state.phase == .unavailable)
            } else {
                Text("This form contains unsupported fields. You can cancel the request.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if let error = state.errorMessage {
                Text(error).font(.subheadline).foregroundStyle(.red)
                    .accessibilityIdentifier("form.error.\(form.id)")
            } else if state.phase == .uncertain {
                Text("The form status is unknown. Check status before trying again.")
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            if !allowsActions {
                Text("Form actions are unavailable on this connection.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel Request", role: .cancel) { Task { await cancel() } }
                    .disabled(!allowsActions || state.phase != .ready)
                    .accessibilityIdentifier("form.cancel.\(form.id)")
                Spacer()
                if state.phase == .uncertain || state.phase == .unavailable {
                    Button("Check Status") { Task { await refresh() } }
                        .disabled(!allowsActions)
                        .accessibilityIdentifier("form.refresh.\(form.id)")
                } else {
                    Button("Submit") { Task { await submit() } }
                        .buttonStyle(.borderedProminent)
                        .disabled(!allowsActions || state.phase != .ready || !form.contract.isSupported())
                        .accessibilityIdentifier("form.submit.\(form.id)")
                }
            }
        }
        .padding(14)
        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityIdentifier("chat.sessionForm.\(form.id)")
        .task(id: contextID) { if allowsActions { await refresh() } }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active && allowsActions { Task { await refresh() } }
        }
    }
}
