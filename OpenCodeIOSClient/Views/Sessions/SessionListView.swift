import SwiftUI

struct SessionListView: View {
    @ObservedObject var viewModel: AppViewModel
    let onSessionChosen: () -> Void

    var body: some View {
        List {
            Section("Sessions") {
                ForEach(viewModel.sessions) { session in
                    Button {
                        Task {
                            await viewModel.selectSession(session)
                            onSessionChosen()
                        }
                    } label: {
                        SessionRow(viewModel: viewModel, session: session)
                    }
                    .buttonStyle(.plain)
                    .listRowBackground(viewModel.selectedSession?.id == session.id ? Color.blue.opacity(0.10) : Color.clear)
                    .listRowInsets(EdgeInsets(top: 10, leading: 16, bottom: 10, trailing: 16))
                    .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                        Button(role: .destructive) {
                            Task { await viewModel.deleteSession(session) }
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            }

            if let errorMessage = viewModel.errorMessage {
                Section("Error") {
                    Text(errorMessage)
                        .foregroundStyle(.red)
                }
            }
        }
        .listStyle(.plain)
        .navigationTitle(viewModel.projectScopeTitle.split(separator: "/").last.map(String.init) ?? viewModel.projectScopeTitle)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    viewModel.presentCreateSessionSheet()
                } label: {
                    Image(systemName: "square.and.pencil")
                }
                .accessibilityLabel("Create Session")
                .accessibilityIdentifier("sessions.create")
            }
        }
        .sheet(isPresented: $viewModel.isShowingCreateSessionSheet) {
            CreateSessionSheet(viewModel: viewModel)
        }
    }
}
