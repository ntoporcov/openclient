import SwiftUI

struct GlobalFormsBanner: View {
    let facade: GlobalFormsFacade
    let location: BackendFormLocation?
    @State private var presented: BackendFormLocation?

    var body: some View {
        VStack(spacing: 0) {
            if !facade.pending(for: location).isEmpty, let origin = facade.canonical(location) {
                Button {
                    presented = origin
                } label: {
                    Label("Project Input Required", systemImage: "text.bubble")
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                        .frame(minHeight: 44)
                }
                .accessibilityIdentifier("globalForms.open")
                .background(.regularMaterial)
            } else if facade.errors.contains(location) {
                Button("Check Project Requests") { facade.request(location) }
                    .padding(12)
            }
        }
        .task(id: location) { await facade.hydrate(location) }
        .onChange(of: facade.connectionID) { _, _ in presented = nil }
        .sheet(isPresented: Binding(get: { presented != nil }, set: { if !$0 { presented = nil } })) {
            if let origin = presented {
                GlobalFormsSheet(facade: facade, location: origin)
            }
        }
    }
}

private struct GlobalFormsSheet: View {
    let facade: GlobalFormsFacade
    let location: BackendFormLocation
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(location.directory).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    if let workspace = location.workspaceID { Text(workspace).font(.caption).foregroundStyle(.secondary) }
                    if let store = facade.store(for: location), !facade.pending(for: location).isEmpty {
                        SessionFormPanel(forms: facade.pending(for: location), store: store,
                            contextID: facade.connectionID?.uuidString ?? "disconnected", allowsActions: true,
                            submit: { await facade.submit($0, at: location) },
                            cancel: { await facade.cancel($0, at: location) },
                            refresh: { await facade.refresh($0, at: location) })
                    } else {
                        Text("No Pending Project Requests")
                            .accessibilityIdentifier("globalForms.empty")
                    }
                }
                .padding()
            }
            .navigationTitle("Project Requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Close") { dismiss() }.accessibilityIdentifier("globalForms.close")
                }
            }
        }
    }
}
