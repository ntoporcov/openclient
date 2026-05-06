import Combine
import Foundation

@MainActor
final class ComposerStore: ObservableObject {
    @Published var draftMessage: String
    @Published var draftAttachments: [OpenCodeComposerAttachment]
    @Published var draftsByChatKey: [String: OpenCodeMessageDraft]
    @Published var resetToken: UUID
    var isStreamingFocused: Bool

    init(
        draftMessage: String = "",
        draftAttachments: [OpenCodeComposerAttachment] = [],
        draftsByChatKey: [String: OpenCodeMessageDraft] = [:],
        resetToken: UUID = UUID(),
        isStreamingFocused: Bool = false
    ) {
        self.draftMessage = draftMessage
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

    func removeAttachment(id: String) {
        draftAttachments.removeAll { $0.id == id }
    }

    func clearAttachments() {
        draftAttachments.removeAll()
    }

    func resetActiveDraft(text: String = "", attachments: [OpenCodeComposerAttachment] = []) {
        draftMessage = text
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
        resetActiveDraft(text: draftsByChatKey[key]?.text ?? "")
    }

    func restoreDraftIfActiveIsEmpty(forKey key: String) -> Bool {
        guard draftMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard let draft = draftsByChatKey[key], !draft.isEmpty else { return false }

        resetActiveDraft(text: draft.text)
        return true
    }

    func saveDraft(
        _ text: String,
        forKey key: String,
        removesEmpty: Bool = true,
        updateActiveDraft: Bool = true
    ) {
        if updateActiveDraft {
            draftMessage = text
        }

        let draft = OpenCodeMessageDraft(text: text)
        if draft.isEmpty {
            guard removesEmpty else { return }
            draftsByChatKey.removeValue(forKey: key)
        } else {
            draftsByChatKey[key] = draft
        }
    }

    func clearDraft(forKey key: String, clearActive: Bool) {
        if clearActive {
            draftMessage = ""
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
