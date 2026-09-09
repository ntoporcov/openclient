import Foundation

@MainActor
final class OpenCodeBackendEventSource: BackendEventSource {
    private let client: OpenCodeAPIClient
    private let profile: OpenCodeAPIProfile
    private let manager: OpenCodeEventManager
    private var generation = 0
    private var managerGeneration: UInt?

    // Compatibility sinks keep full OpenCode metadata and the tested v2 projection path.
    // These are not part of BackendEvent or required of another harness.
    var legacyEvent: (@MainActor (OpenCodeManagedEvent) -> Void)?
    var v2Event: (@MainActor (OpenCodeV2ManagedEvent) -> Void)?

    init(client: OpenCodeAPIClient, profile: OpenCodeAPIProfile, manager: OpenCodeEventManager) {
        self.client = client
        self.profile = profile
        self.manager = manager
    }

    func start(receive: @escaping @MainActor (BackendEvent) -> Void) {
        generation &+= 1
        let current = generation
        let status: @Sendable (String) async -> Void = { [weak self] value in
            await MainActor.run {
                guard self?.generation == current else { return }
                receive(.status(value))
            }
        }
        let dropped: @Sendable (String) async -> Void = { [weak self] value in
            await MainActor.run {
                guard self?.generation == current else { return }
                receive(.diagnostic(value))
            }
        }
        if profile == .v2 {
            manager.startV2(client: client, onStatus: status, onDroppedEvent: dropped) { [weak self] event in
                await MainActor.run {
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    if let form = event.globalFormEvent {
                        receive(.globalForm(location: event.location.map {
                            .init(directory: $0.directory, workspaceID: $0.workspaceID)
                        }, event: form))
                        return
                    }
                    if event.sessionID == "global", event.type.hasPrefix("form.") {
                        receive(.diagnostic("drop malformed global form event: \(event.type)"))
                        return
                    }
                    // Do not pretend a v2 event is a canonical legacy mutation. Projection and
                    // revision-guarded reconciliation remain in the existing compatibility sink.
                    self.v2Event?(event)
                    let data = event.data.objectValue ?? [:]
                    if ["permission.asked", "question.asked", "form.created"].contains(event.type), let id = event.sessionID {
                        receive(.actionSignal(.needsAttention(sessionID: id)))
                    }
                    if event.type == "session.created", let id = event.sessionID,
                       let parent = data["parentID"]?.literalStringValue {
                        receive(.actionSignal(.sessionParent(sessionID: id, parentID: parent)))
                    }
                    if event.isExecutionTerminal || ["session.step.ended", "session.step.failed", "session.inbox.delivered", "session.input.promoted"].contains(event.type),
                       let id = event.sessionID {
                        receive(.actionSignal(.execution(sessionID: id)))
                    }
                }
            }
        } else {
            manager.start(client: client, onStatus: status, onDroppedEvent: dropped) { [weak self] event in
                await MainActor.run {
                    guard let self, self.generation == current, !Task.isCancelled else { return }
                    if let legacyEvent = self.legacyEvent { legacyEvent(event) }
                    else { receive(.mutation(directory: event.directory, event: event.typed)) }
                    switch event.typed {
                    case .permissionAsked(let request): receive(.actionSignal(.needsAttention(sessionID: request.sessionID)))
                    case .questionAsked(let request): receive(.actionSignal(.needsAttention(sessionID: request.sessionID)))
                    case .sessionCreated(let session):
                        if let parent = session.parentID { receive(.actionSignal(.sessionParent(sessionID: session.id, parentID: parent))) }
                    case .messageUpdated(let message):
                        if let id = message.sessionID { receive(.actionSignal(.execution(sessionID: id))) }
                    case .sessionIdle(let id), .sessionStatus(let id, _): receive(.actionSignal(.execution(sessionID: id)))
                    default: break
                    }
                }
            }
        }
        managerGeneration = manager.generation
    }

    func stop() {
        generation &+= 1
        if managerGeneration == manager.generation { manager.stop() }
        managerGeneration = nil
    }
}

// Reconstruct reducer metadata from normalized values, never a raw backend payload.
// This bridge can disappear when DirectorySyncFacade accepts typed mutations directly.
enum BackendMutationBridge {
    static func managed(directory: String?, event: OpenCodeTypedEvent) throws -> OpenCodeManagedEvent {
        func convert<T: Encodable, U: Decodable>(_ value: T) throws -> U {
            try JSONDecoder().decode(U.self, from: JSONEncoder().encode(value))
        }
        let type: String
        let properties: OpenCodeEventProperties
        switch event {
        case let .projectUpdated(project):
            type = "project.updated"; properties = try convert(project)
        case let .sessionCreated(session), let .sessionUpdated(session), let .sessionDeleted(session):
            switch event {
            case .sessionCreated: type = "session.created"
            case .sessionDeleted: type = "session.deleted"
            default: type = "session.updated"
            }
            properties = try .init(sessionID: session.id, info: convert(session))
        case let .sessionStatus(id, status):
            type = "session.status"; properties = .init(sessionID: id, status: .init(type: status))
        case let .sessionIdle(id):
            type = "session.idle"; properties = .init(sessionID: id)
        case let .sessionError(id, message):
            type = "session.error"; properties = .init(sessionID: id, message: message)
        case let .messageUpdated(message):
            type = "message.updated"; properties = .init(sessionID: message.sessionID, info: .init(message: message))
        case let .messageRemoved(sessionID, messageID):
            type = "message.removed"; properties = .init(sessionID: sessionID, messageID: messageID)
        case let .messagePartUpdated(part):
            type = "message.part.updated"; properties = .init(sessionID: part.sessionID, part: part, messageID: part.messageID, partID: part.id)
        case let .messagePartRemoved(messageID, partID):
            type = "message.part.removed"; properties = .init(messageID: messageID, partID: partID)
        case let .messagePartDelta(sessionID, messageID, partID, field, delta):
            type = "message.part.delta"; properties = .init(sessionID: sessionID, messageID: messageID, partID: partID, field: field, delta: delta)
        case let .todoUpdated(sessionID, todos):
            type = "todo.updated"; properties = .init(sessionID: sessionID, todos: todos)
        case let .sessionDiff(sessionID, diff):
            type = "session.diff"; properties = .init(sessionID: sessionID, diff: diff)
        case let .permissionAsked(permission):
            type = "permission.asked"; properties = try convert(permission)
        case let .permissionReplied(sessionID, requestID, reply):
            type = "permission.replied"; properties = .init(sessionID: sessionID, requestID: requestID, reply: reply)
        case let .questionAsked(question):
            type = "question.asked"; properties = try convert(question)
        case let .questionReplied(sessionID, requestID):
            type = "question.replied"; properties = .init(sessionID: sessionID, requestID: requestID)
        case let .questionRejected(sessionID, requestID):
            type = "question.rejected"; properties = .init(sessionID: sessionID, requestID: requestID)
        default:
            // Optional OpenCode-only features still use the compatibility event sink.
            throw BackendError.invalidScope
        }
        return .init(directory: directory ?? "global", envelope: .init(type: type, properties: properties), typed: event)
    }
}
