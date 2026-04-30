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

    private var patchDiffs: [OpenCodeUnifiedDiffData] {
        guard effectivePart.tool == "apply_patch" else { return [] }
        return (effectivePart.state?.metadata?.files ?? []).compactMap(ActivityPatchFile.init).map(\.diff)
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

            if !patchDiffs.isEmpty {
                Section(patchDiffs.count == 1 ? "Patch Diff" : "Patch Diffs") {
                    ForEach(Array(patchDiffs.enumerated()), id: \.offset) { _, diff in
                        VStack(alignment: .leading, spacing: 12) {
                            Text(diff.file)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)

                            OpenCodeUnifiedDiffView(diff: diff, showsHeader: false)
                                .frame(minHeight: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
                                )
                        }
                        .padding(.vertical, 4)
                    }
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
        .opencodeInlineNavigationTitle()
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

private struct ActivityPatchFile {
    let diff: OpenCodeUnifiedDiffData

    init?(_ value: OpenCodeJSONValue) {
        guard let object = value.objectValue else { return nil }

        let relativePath = object["relativePath"]?.stringValue
        let filePath = object["filePath"]?.stringValue
        let file = relativePath ?? filePath
        let patch = object["patch"]?.stringValue ?? object["diff"]?.stringValue
        let before = object["before"]?.stringValue
        let after = object["after"]?.stringValue

        guard let file else { return nil }
        guard let renderedPatch = patch ?? Self.makePatch(file: file, before: before, after: after) else { return nil }

        let additions = Self.intValue(object["additions"])
        let deletions = Self.intValue(object["deletions"])
        let status = Self.status(from: object["type"]?.stringValue)

        diff = OpenCodeUnifiedDiffData(
            file: file,
            patch: renderedPatch,
            additions: additions,
            deletions: deletions,
            status: status
        )
    }

    private static func intValue(_ value: OpenCodeJSONValue?) -> Int {
        if let string = value?.stringValue, let parsed = Int(string) {
            return parsed
        }
        if let number = value?.doubleValue {
            return Int(number)
        }
        return 0
    }

    private static func status(from type: String?) -> String? {
        switch type {
        case "add":
            return "added"
        case "delete":
            return "deleted"
        case "update", "move":
            return "modified"
        default:
            return nil
        }
    }

    private static func makePatch(file: String, before: String?, after: String?) -> String? {
        guard before != nil || after != nil else { return nil }

        let beforeLines = (before ?? "").components(separatedBy: .newlines)
        let afterLines = (after ?? "").components(separatedBy: .newlines)
        let oldCount = lineCount(before ?? "")
        let newCount = lineCount(after ?? "")

        var patchLines = [
            "--- \(file)",
            "+++ \(file)",
            "@@ -1,\(oldCount) +1,\(newCount) @@"
        ]
        patchLines.append(contentsOf: beforeLines.map { "-\($0)" })
        patchLines.append(contentsOf: afterLines.map { "+\($0)" })
        return patchLines.joined(separator: "\n")
    }

    private static func lineCount(_ text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        return text.components(separatedBy: .newlines).count
    }
}
