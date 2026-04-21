import SwiftUI

struct TodoInspectorView: View {
    @ObservedObject var viewModel: AppViewModel
    @State private var refreshedTodos: [OpenCodeTodo] = []
    @State private var todoMessageDetail: OpenCodeMessageEnvelope?
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var lastRefreshedAt: Date?
    @State private var rawTodoJSON = ""

    var body: some View {
        List {
            Section("Source") {
                if let selectedSession = viewModel.selectedSession {
                    LabeledContent("Session ID", value: selectedSession.id)
                }
                if let lastRefreshedAt {
                    LabeledContent("Last Refreshed", value: lastRefreshedAt.formatted(date: .omitted, time: .standard))
                }
                Text("Todo status comes directly from `GET /session/:id/todo`.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if let loadError {
                Section("Error") {
                    Text(loadError)
                        .foregroundStyle(.red)
                }
            }

            Section("Todos") {
                ForEach(refreshedTodos.isEmpty ? viewModel.todos : refreshedTodos) { todo in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: todo.isComplete ? "checkmark.circle.fill" : (todo.isInProgress ? "clock.badge" : "circle"))
                            .foregroundStyle(todo.isComplete ? .green : (todo.isInProgress ? .blue : .secondary))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(todo.content)
                            Text(todo.status.replacingOccurrences(of: "_", with: " ").capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }

            if let todoMessageDetail {
                Section("Todowrite Context") {
                    Text(todoMessageDetail.parts.compactMap(\.text).joined(separator: "\n\n"))
                        .font(.system(.body, design: .monospaced))
                        .textSelection(.enabled)
                }
            }

            if !rawTodoJSON.isEmpty {
                Section("Raw /todo JSON") {
                    Text(rawTodoJSON)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                }
            }
        }
        .navigationTitle("Todos")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button(isLoading ? "Refreshing..." : "Refresh") {
                    Task { await refresh() }
                }
                .disabled(isLoading)
            }
        }
        .task {
            await refresh()
        }
    }

    private func refresh() async {
        isLoading = true
        defer { isLoading = false }
        do {
            let result = try await viewModel.refreshTodosAndLatestTodoMessage()
            refreshedTodos = result.todos
            todoMessageDetail = result.detail
            lastRefreshedAt = Date()
            rawTodoJSON = encodedTodos(result.todos)
            loadError = nil
        } catch {
            loadError = error.localizedDescription
        }
    }

    private func encodedTodos(_ todos: [OpenCodeTodo]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(todos), let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }
}
