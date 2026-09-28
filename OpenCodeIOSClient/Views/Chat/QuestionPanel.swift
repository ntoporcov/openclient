import SwiftUI

struct QuestionPanel: View {
    let requests: [OpenCodeQuestionRequest]
    @Binding var answers: [String: Set<String>]
    @Binding var customAnswers: [String: String]
    let onDismiss: (OpenCodeQuestionRequest) -> Void
    let onSubmit: (OpenCodeQuestionRequest, [[String]]) -> Void

    private var requestIDs: String {
        requests.map(\.id).joined(separator: "|")
    }

    var body: some View {
        VStack(spacing: 12) {
            ForEach(requests) { request in
                QuestionRequestCarousel(
                    request: request,
                    answers: $answers,
                    customAnswers: $customAnswers,
                    onDismiss: { onDismiss(request) },
                    onSubmit: { onSubmit(request, $0) }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(opencodeSelectionAnimation, value: requestIDs)
    }
}

private struct QuestionRequestCarousel: View {
    let request: OpenCodeQuestionRequest
    @Binding var answers: [String: Set<String>]
    @Binding var customAnswers: [String: String]
    let onDismiss: () -> Void
    let onSubmit: ([[String]]) -> Void

    @State private var selectedQuestionIndex: Int? = 0

    var body: some View {
        VStack(spacing: 12) {
            if request.questions.isEmpty {
                Text("No questions were provided.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 24)
                    .padding(.horizontal, 14)
                    .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                    .padding(.horizontal, 16)
            } else {
                ScrollView(.horizontal) {
                    HStack(alignment: .bottom, spacing: 12) {
                        ForEach(request.questions.indices, id: \.self) { index in
                            let question = request.questions[index]
                            let key = storageKey(index: index)

                            QuestionCarouselPage(
                                question: question,
                                index: index,
                                questionCount: request.questions.count,
                                selectedOptions: answers[key, default: []],
                                customAnswer: customAnswerBinding(for: key, multiple: question.multiple),
                                onSelectOption: { option in
                                    select(option: option, for: question, key: key, index: index)
                                },
                                onSubmitCustomAnswer: {
                                    advance(after: index)
                                }
                            )
                            .padding(14)
                            .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .containerRelativeFrame(.horizontal)
                            .id(index)
                        }
                    }
                    .scrollTargetLayout()
                }
                .scrollClipDisabled()
                .contentMargins(.horizontal, 24, for: .scrollContent)
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned(limitBehavior: .always))
                .scrollPosition(id: $selectedQuestionIndex)
                .animation(opencodeSelectionAnimation, value: selectedQuestionIndex)
                .accessibilityIdentifier("question.carousel.\(request.id)")

                if request.questions.count > 1 {
                    QuestionPageIndicator(
                        count: request.questions.count,
                        selectedIndex: selectedQuestionIndex ?? 0,
                        onSelect: { index in
                            withAnimation(opencodeSelectionAnimation) {
                                selectedQuestionIndex = index
                            }
                        }
                    )
                }
            }

            QuestionGroupActions(
                requestID: request.id,
                submitLabel: submitLabel,
                isSubmitEnabled: answeredQuestionCount == request.questions.count && !request.questions.isEmpty,
                onDismiss: onDismiss,
                onSubmit: { onSubmit(buildAnswers()) }
            )
            .padding(8)
            .opencodeConcentricGlassSurface(
                minimumCornerRadius: 30,
                in: Capsule()
            )
            .padding(.horizontal, 16)
        }
    }

    private func storageKey(index: Int) -> String {
        "\(request.id)-\(index)"
    }

    private var answeredQuestionCount: Int {
        request.questions.indices.reduce(into: 0) { count, index in
            let key = storageKey(index: index)
            let hasSelectedOption = !answers[key, default: []].isEmpty
            let customAnswer = customAnswers[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if hasSelectedOption || !customAnswer.isEmpty {
                count += 1
            }
        }
    }

    private var submitLabel: LocalizedStringResource {
        if answeredQuestionCount == request.questions.count && !request.questions.isEmpty {
            return "Submit"
        }
        if answeredQuestionCount == 0 {
            return "No Answers"
        }
        return "\(answeredQuestionCount) of \(request.questions.count)"
    }

    private func customAnswerBinding(for key: String, multiple: Bool) -> Binding<String> {
        Binding(
            get: { customAnswers[key, default: ""] },
            set: { value in
                customAnswers[key] = value
                if !multiple && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    answers[key] = []
                }
            }
        )
    }

    private func select(option: String, for question: OpenCodeQuestion, key: String, index: Int) {
        var selected = answers[key, default: []]

        if question.multiple {
            if selected.contains(option) {
                selected.remove(option)
            } else {
                selected.insert(option)
            }
        } else if selected.contains(option) {
            selected.removeAll()
        } else {
            selected = [option]
            customAnswers[key] = ""
        }

        withAnimation(opencodeSelectionAnimation) {
            answers[key] = selected
            if !question.multiple && selected.contains(option) {
                advance(after: index)
            }
        }
    }

    private func advance(after index: Int) {
        guard index < request.questions.count - 1 else { return }
        selectedQuestionIndex = index + 1
    }

    private func buildAnswers() -> [[String]] {
        request.questions.enumerated().map { index, question in
            let key = storageKey(index: index)
            let selected = answers[key, default: []]
            var values = question.options.map(\.label).filter(selected.contains)
            let custom = customAnswers[key, default: ""].trimmingCharacters(in: .whitespacesAndNewlines)
            if !custom.isEmpty {
                values.append(custom)
            }
            return values
        }
    }
}

private struct QuestionCarouselPage: View {
    let question: OpenCodeQuestion
    let index: Int
    let questionCount: Int
    let selectedOptions: Set<String>
    @Binding var customAnswer: String
    let onSelectOption: (String) -> Void
    let onSubmitCustomAnswer: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(question.header)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)

                Spacer(minLength: 12)

                if questionCount > 1 {
                    Text("\(index + 1) of \(questionCount)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.tertiary)
                }
            }

            Text(question.question)
                .font(.headline)
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

            VStack(spacing: 8) {
                ForEach(question.options) { option in
                    QuestionOptionButton(
                        title: option.label,
                        detail: option.description,
                        isSelected: selectedOptions.contains(option.label),
                        allowsMultipleSelection: question.multiple,
                        action: { onSelectOption(option.label) }
                    )
                }
            }

            if question.custom != false {
                TextField("Type your answer", text: $customAnswer)
                    .submitLabel(index < questionCount - 1 ? .next : .done)
                    .onSubmit(onSubmitCustomAnswer)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        .padding(.horizontal, 2)
        .frame(maxWidth: .infinity, alignment: .center)
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("question.page.\(index)")
    }
}

/// Shared choice styling for legacy questions and typed V2 forms.
struct QuestionOptionButton: View {
    let title: String
    let detail: String
    let isSelected: Bool
    let allowsMultipleSelection: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: selectionIcon)
                    .font(.title3)
                    .foregroundStyle(isSelected ? .blue : .secondary)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    if !detail.isEmpty {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .animation(opencodeSelectionAnimation, value: isSelected)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var selectionIcon: String {
        if allowsMultipleSelection {
            return isSelected ? "checkmark.square.fill" : "square"
        }
        return isSelected ? "checkmark.circle.fill" : "circle"
    }
}

struct QuestionPageIndicator: View {
    @Environment(\.appSystemAccentColor) private var appAccentColor
    let count: Int
    let selectedIndex: Int
    let onSelect: (Int) -> Void

    var body: some View {
        HStack(spacing: 6) {
            ForEach(0..<count, id: \.self) { index in
                Button {
                    onSelect(index)
                } label: {
                    Capsule()
                        .fill(index == selectedIndex ? appAccentColor : Color.secondary.opacity(0.35))
                        .frame(width: index == selectedIndex ? 18 : 6, height: 6)
                        .contentShape(Rectangle().inset(by: -8))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Question \(index + 1)")
                .accessibilityValue(index == selectedIndex ? LocalizedStringResource("Current") : LocalizedStringResource(""))
            }
        }
        .animation(opencodeSelectionAnimation, value: selectedIndex)
    }
}

private struct QuestionGroupActions: View {
    let requestID: String
    let submitLabel: LocalizedStringResource
    let isSubmitEnabled: Bool
    let onDismiss: () -> Void
    let onSubmit: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(role: .cancel, action: onDismiss) {
                Text("Dismiss")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
                .controlSize(.large)
                .buttonStyle(.plain)
                .frame(maxWidth: .infinity)
                .frame(height: 52)
                .contentShape(Capsule())
                .accessibilityIdentifier("question.dismiss.\(requestID)")

            Button(action: onSubmit) {
                Text(submitLabel)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .controlSize(.large)
            .modifier(AppAccentActionModifier())
            .opencodePrimaryGlassButton()
            .frame(maxWidth: .infinity)
            .frame(height: 52)
            .disabled(!isSubmitEnabled)
            .animation(opencodeSelectionAnimation, value: submitLabel)
            .accessibilityIdentifier("question.submit.\(requestID)")
        }
    }
}
