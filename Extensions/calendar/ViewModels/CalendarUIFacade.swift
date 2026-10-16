import EdithExtensionSupport
import Foundation
import Observation

@MainActor
@Observable
final class CalendarUIFacade {
    private(set) var events: [CalendarEventPayload] = []
    private(set) var groupedDays: [(day: Date, events: [CalendarEventPayload])] = []
    private(set) var authorized = false
    private(set) var blurEvents = true
    private(set) var days = CalendarEventQuery.initialDays
    private(set) var error: String?
    private(set) var loaded = false
    private let invoke: (String, Data) async throws -> Data
    private let invalidate: () -> Void
    private let navigation: CalendarNavigationRequest?
    private var stopped = false
    private let commandTasks = CalendarUITaskOwner()
    private var generation: UInt64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var actions: [UUID: Task<Void, Never>] = [:]

    convenience init(client: ExtensionEngineClient, navigation: CalendarNavigationRequest? = nil) {
        self.init(
            invoke: { try await client.invoke($0, payload: $1) }, invalidate: client.invalidate,
            navigation: navigation)
    }

    init(
        invoke: @escaping (String, Data) async throws -> Data,
        invalidate: @escaping () -> Void = {}, navigation: CalendarNavigationRequest? = nil
    ) {
        self.invoke = invoke
        self.invalidate = invalidate
        self.navigation = navigation
    }

    func observe() async {
        _ = try? await commandTasks.perform { [self] in await observeWork() }
    }

    private func observeWork() async {
        await read("calendar.ui.metadata")
        await refreshAndWait()
        while !stopped && !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await read("calendar.ui.metadata")
        }
    }

    func refresh() {
        guard !stopped else { return }
        refreshTask?.cancel()
        refreshTask = commandTasks.launch { [weak self] in await self?.refreshAndWait() }
    }

    func refreshAndWait() async {
        await read("calendar.ui.list")
    }

    func loadMore() {
        guard !stopped, days < CalendarEventQuery.maximumDays else { return }
        refreshTask?.cancel()
        refreshTask = commandTasks.launch { [weak self] in await self?.read("calendar.ui.loadMore")
        }
    }

    func perform(_ action: CalendarUIAction, eventID: String? = nil) {
        guard !stopped, actions.count < 8 else { return }
        let id = UUID()
        actions[id] = Task { [weak self] in
            await self?.performAndWait(action, eventID: eventID)
            self?.actions.removeValue(forKey: id)
        }
    }

    func performAndWait(_ action: CalendarUIAction, eventID: String? = nil) async {
        let request = CalendarUIActionRequest(action: action, eventID: eventID)
        do {
            try request.validate()
            await read("calendar.ui.action", payload: try JSONEncoder().encode(request))
        } catch { self.error = error.localizedDescription }
    }

    func openPage() {
        guard !stopped, actions.count < 8 else { return }
        let id = UUID()
        actions[id] = Task { [weak self] in
            guard let self else { return }
            defer { actions.removeValue(forKey: id) }
            await openPageAndWait()
        }
    }

    func openPageAndWait() async {
        _ = try? await commandTasks.perform { [self] in await openPageWork() }
    }

    private func openPageWork() async {
        guard !stopped, !Task.isCancelled else { return }
        do {
            guard let navigation else { throw ExtensionPeerError.unavailable }
            try navigation.validate()
            _ = try await invoke("calendar.ui.navigate", JSONEncoder().encode(navigation))
            try Task.checkCancellation()
        } catch {
            if !stopped, !Task.isCancelled { self.error = error.localizedDescription }
        }
    }

    func suspend() {
        generation &+= 1
        refreshTask?.cancel()
        for task in actions.values { task.cancel() }
        commandTasks.cancelPending()
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        suspend()
        commandTasks.cancel()
        invalidate()
    }

    func stopAndWait() async {
        stop()
        await commandTasks.drain()
        while let task = actions.values.first { await task.value }
    }

    func shutdown() {
        stop()
        events = []
        groupedDays = []
        authorized = false
        blurEvents = true
    }

    private func read(_ operation: String, payload: Data = Data("{}".utf8)) async {
        _ = try? await commandTasks.perform { [self] in await readWork(operation, payload: payload)
        }
    }

    private func readWork(_ operation: String, payload: Data) async {
        guard !stopped, !Task.isCancelled else { return }
        generation &+= 1
        let request = generation
        do {
            let data = try await invoke(operation, payload)
            try Task.checkCancellation()
            let snapshot = try JSONDecoder().decode(CalendarUISnapshot.self, from: data)
            guard !stopped, request == generation else { return }
            guard (0...CalendarEventQuery.maximumDays).contains(snapshot.days),
                snapshot.events.count <= 10000,
                Set(snapshot.events.map(\.id)).count == snapshot.events.count,
                snapshot.events.allSatisfy({
                    !$0.id.isEmpty && $0.start.timeIntervalSince1970.isFinite
                        && $0.end.timeIntervalSince1970.isFinite
                })
            else { throw ExtensionPeerError.invalidRequest }
            blurEvents = snapshot.blurEvents
            authorized = snapshot.authorized
            days = snapshot.days
            events = CalendarDayEvents.sorted(snapshot.events)
            let groups = Dictionary(grouping: events) { Calendar.current.startOfDay(for: $0.start) }
            groupedDays = groups.keys.sorted().map { (day: $0, events: groups[$0] ?? []) }
            if operation != "calendar.ui.metadata" || loaded || !events.isEmpty
                || !snapshot.authorized
            {
                error = nil
                loaded = true
            }
        } catch {
            guard !stopped, request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}

@MainActor
final class CalendarUITaskOwner {
    private struct Entry {
        let task: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }

    private var entries: [UUID: Entry] = [:]
    private(set) var closed = false

    func launch(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !closed, entries.count < 256 else { return nil }
        let id = UUID()
        let task = Task {
            defer { entries[id] = nil }
            await work()
        }
        entries[id] = Entry(task: task, cancel: { task.cancel() })
        return task
    }

    func perform<Value: Sendable>(
        _ work: @escaping @MainActor () async throws -> Value
    ) async throws -> Value {
        guard !closed, entries.count < 256 else { throw CancellationError() }
        let id = UUID()
        let task = Task { try await work() }
        let joined = Task {
            _ = await task.result
            entries[id] = nil
        }
        entries[id] = Entry(task: joined, cancel: { task.cancel() })
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancelPending() {
        for entry in entries.values { entry.cancel() }
    }

    func cancel() {
        closed = true
        cancelPending()
    }

    func drain() async {
        cancel()
        while let entry = entries.values.first { await entry.task.value }
    }
}
