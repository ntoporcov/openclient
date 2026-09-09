import Foundation
import Observation

@MainActor
@Observable
final class SessionFormStore {
    enum Phase: Equatable {
        case ready, submitting, cancelling, checking, uncertain, unavailable
        var isBusy: Bool { self == .submitting || self == .cancelling || self == .checking }
    }

    struct EditingState: Equatable {
        var draft: BackendFormDraft = [:]
        var phase: Phase = .ready
        var errorMessage: String? = nil
        var operationID: UUID? = nil
        var operationConnectionID: UUID? = nil
        var operationReference: BackendFormReference? = nil
    }

    private let canonical: SessionFormStore?
    private var storedForms: [BackendFormKey: BackendForm] = [:]
    private var editedForms: [BackendFormKey: BackendForm] = [:]
    private(set) var forms: [BackendFormKey: BackendForm] {
        get { canonical?.forms ?? storedForms }
        set { storedForms = newValue }
    }
    private(set) var editing: [BackendFormKey: EditingState] = [:]
    private var storedGeneration = UUID()
    private(set) var generation: UUID {
        get { canonical?.generation ?? storedGeneration }
        set { storedGeneration = newValue }
    }
    private(set) var revision: UInt = 0
    @ObservationIgnored private var terminalKeys: Set<BackendFormKey> = []
    @ObservationIgnored var onCanonicalChange: @MainActor () -> Void = {}

    init(canonical: SessionFormStore? = nil) { self.canonical = canonical }

    func reset() {
        onCanonicalChange()
        generation = UUID()
        revision &+= 1
        forms = [:]
        editing = [:]
        editedForms = [:]
        terminalKeys = []
    }

    func upsert(_ form: BackendForm) {
        guard !terminalKeys.contains(form.key) else { return }
        onCanonicalChange()
        revision &+= 1
        if let previous = forms[form.key], previous != form { editing[form.key] = nil }
        forms[form.key] = form
    }

    @discardableResult
    func replacePendingForms(_ pending: [BackendForm], sessionID: String, ifUnchangedSince expected: UInt? = nil) -> Bool {
        guard expected == nil || expected == revision else { return false }
        let scoped = pending.filter { $0.sessionID == sessionID }
        let keys = Set(scoped.map(\.key))
        for key in Array(forms.keys) where key.sessionID == sessionID && !keys.contains(key) {
            settle(key)
        }
        for form in scoped { upsert(form) }
        return true
    }

    /// A terminal event invalidates operations before HTTP completion can update the editor.
    func settle(_ key: BackendFormKey) {
        if let canonical { canonical.settle(key); editing[key] = nil; editedForms[key] = nil; return }
        onCanonicalChange()
        revision &+= 1
        terminalKeys.insert(key)
        forms[key] = nil
        editing[key] = nil
    }

    func removeSession(_ sessionID: String) {
        for key in Array(forms.keys) where key.sessionID == sessionID { settle(key) }
    }

    func state(for key: BackendFormKey) -> EditingState {
        guard let canonical else { return editing[key] ?? .init() }
        var state = canonical.state(for: key)
        let local = editedForms[key] == canonical.forms[key] ? editing[key] : nil
        state.draft = local?.draft ?? [:]
        state.errorMessage = local?.errorMessage
        return state
    }

    func setValue(_ value: OpenCodeJSONValue?, fieldID: String, for key: BackendFormKey) {
        guard let form = forms[key], form.fields.contains(where: { $0.id == fieldID }),
              !state(for: key).phase.isBusy, state(for: key).phase != .unavailable else { return }
        var state = state(for: key)
        state.draft[fieldID] = value ?? .null
        editedForms[key] = form
        if state.phase == .ready { state.errorMessage = nil }
        editing[key] = state
    }

    func begin(_ phase: Phase, reference: BackendFormReference, connectionID: UUID) -> UUID? {
        if let canonical { return canonical.begin(phase, reference: reference, connectionID: connectionID) }
        let key = reference.key
        guard forms[key] != nil else { return nil }
        var state = state(for: key)
        guard !state.phase.isBusy,
              phase == .checking || (state.phase != .uncertain && state.phase != .unavailable) else { return nil }
        let token = UUID()
        state.operationID = token
        state.operationConnectionID = connectionID
        state.operationReference = reference
        state.phase = phase
        state.errorMessage = nil
        editing[key] = state
        return token
    }

    func owns(_ token: UUID, reference: BackendFormReference, connectionID: UUID, generation: UUID) -> Bool {
        if let canonical { return canonical.owns(token, reference: reference, connectionID: connectionID, generation: generation) }
        let key = reference.key
        return self.generation == generation && forms[key] != nil && editing[key]?.operationID == token
            && editing[key]?.operationConnectionID == connectionID && editing[key]?.operationReference == reference
    }

    func finish(_ token: UUID, key: BackendFormKey, phase: Phase, message: String? = nil) {
        if let canonical {
            guard canonical.editing[key]?.operationID == token else { return }
            canonical.finish(token, key: key, phase: phase)
            if let message { showValidationError(message, key: key) }
            return
        }
        guard forms[key] != nil, var state = editing[key], state.operationID == token else { return }
        state.phase = phase
        state.errorMessage = message
        state.operationID = nil
        state.operationConnectionID = nil
        state.operationReference = nil
        editing[key] = state
    }

    func showValidationError(_ message: String, key: BackendFormKey) {
        guard forms[key] != nil, !state(for: key).phase.isBusy else { return }
        var state = state(for: key)
        editedForms[key] = forms[key]
        state.errorMessage = message
        editing[key] = state
    }
}
