import SwiftUI

struct DesktopClipboardButton: View {
    @ObservedObject var history: DesktopClipboardHistory
    var copy: (String) -> Void = OpenCodeClipboard.copy
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPresented = false
    @State private var bounce = 0

    var body: some View {
        if !history.items.isEmpty {
            Button { isPresented = true } label: {
                Image(systemName: "list.clipboard")
                    .symbolEffect(.bounce, options: .nonRepeating,
                                  value: bounce)
            }
            .accessibilityLabel("Computer clipboard")
            .accessibilityValue(Text(history.items.count, format: .number))
            .accessibilityIdentifier("remote-desktop.clipboard")
            .onAppear {
                if let capturedAt = history.items.first?.capturedAt,
                   capturedAt.timeIntervalSinceNow > -2, !reduceMotion { bounce += 1 }
            }
            .onChange(of: history.items.first?.id) { _, _ in
                if !reduceMotion { bounce += 1 }
            }
            .popover(isPresented: $isPresented) {
                DesktopClipboardPopover(history: history, copy: copy)
                    .presentationCompactAdaptation(.popover)
                    .tint(nil)
                    .foregroundStyle(.primary)
                    .buttonStyle(.automatic)
            }
        }
    }
}

private struct DesktopClipboardPopover: View {
    @ObservedObject var history: DesktopClipboardHistory
    let copy: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var copiedID: UUID?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(history.items) { item in
                        Button {
                            copy(item.text)
                            copiedID = item.id
                        } label: {
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(verbatim: item.text)
                                        .lineLimit(4)
                                        .foregroundStyle(.primary)
                                    Text(item.capturedAt, style: .time)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer(minLength: 0)
                                Image(systemName: copiedID == item.id ? "checkmark" : "doc.on.doc")
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityHint("Copy this item to your clipboard")
                        .accessibilityIdentifier("remote-desktop.clipboard.item")
                    }
                } header: {
                    Text("Tap an item to copy it to your clipboard.")
                }
            }
            .navigationTitle("Computer clipboard")
            .opencodeInlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .accessibilityIdentifier("remote-desktop.clipboard.done")
                }
                ToolbarItem(placement: .opencodeTrailing) {
                    Button("Clear", role: .destructive) { history.clear() }
                }
            }
        }
        .frame(minWidth: 280, idealWidth: 340, minHeight: 220, idealHeight: 360)
    }
}

#if DEBUG
struct DesktopClipboardFixture: View {
    @StateObject private var history = DesktopClipboardHistory()
    @State private var showingDesktop = true
    @State private var copied = "No copy yet"

    var body: some View {
        VStack {
            if !showingDesktop {
                DesktopClipboardButton(history: history, copy: { copied = $0 })
                Text(verbatim: copied).accessibilityIdentifier("clipboard.fixture.copied")
            }
        }
        .onAppear { history.activate(targetID: "fixture") }
        .fullScreenCover(isPresented: $showingDesktop) {
            NavigationStack {
                VStack {
                    Button {
                        history.capture("Captured computer text", targetID: "fixture")
                    } label: { Text(verbatim: "Capture fixture") }
                    .accessibilityIdentifier("clipboard.fixture.capture")
                    Text(verbatim: copied).accessibilityIdentifier("clipboard.fixture.copied")
                }
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button { showingDesktop = false } label: { Text(verbatim: "Close fixture") }
                            .accessibilityIdentifier("clipboard.fixture.close")
                    }
                    ToolbarItem(placement: .opencodeTrailing) {
                        DesktopClipboardButton(history: history, copy: { copied = $0 })
                    }
                }
            }
        }
    }
}
#endif
