import SwiftUI

struct QuestionPanel: View {
    let requests: [OpenCodeQuestionRequest]
    @Binding var answers: [String: Set<String>]
    @Binding var customAnswers: [String: String]
    let onDismiss: (OpenCodeQuestionRequest) -> Void
    let onSubmit: (OpenCodeQuestionRequest, [[String]]) -> Void

    private var requestIDs: String {
        requests.map { $0.id }.joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(requests) { request in
                VStack(alignment: .leading, spacing: 12) {
                    ForEach(Array(request.questions.enumerated()), id: \.offset) { entry in
                        let index = entry.offset
                        let question = entry.element
                        let key = storageKey(requestID: request.id, index: index)

                        VStack(alignment: .leading, spacing: 8) {
                            Text(question.header)
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                            Text(question.question)
                                .font(.subheadline.weight(.semibold))

                            VStack(spacing: 8) {
                                ForEach(question.options) { option in
                                    Button {
                                        toggle(option: option.label, for: key, multiple: question.multiple)
                                    } label: {
                                        HStack {
                                            Image(systemName: isSelected(option.label, key: key) ? "checkmark.circle.fill" : "circle")
                                                .foregroundStyle(isSelected(option.label, key: key) ? .blue : .secondary)
                                            VStack(alignment: .leading, spacing: 2) {
                                                Text(option.label)
                                                    .foregroundStyle(.primary)
                                                Text(option.description)
                                                    .font(.caption)
                                                    .foregroundStyle(.secondary)
                                            }
                                            Spacer()
                                        }
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 8)
                                        .contentShape(Rectangle())
                                        .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                                    }
                                    .buttonStyle(.plain)
                                    .animation(opencodeSelectionAnimation, value: answers[key, default: []])
                                }
                            }

                            if question.custom == true {
                                TextField("Type your answer", text: Binding(
                                    get: { customAnswers[key, default: ""] },
                                    set: { customAnswers[key] = $0 }
                                ))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 12)
                                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            }
                        }
                    }

                    VStack(spacing: 8) {
                        Button {
                            onSubmit(request, buildAnswers(for: request))
                        } label: {
                            HStack {
                                Spacer()
                                Text("Send Answer")
                                Spacer()
                            }
                            .padding(.vertical, 3)
                        }
                        .controlSize(.large)
                        .opencodePrimaryGlassButton()
                        .frame(maxWidth: .infinity)
                        .buttonBorderShape(.capsule)

                        Button {
                            onDismiss(request)
                        } label: {
                            HStack {
                                Spacer()
                                Text("Dismiss")
                                Spacer()
                            }
                            .padding(.vertical, 7)
                        }
                        .frame(maxWidth: .infinity)
                        .buttonStyle(.plain)
                    }
                }
                .padding(14)
                .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(opencodeSelectionAnimation, value: requestIDs)
    }

    private func storageKey(requestID: String, index: Int) -> String {
        "\(requestID)-\(index)"
    }

    private func isSelected(_ option: String, key: String) -> Bool {
        answers[key, default: []].contains(option)
    }

    private func toggle(option: String, for key: String, multiple: Bool) {
        var set = answers[key, default: []]
        if multiple {
            if set.contains(option) {
                set.remove(option)
            } else {
                set.insert(option)
            }
        } else {
            set = set.contains(option) ? [] : [option]
        }
        withAnimation(opencodeSelectionAnimation) {
            answers[key] = set
        }
    }

    private func buildAnswers(for request: OpenCodeQuestionRequest) -> [[String]] {
        request.questions.enumerated().map { index, _ in
            let key = storageKey(requestID: request.id, index: index)
            var values = Array(answers[key, default: []])
            let custom = customAnswers[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                values.append(custom)
            }
            return values
        }
    }
}
