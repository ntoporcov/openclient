#if DEBUG
import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

private enum DebugProbeLogFilter: String, CaseIterable, Identifiable {
    case deltaFlush
    case stream
    case drops
    case breadcrumbs
    case all

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .deltaFlush:
            return "Delta"
        case .stream:
            return "Stream"
        case .drops:
            return "Drops"
        case .breadcrumbs:
            return "Crumbs"
        case .all:
            return "All"
        }
    }

    var emptyMessage: String {
        switch self {
        case .deltaFlush:
            return String(localized: "No delta flush lines yet. Start the probe and stream a response.")
        case .stream:
            return String(localized: "No stream event lines match the current filter.")
        case .drops:
            return String(localized: "No drop or error lines match the current filter.")
        case .breadcrumbs:
            return String(localized: "No breadcrumb lines match the current filter.")
        case .all:
            return String(localized: "No log lines match the current filter.")
        }
    }

    func includes(line: String, sectionTitle: String) -> Bool {
        let lowerLine = line.localizedLowercase
        switch self {
        case .deltaFlush:
            return lowerLine.contains("delta flush")
        case .stream:
            return lowerLine.contains("message.part") || lowerLine.contains("message.updated") || lowerLine.contains("session idle") || lowerLine.contains("event ")
        case .drops:
            return lowerLine.contains("drop") || lowerLine.contains("error") || lowerLine.contains("failed")
        case .breadcrumbs:
            return sectionTitle == String(localized: "Chat Breadcrumbs")
        case .all:
            return true
        }
    }
}

struct ChatDebugProbeSheet: View {
    @ObservedObject var chatFacade: ChatFacade
    @Binding var copiedDebugLog: Bool
    @State private var selectedFilter: DebugProbeLogFilter = .deltaFlush
    @State private var filterQuery = ""

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Run a streaming probe on this chat. It will auto-send a test prompt and collect a timestamped log you can copy back.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Button(chatFacade.isRunningDebugProbe ? LocalizedStringResource("Running...") : LocalizedStringResource("Start Probe")) {
                            Task { await chatFacade.startDebugProbe() }
                        }
                        .buttonStyle(.borderedProminent)
                        .modifier(AppAccentActionModifier())
                        .disabled(chatFacade.isRunningDebugProbe)

                        Button(copiedDebugLog ? LocalizedStringResource("Copied") : LocalizedStringResource("Copy Filtered")) {
                            OpenCodeClipboard.copy(filteredDebugText)
                            copiedDebugLog = true
                        }
                        .buttonStyle(.bordered)
                        .disabled(!hasFilteredLines)
                        .accessibilityIdentifier("debugProbe.copy")
                    }

                    Picker("Log Filter", selection: $selectedFilter) {
                        ForEach(DebugProbeLogFilter.allCases) { filter in
                            Text(filter.title).tag(filter)
                        }
                    }
                    .pickerStyle(.segmented)

                    TextField("Filter text", text: $filterQuery)
                        .textFieldStyle(.roundedBorder)
                        .opencodeDisableTextAutocapitalization()
                        .accessibilityIdentifier("debugProbe.filterText")

                    Text(filteredLineSummary)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)

                ScrollView {
                    Text(filteredDebugText)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding()
                        .accessibilityIdentifier("debugProbe.log")
                }
                .background(OpenCodePlatformColor.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .padding(.horizontal)
            }
            .padding(.vertical)
            .navigationTitle("Debug Probe")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .opencodeLeading) {
                    Button("Close") {
                        chatFacade.dismissDebugProbe()
                    }
                }
            }
        }
        .onChange(of: chatFacade.debugProbeLogCount) { _, _ in
            copiedDebugLog = false
        }
        .onChange(of: chatFacade.chatBreadcrumbCount) { _, _ in
            copiedDebugLog = false
        }
        .onChange(of: selectedFilter) { _, _ in
            copiedDebugLog = false
        }
        .onChange(of: filterQuery) { _, _ in
            copiedDebugLog = false
        }
    }

    private var filteredDebugText: String {
        let sections = filteredSections
        guard sections.contains(where: { !$0.lines.isEmpty }) else {
            return selectedFilter.emptyMessage
        }

        return sections.compactMap { section -> String? in
            guard !section.lines.isEmpty else { return nil }
            return ([section.title] + section.lines).joined(separator: "\n")
        }.joined(separator: "\n\n")
    }

    private var hasFilteredLines: Bool {
        filteredSections.contains { !$0.lines.isEmpty }
    }

    private var filteredLineSummary: String {
        let total = filteredSections.reduce(0) { $0 + $1.lines.count }
        let filterTitle = String(localized: selectedFilter.title)
        if filterQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if total == 1 { return String(localized: "Showing 1 line for \(filterTitle).") }
            return String(localized: "Showing \(total) lines for \(filterTitle).")
        }
        if total == 1 { return String(localized: "Showing 1 line for \(filterTitle) matching \"\(filterQuery)\".") }
        return String(localized: "Showing \(total) lines for \(filterTitle) matching \"\(filterQuery)\".")
    }

    private var filteredSections: [(title: String, lines: [String])] {
        rawSections.map { section in
            let lines = section.lines.filter { line in
                guard selectedFilter.includes(line: line, sectionTitle: section.title) else { return false }
                let query = filterQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !query.isEmpty else { return true }
                return line.localizedCaseInsensitiveContains(query) || section.title.localizedCaseInsensitiveContains(query)
            }
            return (section.title, lines)
        }
    }

    private var rawSections: [(title: String, lines: [String])] {
        [
            (String(localized: "Probe Log"), lines(from: chatFacade.copyDebugProbeLog())),
            (String(localized: "Chat Breadcrumbs"), lines(from: chatFacade.copyChatBreadcrumbs())),
        ]
    }

    private func lines(from text: String) -> [String] {
        text.components(separatedBy: .newlines).filter { !$0.isEmpty }
    }
}
#endif
