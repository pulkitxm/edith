import AppKit
import EdithKit
import EventKit

@MainActor
enum CalendarPermission {
    static let model = CalendarPermissionModel()

    nonisolated static var isGranted: Bool {
        EKEventStore.authorizationStatus(for: .event) == .fullAccess
    }

    static func refresh(observer: UUID? = nil) { model.refresh(observer: observer) }
    static func observe(_ id: UUID) { model.observe(id) }
    static func stopObserving(_ id: UUID) { model.stopObserving(id) }
    static func performRequest() { model.request() }
    static func shutdown() { model.shutdown() }
}

@MainActor
final class CalendarPermissionModel {
    private let read: @Sendable () async throws -> Bool
    private let grant: @MainActor (@escaping @Sendable () -> Void) -> Void
    private let publish: @MainActor (Bool) -> Void
    private var observers: Set<UUID> = []
    private var explicitDemand = false
    private var pending = false
    private var generation = 0
    private var stopped = false
    private var workerID: UUID?
    private var grantID: UUID?
    nonisolated(unsafe) private var worker: Task<Void, Never>?

    init(
        read: @escaping @Sendable () async throws -> Bool = {
            let read = Task.detached(priority: .utility) {
                try Task.checkCancellation()
                return CalendarPermission.isGranted
            }
            return try await withTaskCancellationHandler {
                try await read.value
            } onCancel: {
                read.cancel()
            }
        },
        grant: @escaping @MainActor (@escaping @Sendable () -> Void) -> Void = { completion in
            CalendarPermissionGrant().request(completion)
        },
        publish: @escaping @MainActor (Bool) -> Void = { value in
            let defaults = SharedDefaults.store
            if defaults.object(forKey: AppStorageKeys.Permissions.calendarGranted) as? Bool != value
            {
                defaults.set(value, forKey: AppStorageKeys.Permissions.calendarGranted)
                IPC.post(IPC.Name.permissionsRefreshed)
            }
            IPC.post(IPC.Name.requestPermissionsRefresh)
        }
    ) {
        self.read = read
        self.grant = grant
        self.publish = publish
    }

    deinit { worker?.cancel() }

    var isRequestingPermission: Bool { grantID != nil }

    func observe(_ id: UUID) {
        guard !stopped, observers.count < 64 else { return }
        observers.insert(id)
    }

    func stopObserving(_ id: UUID) {
        observers.remove(id)
        guard observers.isEmpty, !explicitDemand else { return }
        generation &+= 1
        pending = false
        worker?.cancel()
    }

    func refresh(observer: UUID? = nil) {
        guard !stopped else { return }
        if let observer {
            guard observers.contains(observer) else { return }
        } else {
            explicitDemand = true
        }
        pending = true
        generation &+= 1
        kick()
    }

    func request() {
        guard !stopped, grantID == nil else { return }
        let id = UUID()
        grantID = id
        grant { [weak self] in
            Task { @MainActor [weak self] in self?.grantFinished(id) }
        }
    }

    private func grantFinished(_ id: UUID) {
        guard grantID == id else { return }
        grantID = nil
        guard !stopped else { return }
        refresh()
    }

    func shutdown() {
        stopped = true
        observers.removeAll()
        explicitDemand = false
        pending = false
        generation &+= 1
        worker?.cancel()
    }

    func waitForRefresh() async {
        while let task = worker { await task.value }
    }

    private func kick() {
        guard !stopped, pending else { return }
        guard worker == nil else { return }
        let id = UUID()
        workerID = id
        let read = read
        worker = Task { [weak self] in
            defer { self?.finished(id) }
            while !Task.isCancelled {
                guard let generation = self?.next() else { return }
                do {
                    let value = try await read()
                    guard !Task.isCancelled else { return }
                    self?.apply(value, generation: generation)
                } catch {
                    guard !Task.isCancelled else { return }
                    self?.completed(generation)
                }
            }
        }
    }

    private func next() -> Int? {
        guard !stopped, pending else { return nil }
        pending = false
        return generation
    }

    private func apply(_ value: Bool, generation: Int) {
        guard !stopped, self.generation == generation,
            explicitDemand || !observers.isEmpty
        else { return }
        publish(value)
        completed(generation)
    }

    private func completed(_ generation: Int) {
        guard self.generation == generation else { return }
        explicitDemand = false
    }

    private func finished(_ id: UUID) {
        guard workerID == id else { return }
        workerID = nil
        worker = nil
        kick()
    }
}

@MainActor
enum MainPermissionOperations {
    static var center: PermissionOperationCenter {
        PermissionOperationCenter(
            environment: PermissionOperationEnvironment(
                defaults: SharedDefaults.store,
                requestPermission: { permission in
                    if permission == .calendar {
                        PermissionPromptTracker.record()
                        CalendarPermission.performRequest()
                        return true
                    }
                    guard let request = permission.grantRequest else { return false }
                    IPC.post(request)
                    return false
                },
                refreshStatus: { CalendarPermission.refresh() },
                openSettings: { NSWorkspace.shared.open($0) }))
    }
}

@MainActor
private final class CalendarPermissionGrant {
    private let store = EKEventStore()

    func request(_ completion: @escaping @Sendable () -> Void) {
        store.requestFullAccessToEvents { [self] _, _ in
            withExtendedLifetime(self) { completion() }
        }
    }
}
