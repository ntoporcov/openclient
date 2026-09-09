import Foundation

#if canImport(ActivityKit) && os(iOS) && !targetEnvironment(macCatalyst)
import ActivityKit

struct LiveActivitySnapshotInput {
    var session: OpenCodeSession
    var sessionTitle: String
    var selectedSessionID: String?
    var selectedMessages: [OpenCodeMessageEnvelope]
    var cachedMessages: [OpenCodeMessageEnvelope]
    var sessionStatus: String?
    var sessionPreviewText: String?
    var permissions: [OpenCodePermission]
    var questions: [OpenCodeQuestionRequest]
    var profile: OpenCodeProfileIdentity = .legacy
    var forms: [BackendForm] = []
}

enum LiveActivitySnapshotBuilder {
    static let staleAfter: TimeInterval = 45
    static let gracePeriod: TimeInterval = 180

    static func sessionTitle(_ title: String) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? String(localized: "Session") : trimmed
    }

    static func state(for input: LiveActivitySnapshotInput, now: Date = .now) -> OpenCodeChatActivityAttributes.ContentState {
        let pendingPermission = input.permissions.first { $0.sessionID == input.session.id }
        let pendingQuestion = input.profile == .legacy ? input.questions.first { $0.sessionID == input.session.id } : nil
        let pendingForm = input.profile == .v2 ? input.forms.first { $0.sessionID == input.session.id } : nil
        let transcriptLines = transcriptLines(for: input)
        let latestSnippet = latestSnippet(for: input, transcriptLines: transcriptLines)
        let status = statusText(sessionStatus: input.sessionStatus, hasPendingInteraction: pendingPermission != nil || pendingQuestion != nil || pendingForm != nil)

        if let pendingPermission {
            return OpenCodeChatActivityAttributes.ContentState(
                status: status,
                latestSnippet: latestSnippet,
                transcriptLines: transcriptLines,
                updatedAt: now,
                pendingInteractionKind: "permission",
                interactionID: pendingPermission.id,
                interactionTitle: pendingPermission.title,
                interactionSummary: pendingPermission.summary,
                questionOptionLabels: [],
                canReplyToQuestionInline: false
            )
        }

        if let pendingForm {
            return OpenCodeChatActivityAttributes.ContentState(
                status: status, latestSnippet: latestSnippet, transcriptLines: transcriptLines,
                updatedAt: now, pendingInteractionKind: "form", interactionID: pendingForm.id,
                interactionTitle: pendingForm.title, interactionSummary: pendingForm.title,
                questionOptionLabels: [], canReplyToQuestionInline: false
            )
        }

        if let pendingQuestion,
           let firstQuestion = pendingQuestion.questions.first {
            let optionLabels = Array(firstQuestion.options.map(\.label).prefix(3))
            let canReplyInline = pendingQuestion.questions.count == 1 &&
                firstQuestion.multiple == false &&
                optionLabels.isEmpty == false &&
                optionLabels.count == firstQuestion.options.count

            return OpenCodeChatActivityAttributes.ContentState(
                status: status,
                latestSnippet: latestSnippet,
                transcriptLines: transcriptLines,
                updatedAt: now,
                pendingInteractionKind: "question",
                interactionID: pendingQuestion.id,
                interactionTitle: firstQuestion.header,
                interactionSummary: firstQuestion.question,
                questionOptionLabels: optionLabels,
                canReplyToQuestionInline: canReplyInline
            )
        }

        return OpenCodeChatActivityAttributes.ContentState(
            status: status,
            latestSnippet: latestSnippet,
            transcriptLines: transcriptLines,
            updatedAt: now,
            pendingInteractionKind: nil,
            interactionID: nil,
            interactionTitle: nil,
            interactionSummary: nil,
            questionOptionLabels: [],
            canReplyToQuestionInline: false
        )
    }

    static func transcriptLines(for input: LiveActivitySnapshotInput) -> [OpenCodeChatActivityLine] {
        let sourceMessages = input.selectedSessionID == input.session.id ? input.selectedMessages : input.cachedMessages
        guard let latestAssistant = sourceMessages
            .last(where: { ($0.info.role ?? "").lowercased() == "assistant" }),
            let text = text(for: latestAssistant, limit: 180) else {
            return []
        }

        return [
            OpenCodeChatActivityLine(
                id: latestAssistant.id,
                role: "assistant",
                text: text,
                isStreaming: input.sessionStatus == "busy"
            )
        ]
    }

    static func content(state: OpenCodeChatActivityAttributes.ContentState) -> ActivityContent<OpenCodeChatActivityAttributes.ContentState> {
        ActivityContent(
            state: state,
            staleDate: Date().addingTimeInterval(staleAfter)
        )
    }

    static func statesMatch(
        _ lhs: OpenCodeChatActivityAttributes.ContentState,
        _ rhs: OpenCodeChatActivityAttributes.ContentState
    ) -> Bool {
        lhs.status == rhs.status &&
            lhs.latestSnippet == rhs.latestSnippet &&
            lhs.transcriptLines == rhs.transcriptLines &&
            lhs.pendingInteractionKind == rhs.pendingInteractionKind &&
            lhs.interactionID == rhs.interactionID &&
            lhs.interactionTitle == rhs.interactionTitle &&
            lhs.interactionSummary == rhs.interactionSummary &&
            lhs.questionOptionLabels == rhs.questionOptionLabels &&
            lhs.canReplyToQuestionInline == rhs.canReplyToQuestionInline
    }

    static func shouldScheduleRefresh(pendingRefreshExists: Bool, immediate: Bool, endIfIdle: Bool) -> Bool {
        !pendingRefreshExists && !immediate && !endIfIdle
    }

    private static func latestSnippet(for input: LiveActivitySnapshotInput, transcriptLines: [OpenCodeChatActivityLine]) -> String {
        if let assistant = transcriptLines.last(where: { $0.role == "assistant" }) {
            return assistant.text
        }

        if let latest = transcriptLines.last {
            return latest.text
        }

        if input.selectedSessionID == input.session.id {
            if let assistant = latestMeaningfulSnippet(in: input.selectedMessages, role: "assistant") {
                return assistant
            }
            if let user = latestMeaningfulSnippet(in: input.selectedMessages, role: "user") {
                if input.sessionStatus == "busy" {
                    return String(localized: "Waiting for assistant...")
                }
                return user
            }
        }

        if let assistant = latestMeaningfulSnippet(in: input.cachedMessages, role: "assistant") {
            return assistant
        }
        if let user = latestMeaningfulSnippet(in: input.cachedMessages, role: "user") {
            if input.sessionStatus == "busy" {
                return String(localized: "Waiting for assistant...")
            }
            return user
        }

        return input.sessionPreviewText ?? String(localized: "No messages yet")
    }

    private static func statusText(sessionStatus: String?, hasPendingInteraction: Bool) -> String {
        if hasPendingInteraction {
            return "Action"
        }

        switch sessionStatus {
        case "busy":
            return "Live"
        case "idle":
            return "Ready"
        default:
            return "Live"
        }
    }

    private static func text(for message: OpenCodeMessageEnvelope, limit: Int) -> String? {
        let text = message.parts
            .compactMap(displayText(for:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")

        return opencodePreviewText(text, limit: limit)
    }

    private static func displayText(for part: OpenCodePart) -> String? {
        switch part.type {
        case "text", "reasoning":
            return part.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        case "tool":
            if let title = part.state?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return title
            }
            if let description = part.state?.input?.description?.trimmingCharacters(in: .whitespacesAndNewlines), !description.isEmpty {
                return description
            }
            if let output = part.state?.output?.trimmingCharacters(in: .whitespacesAndNewlines), !output.isEmpty {
                return output
            }
            if let tool = part.tool?.trimmingCharacters(in: .whitespacesAndNewlines), !tool.isEmpty {
                return String(localized: "Running \(tool)")
            }
            return nil
        default:
            if let title = part.state?.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
                return title
            }
            return part.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    private static func latestMeaningfulSnippet(in messages: [OpenCodeMessageEnvelope], role: String) -> String? {
        messages
            .reversed()
            .first(where: { ($0.info.role ?? "").lowercased() == role })?
            .parts
            .compactMap(displayText(for:))
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .pipe { opencodePreviewText($0, limit: 140) }
    }
}

private extension String {
    func pipe<T>(_ transform: (String) -> T) -> T {
        transform(self)
    }
}
#endif
