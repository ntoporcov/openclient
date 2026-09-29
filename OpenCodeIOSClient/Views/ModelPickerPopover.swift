import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

struct ModelPickerItem: Identifiable, Equatable {
    let providerID: String
    let modelID: String
    let name: String

    var id: String { "\(providerID):\(modelID)" }
    var reference: OpenCodeModelReference { OpenCodeModelReference(providerID: providerID, modelID: modelID) }
}

struct ModelPickerSection: Identifiable, Equatable {
    let id: String
    let name: String
    let models: [ModelPickerItem]
}

struct ModelPickerKeyboardSelection {
    struct Context: Equatable {
        let query: String
        let ids: [String]
    }

    private var context: Context?
    private var selection: String?

    func selectedID(in context: Context) -> String? {
        self.context == context ? selection : context.ids.first
    }

    mutating func synchronize(to context: Context) {
        guard self.context != context else { return }
        self.context = context
        selection = context.ids.first
    }

    mutating func move(by offset: Int, in context: Context) {
        synchronize(to: context)
        guard let selection, let index = context.ids.firstIndex(of: selection) else { return }
        let count = context.ids.count
        self.selection = context.ids[(index + offset % count + count) % count]
    }
}

struct ModelPickerPopover: View {
    let sections: [ModelPickerSection]
    let selectedReference: OpenCodeModelReference?
    let accessibilityIdentifierPrefix: String
    let onSelect: (OpenCodeModelReference) -> Void
    @State private var path: [String] = []

    var body: some View {
        NavigationStack(path: $path) {
            ModelPickerPage(
                sections: sections,
                providerID: nil,
                selectedReference: selectedReference,
                accessibilityIdentifierPrefix: accessibilityIdentifierPrefix,
                onSelectProvider: { providerID in
                    guard path.isEmpty else { return }
                    path.append(providerID)
                },
                onSelect: onSelect
            )
            .navigationTitle("Models")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: String.self) { providerID in
                if let section = sections.first(where: { $0.id == providerID }) {
                    ModelPickerPage(
                        sections: [section],
                        providerID: providerID,
                        selectedReference: selectedReference,
                        accessibilityIdentifierPrefix: accessibilityIdentifierPrefix,
                        onSelectProvider: { _ in },
                        onSelect: onSelect
                    )
                    .navigationTitle(Text(verbatim: section.name))
                    .navigationBarTitleDisplayMode(.inline)
                }
            }
        }
        .frame(width: 320, height: 320)
        .accessibilityIdentifier("\(accessibilityIdentifierPrefix).popover")
    }
}

private struct ModelPickerPage: View {
    @Environment(\.appAccentColor) private var appAccentColor
    let sections: [ModelPickerSection]
    let providerID: String?
    let selectedReference: OpenCodeModelReference?
    let accessibilityIdentifierPrefix: String
    let onSelectProvider: (String) -> Void
    let onSelect: (OpenCodeModelReference) -> Void
    @State private var searchText = ""
    @State private var activationID: UUID?
    @State private var keyboardSelection = ModelPickerKeyboardSelection()
    @FocusState private var fallbackSearchFocused: Bool

    private var showsProviders: Bool { providerID == nil && normalizedSearchText.isEmpty }
    private var isActive: Bool { activationID != nil }

    private var selectionContext: ModelPickerKeyboardSelection.Context {
        .init(query: searchText, ids: showsProviders ? sections.map(\.id) : filteredSections.flatMap { $0.models.map(\.id) })
    }

    private var highlightedID: String? { keyboardSelection.selectedID(in: selectionContext) }

    var body: some View {
        VStack(spacing: 0) {
            searchField
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            ScrollViewReader { proxy in
                List {
                    if showsProviders {
                        Section("Providers") {
                            ForEach(sections) { section in
                                NavigationLink(value: section.id) {
                                    HStack(spacing: 10) {
                                        ProviderIcon(providerID: section.id, size: 22)
                                        VStack(alignment: .leading, spacing: 2) {
                                            Text(verbatim: section.name).foregroundStyle(.primary)
                                            Text(verbatim: section.id).font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .id(section.id)
                                .listRowBackground(highlightedID == section.id ? appAccentColor.opacity(0.12) : nil)
                                .accessibilityAddTraits(highlightedID == section.id ? .isSelected : [])
                                .accessibilityIdentifier("\(accessibilityIdentifierPrefix).provider.\(section.id)")
                            }
                        }
                    } else {
                        ForEach(filteredSections) { section in
                            Section {
                                ForEach(section.models) { model in
                                    ModelPickerOptionButton(
                                        title: model.name,
                                        providerID: providerID == nil ? section.id : nil,
                                        providerName: providerID == nil ? section.name : nil,
                                        identifier: "\(accessibilityIdentifierPrefix).\(model.id)",
                                        isSelected: selectedReference == model.reference
                                    ) {
                                        onSelect(model.reference)
                                    }
                                    .id(model.id)
                                    .listRowBackground(highlightedID == model.id ? appAccentColor.opacity(0.12) : nil)
                                    .accessibilityAddTraits(highlightedID == model.id ? .isSelected : [])
                                }
                            } header: {
                                if providerID != nil {
                                    HStack(spacing: 8) {
                                        ProviderIcon(providerID: section.id, size: 18)
                                        Text(verbatim: section.name)
                                    }
                                }
                            }
                        }
                    }
                    if selectionContext.ids.isEmpty {
                        ContentUnavailableView("No Models", systemImage: "magnifyingglass")
                    }
                }
                .listStyle(.insetGrouped)
                .scrollDismissesKeyboard(.never)
                .opencodeSoftScrollEdgeEffect()
                .accessibilityIdentifier(providerID.map {
                    "\(accessibilityIdentifierPrefix).provider.\($0).content"
                } ?? "\(accessibilityIdentifierPrefix).results")
                .onChange(of: selectionContext, initial: true) { _, context in
                    keyboardSelection.synchronize(to: context)
                    if let highlightedID { proxy.scrollTo(highlightedID) }
                }
                .onChange(of: highlightedID) { _, id in
                    if let id { proxy.scrollTo(id) }
                }
            }
        }
        .onAppear {
            activationID = UUID()
            fallbackSearchFocused = true
        }
        .onDisappear {
            activationID = nil
            fallbackSearchFocused = false
        }
    }

    @ViewBuilder
    private var searchField: some View {
        #if canImport(UIKit)
        ModelPickerSearchField(
            text: $searchText,
            isActive: isActive,
            accessibilityIdentifier: "\(accessibilityIdentifierPrefix).search",
            onMove: { offset in
                guard isActive else { return }
                keyboardSelection.move(by: offset, in: selectionContext)
            },
            onSubmit: activateHighlightedRow
        )
        // NavigationStack may retain a hidden page without updating its UIKit view.
        // A fresh field on appearance gives that page one new focus request on Back.
        .id(activationID)
        .fixedSize(horizontal: false, vertical: true)
        #else
        TextField("Search models", text: $searchText)
            .textFieldStyle(.roundedBorder)
            .focused($fallbackSearchFocused)
            .onSubmit(activateHighlightedRow)
            .onMoveCommand { direction in
                if direction == .up { keyboardSelection.move(by: -1, in: selectionContext) }
                if direction == .down { keyboardSelection.move(by: 1, in: selectionContext) }
            }
        #endif
    }

    private func activateHighlightedRow() {
        guard isActive, let highlightedID else { return }
        if showsProviders {
            onSelectProvider(highlightedID)
        } else if let model = filteredSections.lazy.flatMap(\.models).first(where: { $0.id == highlightedID }) {
            onSelect(model.reference)
        }
    }

    private var normalizedSearchText: String {
        searchText.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var filteredSections: [ModelPickerSection] {
        let query = normalizedSearchText
        guard !query.isEmpty else { return sections }
        return sections.compactMap { section in
            let models = section.models.filter {
                $0.name.localizedCaseInsensitiveContains(query)
                    || $0.modelID.localizedCaseInsensitiveContains(query)
            }
            guard !models.isEmpty else { return nil }
            return ModelPickerSection(id: section.id, name: section.name, models: models)
        }
    }
}

private struct ModelPickerOptionButton: View {
    @Environment(\.appAccentColor) private var appAccentColor
    let title: String
    var providerID: String?
    var providerName: String?
    let identifier: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                if let providerID {
                    ProviderIcon(providerID: providerID, size: 20)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: title)
                        .foregroundStyle(.primary)
                    if let providerName {
                        Text(verbatim: providerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Image(systemName: "checkmark")
                    .foregroundStyle(isSelected ? appAccentColor : Color.clear)
            }
            .contentShape(Rectangle())
        }
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(Text(verbatim: title))
    }
}
