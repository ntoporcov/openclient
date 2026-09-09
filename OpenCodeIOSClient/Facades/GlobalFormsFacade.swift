import Foundation
import Observation

/// Location-owned MCP requests never acquire a chat/session owner. Stores live only for one connection.
@MainActor @Observable
final class GlobalFormsFacade {
    private(set) var connectionID: UUID?
    private(set) var stores: [BackendFormLocation: SessionFormStore] = [:]
    private(set) var defaultLocation: BackendFormLocation?
    private(set) var errors: Set<BackendFormLocation?> = []
    private var aliases: [BackendFormLocation: BackendFormLocation] = [:]
    @ObservationIgnored private var connection: BackendConnection?
    @ObservationIgnored private var tasks: [BackendFormLocation?: Task<Void, Never>] = [:]
    @ObservationIgnored private var requests: [BackendFormLocation?: UUID] = [:]
    @ObservationIgnored private var revision: UInt = 0

    func configure(_ connection: BackendConnection?) {
        tasks.values.forEach { $0.cancel() }
        tasks = [:]
        requests = [:]
        stores.values.forEach { $0.reset() }
        stores = [:]
        aliases = [:]
        errors = []
        defaultLocation = nil
        self.connection = connection
        connectionID = connection?.id
        revision &+= 1
    }

    func canonical(_ location: BackendFormLocation?) -> BackendFormLocation? {
        guard let location else { return defaultLocation }
        return aliases[location] ?? location
    }

    func store(for location: BackendFormLocation?) -> SessionFormStore? {
        guard let location = canonical(location) else { return nil }
        return stores[location]
    }

    func pending(for location: BackendFormLocation?) -> [BackendForm] {
        guard connection?.isClosed == false else { return [] }
        return store(for: location)?.forms.values.sorted { $0.id < $1.id } ?? []
    }

    func request(_ location: BackendFormLocation?) {
        guard connection?.globalForms != nil, connection?.isClosed == false else { return }
        tasks[location]?.cancel()
        tasks[location] = Task { [weak self] in await self?.hydrate(location) }
    }

    func hydrate(_ location: BackendFormLocation?) async {
        guard !Task.isCancelled, let connection, !connection.isClosed, let service = connection.globalForms else { return }
        let token = UUID()
        requests[location] = token
        let revision = revision
        let snapshots = stores.mapValues(\.revision)
        do {
            let inventory = try await service.pendingGlobalForms(scope: location?.scope ?? .init())
            guard !Task.isCancelled, self.connection === connection, !connection.isClosed,
                  requests[location] == token else { return }
            // A global event (even one missing its Location) makes this inventory stale.
            guard self.revision == revision else { request(location); return }
            let canonical = inventory.location
            if let location { aliases[location] = canonical } else { defaultLocation = canonical }
            let store = stores[canonical] ?? SessionFormStore()
            stores[canonical] = store
            guard store.replacePendingForms(inventory.forms, sessionID: "global",
                                            ifUnchangedSince: snapshots[canonical] ?? 0) else {
                request(canonical)
                return
            }
            errors.remove(location)
        } catch {
            guard !Task.isCancelled, self.connection === connection, !connection.isClosed,
                  requests[location] == token else { return }
            errors.insert(location)
        }
    }

    func reconnect() {
        guard connection?.isClosed == false, !requests.isEmpty || !stores.isEmpty else { return }
        revision &+= 1
        let scopes = Set(requests.keys).union(stores.keys.map { Optional($0) }).union([nil])
        requests = [:]
        for location in scopes { request(location) }
    }

    func receive(location: BackendFormLocation?, event: BackendSessionFormsEvent) {
        guard connection?.globalForms != nil, connection?.isClosed == false, event.sessionID == "global" else { return }
        revision &+= 1
        guard let location else {
            // Do not guess the currently visible project. Recover only through canonical inventories.
            reconnect()
            return
        }
        let store = stores[location] ?? SessionFormStore()
        stores[location] = store
        switch event {
        case .created(let form): store.upsert(form)
        case .answered(let key, _), .cancelled(let key): store.settle(key)
        }
    }

    func context(form: BackendForm, location: BackendFormLocation) -> SessionFormContext? {
        guard form.sessionID == "global", let connection, !connection.isClosed,
              let service = connection.globalForms, let store = stores[location], store.forms[form.key] == form else { return nil }
        let reference = BackendFormReference(key: form.key, directory: location.directory, workspaceID: location.workspaceID)
        return .init(connectionID: connection.id, service: service, reference: reference,
                     isCurrent: { [weak self, weak store] in
            self?.connection === connection && !connection.isClosed && self?.stores[location] === store
                && store?.forms[form.key] == form
        })
    }

    func submit(_ form: BackendForm, at location: BackendFormLocation) async {
        guard let context = context(form: form, location: location), let store = stores[location] else { return }
        await SessionFormCoordinator(store: store).submit(context)
    }

    func cancel(_ form: BackendForm, at location: BackendFormLocation) async {
        guard let context = context(form: form, location: location), let store = stores[location] else { return }
        await SessionFormCoordinator(store: store).cancel(context)
    }

    func refresh(_ form: BackendForm, at location: BackendFormLocation) async {
        guard let context = context(form: form, location: location), let store = stores[location] else { return }
        await SessionFormCoordinator(store: store).refresh(context)
    }
}
