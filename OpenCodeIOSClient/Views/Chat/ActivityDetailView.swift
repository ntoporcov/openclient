import SwiftUI

struct ActivityDetail: Identifiable {
    let id = UUID()
    let message: OpenCodeMessageEnvelope
    let part: OpenCodePart

    var sessionID: String {
        part.sessionID ?? message.info.sessionID ?? ""
    }

    var messageID: String {
        part.messageID ?? message.info.id
    }
}

struct ActivityDetailView: View {
    @ObservedObject var viewModel: AppViewModel
    let detail: ActivityDetail
    @State private var loadedMessage: OpenCodeMessageEnvelope?
    @State private var loadError: String?

    private var effectiveMessage: OpenCodeMessageEnvelope {
        loadedMessage ?? detail.message
    }

    private var effectivePart: OpenCodePart {
        guard let partID = detail.part.id,
              let matched = effectiveMessage.parts.first(where: { $0.id == partID }) else {
            return detail.part
        }
        return matched
    }

    var body: some View {
        List {
            Section("Activity") {
                LabeledContent("Type", value: effectivePart.type)
                if let tool = effectivePart.tool {
                    LabeledContent("Tool", value: tool)
                }
                LabeledContent("Role", value: effectiveMessage.info.role ?? "unknown")
                LabeledContent("Message ID", value: effectiveMessage.info.id)
                if let partID = effectivePart.id {
                    LabeledContent("Part ID", value: partID)
                }
                if let callID = effectivePart.callID {
                    LabeledContent("Call ID", value: callID)
                }
                if let sessionID = effectivePart.sessionID ?? effectiveMessage.info.sessionID {
                    LabeledContent("Session ID", value: sessionID)
                }
                if let reason = effectivePart.reason {
                    LabeledContent("Reason", value: reason)
                }
                if let status = effectivePart.state?.status {
                    LabeledContent("Status", value: status)
                }
            }

            if let loadError {
                Section("Error") {
                    Text(loadError)
                        .foregroundStyle(.red)
                }
            }

            if let input = effectivePart.state?.input {
                Section("Input") {
                    if let command = input.command {
                        DetailTextBlock(text: command)
                    }
                    if let path = input.path {
                        DetailTextBlock(text: path)
                    }
                    if let query = input.query {
                        DetailTextBlock(text: query)
                    }
                    if let pattern = input.pattern {
                        DetailTextBlock(text: pattern)
                    }
                    if let url = input.url {
                        DetailTextBlock(text: url)
                    }
                    if let description = input.description {
                        DetailTextBlock(text: description)
                    }
                }
            }

            if let output = effectivePart.state?.output ?? effectivePart.state?.metadata?.output,
               !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Output") {
                    DetailTextBlock(text: output)
                }
            }

            if let error = effectivePart.state?.error,
               !error.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Error") {
                    DetailTextBlock(text: error)
                        .foregroundStyle(.red)
                }
            }

            if let text = effectivePart.text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Section("Details") {
                    DetailTextBlock(text: text)
                }
            }
        }
        .navigationTitle(effectivePart.type.replacingOccurrences(of: "-", with: " ").capitalized)
        .navigationBarTitleDisplayMode(.inline)
        .task {
            guard !detail.sessionID.isEmpty, !detail.messageID.isEmpty else { return }
            do {
                loadedMessage = try await viewModel.fetchMessageDetails(sessionID: detail.sessionID, messageID: detail.messageID)
                loadError = nil
            } catch {
                loadError = error.localizedDescription
            }
        }
    }
}
