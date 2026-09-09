import SwiftUI

struct BackendFormFieldEditor: View {
    let field: BackendFormField
    @Binding var value: OpenCodeJSONValue?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(field.title).font(.headline)
            if let description = field.raw["description"]?.v2ConfigurationString {
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
                BackendFormOptionsEditor(field: field, value: $value)
                if field.allowsCustom {
                    if field.type == "multiselect" {
                        BackendFormCustomSelectionsEditor(value: $value, options: field.options)
                    } else {
                        BackendFormTextEditor(field: field, value: $value)
                    }
                }
            } else {
                BackendFormTextEditor(field: field, value: $value)
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

    var body: some View {
        TextField(field.raw["placeholder"]?.v2ConfigurationString ?? field.title, text: Binding(
            get: { value?.stringValue ?? "" },
            set: { text in value = text.isEmpty && field.type != "string" ? nil : .string(text) }
        ), axis: field.type == "string" ? .vertical : .horizontal)
        .lineLimit(1...4)
        .textInputAutocapitalization(.never)
        .autocorrectionDisabled()
        #if os(iOS)
        .keyboardType(field.type == "number" || field.type == "integer" ? .numbersAndPunctuation : .default)
        #endif
    }
}

private struct BackendFormOptionsEditor: View {
    let field: BackendFormField
    @Binding var value: OpenCodeJSONValue?

    var body: some View {
        ForEach(field.options, id: \.self) { option in
            if let optionValue = option["value"], let label = option["label"]?.v2ConfigurationString {
                let selected = field.type == "multiselect"
                    ? value?.arrayValue?.contains { $0.v2FormEquals(optionValue) == true } == true
                    : value?.v2FormEquals(optionValue) == true
                Button {
                    if field.type == "multiselect" {
                        var selections = value?.arrayValue ?? []
                        selections.removeAll { $0.v2FormEquals(optionValue) == true }
                        if !selected { selections.append(optionValue) }
                        value = .array(selections)
                    } else { value = selected ? nil : optionValue }
                } label: {
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

private struct BackendFormCustomSelectionsEditor: View {
    @Binding var value: OpenCodeJSONValue?
    let options: [[String: OpenCodeJSONValue]]
    @State private var text = ""

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
                Button("Add") {
                    var selections = value?.arrayValue ?? []
                    let next = OpenCodeJSONValue.string(text)
                    if !selections.contains(where: { $0.v2FormEquals(next) == true }) { selections.append(next) }
                    value = .array(selections)
                    text = ""
                }
                .disabled(text.isEmpty)
            }
        }
    }
}
