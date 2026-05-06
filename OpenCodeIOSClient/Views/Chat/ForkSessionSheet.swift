import SwiftUI

struct ForkSessionSheet: View {
    @ObservedObject var viewModel: AppViewModel
    let sessionID: String

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""

    private var messages: [OpenCodeForkableMessage] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return viewModel.forkableMessages }
        return viewModel.forkableMessages.filter { $0.text.localizedCaseInsensitiveContains(query) }
    }

    var body: some View {
        List {
            if messages.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "No User Messages" : "No Matches",
                    systemImage: "arrow.triangle.branch",
                    description: Text(searchText.isEmpty ? "Send a message before forking this session." : "Try a different search.")
                )
                .listRowBackground(Color.clear)
            } else {
                ForEach(messages) { message in
                    Button {
                        Task {
                            await viewModel.forkSelectedSession(from: message.id)
                            dismiss()
                        }
                    } label: {
                        ForkMessageRow(message: message, isPreparing: viewModel.pendingForkMessageID == message.id)
                    }
                    .buttonStyle(.plain)
                    .disabled(viewModel.pendingForkMessageID != nil)
                    .accessibilityIdentifier("chat.fork.message.\(message.id)")
                }
            }
        }
        .navigationTitle("Fork Session")
        .navigationBarTitleDisplayMode(.inline)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search messages")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") {
                    viewModel.isShowingForkSessionSheet = false
                    dismiss()
                }
                .disabled(viewModel.pendingForkMessageID != nil)
            }
        }
    }
}

private struct ForkMessageRow: View {
    let message: OpenCodeForkableMessage
    let isPreparing: Bool

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

            if isPreparing {
                ProgressView()
                    .controlSize(.small)
                    .padding(.top, 2)
                    .accessibilityLabel("Preparing fork")
            } else {
                Image(systemName: "arrow.triangle.branch")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.vertical, 4)
    }
}
