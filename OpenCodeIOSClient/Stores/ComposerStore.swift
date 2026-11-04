import Combine
import Foundation

struct ComposerMentionCandidate: Identifiable, Equatable {
    let kind: OpenCodeComposerMention.Kind
    let name: String
    let displayName: String
    let description: String?

    var id: String { "\(kind.rawValue):\(name)" }

    static func candidates(agents: [OpenCodeAgent], skills: [OpenCodeSkill], query: String) -> [Self] {
        let entries = agents.map { Self(kind: .agent, name: $0.name, displayName: $0.name, description: $0.description) }
            + skills.map { Self(kind: .skill, name: $0.id, displayName: $0.name, description: $0.description) }
        return entries.enumerated().compactMap { index, entry -> (index: Int, entry: Self, rank: Int)? in
            let names = [entry.name, entry.displayName]
            guard query.isEmpty || names.contains(where: { $0.localizedCaseInsensitiveContains(query) })
                || (entry.description?.localizedCaseInsensitiveContains(query) ?? false) else { return nil }

            let rank: Int
            if query.isEmpty || names.contains(where: { $0.localizedCaseInsensitiveCompare(query) == .orderedSame }) {
                rank = 0
            } else if names.contains(where: { $0.range(of: query, options: [.caseInsensitive, .anchored], locale: .current) != nil }) {
                rank = 1
            } else {
                rank = 2
            }
            return (index, entry, rank)
        }.sorted {
            if $0.rank != $1.rank { return $0.rank < $1.rank }
            let order = $0.entry.displayName.localizedCaseInsensitiveCompare($1.entry.displayName)
            return order == .orderedSame ? $0.index < $1.index : order == .orderedAscending
        }
        .map(\.entry)
    }
}

@MainActor
final class ComposerStore: ObservableObject {
    @Published var draftMessage: String
    @Published var draftAgentMentions: [OpenCodeAgentMention]
    @Published var draftAttachments: [OpenCodeComposerAttachment]
    @Published var draftsByChatKey: [String: OpenCodeMessageDraft]
    @Published var resetToken: UUID {
        didSet { streamingDeliveryOverride = nil }
    }
    @Published private(set) var streamingDeliveryOverride: OpenCodePromptDelivery?
    var isStreamingFocused: Bool

    init(
        draftMessage: String = "",
        draftAgentMentions: [OpenCodeAgentMention] = [],
        draftAttachments: [OpenCodeComposerAttachment] = [],
        draftsByChatKey: [String: OpenCodeMessageDraft] = [:],
        resetToken: UUID = UUID(),
        isStreamingFocused: Bool = false
    ) {
        self.draftMessage = draftMessage
        self.draftAgentMentions = draftAgentMentions
        self.draftAttachments = draftAttachments
        self.draftsByChatKey = draftsByChatKey
        self.resetToken = resetToken
        self.isStreamingFocused = isStreamingFocused
    }

    func addAttachments(_ attachments: [OpenCodeComposerAttachment]) {
        guard !attachments.isEmpty else { return }

        var existingIDs = Set(draftAttachments.map(\.id))
        let newItems = attachments.filter { attachment in
            guard !existingIDs.contains(attachment.id) else { return false }
            existingIDs.insert(attachment.id)
            return true
        }
        guard !newItems.isEmpty else { return }

        draftAttachments.append(contentsOf: newItems)
    }

    /// Appends without shifting existing mention ranges or replacing attachments.
    func textAppendingDesktopFollowup() -> String {
        let followup = String(localized: "I’ve finished the desktop task. Please continue.")
        if draftMessage.contains(followup) { return draftMessage }
        if draftMessage.isEmpty { return followup }
        return draftMessage + "\n\n" + followup
    }

    func selectStreamingDelivery(_ delivery: OpenCodePromptDelivery) {
        streamingDeliveryOverride = delivery
    }

    func streamingDelivery(default defaultDelivery: OpenCodePromptDelivery) -> OpenCodePromptDelivery {
        streamingDeliveryOverride ?? defaultDelivery
    }

    func removeAttachment(id: String) {
        draftAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        draftAttachments.removeAll()
    }

    func resetActiveDraft(text: String = "", agentMentions: [OpenCodeAgentMention] = [], attachments: [OpenCodeComposerAttachment] = []) {
        draftMessage = text
        draftAgentMentions = agentMentions
        draftAttachments = attachments
        resetToken = UUID()
    }

    func draft(forKey key: String) -> OpenCodeMessageDraft? {
        draftsByChatKey[key]
    }

    func hasNonEmptyDraft(forKey key: String) -> Bool {
        draftsByChatKey[key]?.isEmpty == false
    }

    func restoreDraft(forKey key: String) {
        let draft = draftsByChatKey[key]
        resetActiveDraft(text: draft?.text ?? "", agentMentions: draft?.agentMentions ?? [])
    }

    func restoreDraftIfActiveIsEmpty(forKey key: String) -> Bool {
        guard draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let draft = draftsByChatKey[key], !draft.isEmpty else { return false }

        resetActiveDraft(text: draft.text, agentMentions: draft.agentMentions)
        return true
    }

    @discardableResult
    func saveDraft(
        _ text: String,
        agentMentions: [OpenCodeAgentMention] = [],
        forKey key: String,
        removesEmpty: Bool = true,
        updateActiveDraft: Bool = true
    ) -> Bool {
        if updateActiveDraft {
            if draftMessage != text {
                draftMessage = text
            }
            if draftAgentMentions != agentMentions {
                draftAgentMentions = agentMentions
            }
        }

        let draft = OpenCodeMessageDraft(text: text, agentMentions: agentMentions)
        if draft.isEmpty {
            guard removesEmpty else { return false }
            guard draftsByChatKey[key] != nil else { return false }
            draftsByChatKey.removeValue(forKey: key)
            return true
        }

        guard draftsByChatKey[key] != draft else { return false }
        draftsByChatKey[key] = draft
        return true
    }

    func clearDraft(forKey key: String, clearActive: Bool) {
        if clearActive {
            streamingDeliveryOverride = nil
            draftMessage = ""
            draftAgentMentions = []
            draftAttachments = []
        }
        draftsByChatKey.removeValue(forKey: key)
    }

    func loadDrafts(storageKey: String, defaults: UserDefaults = .standard) {
        guard let data = defaults.data(forKey: storageKey) else {
            draftsByChatKey = [:]
            return
        }
        draftsByChatKey = (try? JSONDecoder().decode([String: OpenCodeMessageDraft].self, from: data)) ?? [:]
    }

    func saveDrafts(storageKey: String, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(draftsByChatKey) else { return }
        defaults.set(data, forKey: storageKey)
    }
}
