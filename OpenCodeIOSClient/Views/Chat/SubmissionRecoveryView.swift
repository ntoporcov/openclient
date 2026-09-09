import SwiftUI

struct SubmissionRecoveryView: View {
    let input: ChatStore.SubmissionRecovery
    let checkStatus: (String) async -> Void
    var onVisibilityChange: (Bool) -> Void = { _ in }
    @State private var showsDetails = false

    var body: some View {
        TimelineView(SubmissionStatusSchedule(dates: SubmissionTranscriptPresentation.statusUpdates(input: input))) { context in
            SubmissionRecoveryStatus(input: input, now: context.date, showDetails: { showsDetails = true })
                .onChange(of: SubmissionTranscriptPresentation.showsStatus(input: input, now: context.date), initial: true) { _, visible in
                    onVisibilityChange(visible)
                }
        }
        .sheet(isPresented: $showsDetails) {
            SubmissionRecoveryDetails(input: input, checkStatus: checkStatus)
        }
    }
}

struct SubmissionStatusSchedule: TimelineSchedule {
    let dates: [Date]

    func entries(from startDate: Date, mode: TimelineScheduleMode) -> [Date] {
        // Supply an immediate frame without consuming the future reveal deadline as the initial frame.
        [startDate] + dates.filter { $0 > startDate }
    }
}

struct SubmissionRecoveryStatus: View {
    let input: ChatStore.SubmissionRecovery
    let now: Date
    let showDetails: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if SubmissionTranscriptPresentation.showsStatus(input: input, now: now) {
            VStack(alignment: .trailing, spacing: 5) {
                let fraction = SubmissionTranscriptPresentation.statusProgress(input: input, now: now, reduceMotion: reduceMotion)
                Capsule()
                    .fill(.quaternary)
                    .overlay(alignment: .leading) {
                        Capsule().fill(input.phase == .cancelled ? Color.secondary.opacity(0.5) :
                            (input.phase == .uncertain || input.pendingStatusUnknown ? Color.orange.opacity(0.65) : Color.accentColor.opacity(0.65)))
                            .frame(width: 96 * fraction)
                    }
                    .frame(width: 96, height: 2)
                    .accessibilityHidden(true)
                HStack(spacing: 8) {
                    Text(input.recoveryTitle).foregroundStyle(.secondary)
                    Button("Show status", action: showDetails)
                        .accessibilityIdentifier("chat.recovery.show.\(input.id)")
                }
                .font(.caption2)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
            .padding(.horizontal, 16)
            .padding(.bottom, 6)
            .accessibilityElement(children: .contain)
            .accessibilityIdentifier("chat.recovery.\(input.id)")
        }
    }
}

// This projection is presentation-only. Never feed it into sync, caching, or admission checks.
enum SubmissionTranscriptPresentation {
    static func messages(canonical: [OpenCodeMessageEnvelope], recoveries: [ChatStore.SubmissionRecovery]) -> [OpenCodeMessageEnvelope] {
        let inputs = Dictionary(recoveries.map { ($0.id, $0) }, uniquingKeysWith: { _, last in last })
        let canonical = canonical.filter { message in
            guard let input = inputs[message.id] else { return true }
            return input.canBeReplaced(by: message)
        }
        let canonicalIDs = Set(canonical.map(\.id))
        var result = canonical
        for input in inputs.values.sorted(by: { ($0.submittedAt, $0.id) < ($1.submittedAt, $1.id) }) {
            guard !canonicalIDs.contains(input.id) else { continue }
            let preceding = Set(input.precedingMessageIDs)
            let index = result.lastIndex(where: { preceding.contains($0.id) }).map { $0 + 1 } ?? 0
            result.insert(input.message, at: index)
        }
        return result
    }

    static func progress(submittedAt: Date, now: Date) -> Double {
        let elapsed = min(1, max(0, now.timeIntervalSince(submittedAt.addingTimeInterval(1.5)) / 2))
        return 0.08 + 0.86 * (1 - pow(1 - elapsed, 3))
    }

    static func showsStatus(input: ChatStore.SubmissionRecovery, now: Date) -> Bool {
        !(input.phase == .admitted && !input.pendingStatusUnknown)
            && now >= input.submittedAt.addingTimeInterval(1.5)
    }

    static func statusProgress(input: ChatStore.SubmissionRecovery, now: Date, reduceMotion: Bool) -> Double {
        reduceMotion || input.phase != .submitting ? 0.94 : progress(submittedAt: input.submittedAt, now: now)
    }

    static func statusUpdates(input: ChatStore.SubmissionRecovery) -> [Date] {
        guard input.phase != .admitted || input.pendingStatusUnknown else { return [] }
        let revealAt = input.submittedAt.addingTimeInterval(1.5)
        return (0...60).map { revealAt.addingTimeInterval(Double($0) / 30) }
    }
}

private struct SubmissionRecoveryDetails: View {
    let input: ChatStore.SubmissionRecovery
    let checkStatus: (String) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var attachment: OpenCodeComposerAttachment?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(input.recoveryTitle).font(.headline)
                    Text("Checking status does not resend this submission.")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Text(verbatim: input.text).textSelection(.enabled)
                    ForEach(input.agentMentions, id: \.id) { mention in
                        Text(verbatim: "@\(mention.name)").font(.caption)
                    }
                    if !input.attachments.isEmpty {
                        AttachmentStrip(attachments: input.attachments, allowsRemoval: false,
                            onTapAttachment: { attachment = $0 }, onRemoveAttachment: { _ in })
                    }
                    Button("Copy") { OpenCodeClipboard.copy(input.text) }
                    Button("Check status") {
                        checking = true
                        Task { @MainActor in
                            defer { checking = false }
                            await checkStatus(input.id)
                        }
                    }
                    .disabled(checking || input.phase == .submitting)
                    .accessibilityIdentifier("chat.recovery.check.\(input.id)")
                    Text(verbatim: input.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .navigationTitle("Submission details")
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $attachment) { attachment in
                NavigationStack { AttachmentPreviewSheet(attachment: attachment) }
            }
        }
    }
}

private extension ChatStore.SubmissionRecovery {
    var recoveryTitle: LocalizedStringResource {
        switch phase {
        case .submitting: "Sending"
        case .uncertain: "Submission unconfirmed"
        case .admitted: pendingStatusUnknown ? "Submission status unknown" : "Queued"
        case .cancelled: "Submission cancelled"
        }
    }
}
