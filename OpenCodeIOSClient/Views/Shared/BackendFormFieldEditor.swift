import SwiftUI

struct BackendFormFieldEditor: View {
    let field: BackendFormField
    @Binding var value: OpenCodeJSONValue?
    var usesQuestionStyle = false
    var onSelectAnswer: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(usesQuestionStyle ? field.raw["description"]?.v2ConfigurationString ?? field.title : field.title)
                .font(.headline)
                .multilineTextAlignment(usesQuestionStyle ? .center : .leading)
                .frame(maxWidth: .infinity, alignment: usesQuestionStyle ? .center : .leading)
            if !usesQuestionStyle, let description = field.raw["description"]?.v2ConfigurationString {
                Text(description).font(.caption).foregroundStyle(.secondary)
            }
            if field.type == "external" {
                if let url = field.browserURL {
                    Link("Open Browser", destination: url)
                    Toggle("I completed this step", isOn: Binding(
                        get: { value == .bool(true) }, set: { value = $0 ? .bool(true) : nil }
                    ))
                } else {
                    Text("This link cannot be opened safely. You can cancel the request.")
                        .foregroundStyle(.secondary)
                }
            } else if field.type == "boolean" {
                Picker(field.title, selection: $value) {
                    Text("Not Set").tag(Optional<OpenCodeJSONValue>.none)
                    Text("Yes").tag(Optional(OpenCodeJSONValue.bool(true)))
                    Text("No").tag(Optional(OpenCodeJSONValue.bool(false)))
                }
            } else if field.type == "multiselect" || (field.type == "string" && field.raw["options"] != nil) {
                BackendFormOptionsEditor(field: field, value: $value,
                    usesQuestionStyle: usesQuestionStyle, onSelectAnswer: onSelectAnswer)
                if field.allowsCustom {
                    if field.type == "multiselect" {
                        BackendFormCustomSelectionsEditor(value: $value, options: field.options,
                            usesQuestionStyle: usesQuestionStyle)
                    } else {
                        BackendFormTextEditor(field: field, value: $value, usesQuestionStyle: usesQuestionStyle)
                    }
                }
            } else {
                BackendFormTextEditor(field: field, value: $value, usesQuestionStyle: usesQuestionStyle)
            }
            if !field.required {
                Button("Not Set") { value = nil }.disabled(value == nil)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("form.field.\(field.id)")
    }
}

private struct BackendFormTextEditor: View {
    let field: BackendFormField
    @Binding var value: OpenCodeJSONValue?
    var usesQuestionStyle = false

    var body: some View {
        TextField(field.raw["placeholder"]?.v2ConfigurationString ?? field.title, text: Binding(
            get: {
                if usesQuestionStyle && field.options.contains(where: { $0["value"]?.v2FormEquals(value ?? .null) == true }) {
                    return ""
                }
                return value?.stringValue ?? ""
            },
            set: { text in value = text.isEmpty && field.type != "string" ? nil : .string(text) }
        ), axis: field.type == "string" ? .vertical : .horizontal)
        .lineLimit(1...4)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        .padding(.horizontal, usesQuestionStyle ? 14 : 0)
        .padding(.vertical, usesQuestionStyle ? 12 : 0)
        .background {
            if usesQuestionStyle {
                Color.clear.opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        }
        #if os(iOS)
        .keyboardType(field.type == "number" || field.type == "integer" ? .numbersAndPunctuation : .default)
        #endif
    }
}

private struct BackendFormOptionsEditor: View {
    let field: BackendFormField
    @Binding var value: OpenCodeJSONValue?
    let usesQuestionStyle: Bool
    let onSelectAnswer: () -> Void

    var body: some View {
        ForEach(field.options, id: \.self) { option in
            if let optionValue = option["value"], let label = option["label"]?.v2ConfigurationString {
                let selected = field.type == "multiselect"
                    ? value?.arrayValue?.contains { $0.v2FormEquals(optionValue) == true } == true
                    : value?.v2FormEquals(optionValue) == true
                let select: () -> Void = {
                    if field.type == "multiselect" {
                        var selections = value?.arrayValue ?? []
                        selections.removeAll { $0.v2FormEquals(optionValue) == true }
                        if !selected { selections.append(optionValue) }
                        value = .array(selections)
                    } else {
                        value = selected ? nil : optionValue
                        if !selected { onSelectAnswer() }
                    }
                }
                if usesQuestionStyle {
                    QuestionOptionButton(title: label,
                        detail: option["description"]?.v2ConfigurationString
                            ?? (field.options.filter { $0["label"]?.v2ConfigurationString == label }.count > 1
                                ? optionValue.v2ConfigurationString ?? "" : ""),
                        isSelected: selected, allowsMultipleSelection: field.type == "multiselect",
                        action: select)
                        .accessibilityIdentifier("form.option.\(field.id).\(optionValue.v2ConfigurationString ?? "")")
                } else {
                    Button(action: select) {
                        HStack(alignment: .top) {
                            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(label)
                                if let description = option["description"]?.v2ConfigurationString {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                } else if field.options.filter({ $0["label"]?.v2ConfigurationString == label }).count > 1 {
                                    Text(optionValue.v2ConfigurationString ?? "").font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
        }
    }
}

private struct BackendFormCustomSelectionsEditor: View {
    @Binding var value: OpenCodeJSONValue?
    let options: [[String: OpenCodeJSONValue]]
    let usesQuestionStyle: Bool
    @State private var text = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach((value?.arrayValue ?? []).filter { candidate in
                !options.contains { $0["value"]?.v2FormEquals(candidate) == true }
            }, id: \.self) { selection in
                HStack {
                    Text(selection.v2ConfigurationString ?? "")
                    Spacer()
                    Button("Remove") {
                        value = .array((value?.arrayValue ?? []).filter { $0.v2FormEquals(selection) != true })
                    }
                }
            }
            HStack {
                TextField("Type your answer", text: $text)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .focused($isFocused)
                    .submitLabel(.done)
                    .onSubmit(addSelection)
                Button("Add", action: addSelection)
                    .disabled(text.isEmpty)
            }
            .padding(.horizontal, usesQuestionStyle ? 14 : 0)
            .padding(.vertical, usesQuestionStyle ? 12 : 0)
            .background {
                if usesQuestionStyle {
                    Color.clear.opencodeGlassSurface(in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                }
            }
        }
    }

    private func addSelection() {
        guard !text.isEmpty else { return }
        var selections = value?.arrayValue ?? []
        let next = OpenCodeJSONValue.string(text)
        if !selections.contains(where: { $0.v2FormEquals(next) == true }) { selections.append(next) }
        value = .array(selections)
        text = ""
        isFocused = false
    }
}
