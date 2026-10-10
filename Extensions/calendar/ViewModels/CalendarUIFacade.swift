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
    private var stopped = false
    private var generation: UInt64 = 0
    @ObservationIgnored private var refreshTask: Task<Void, Never>?
    @ObservationIgnored private var actions: [UUID: Task<Void, Never>] = [:]

    convenience init(client: ExtensionEngineClient) {
        self.init(
            invoke: { try await client.invoke($0, payload: $1) }, invalidate: client.invalidate)
    }

    init(
        invoke: @escaping (String, Data) async throws -> Data,
        invalidate: @escaping () -> Void = {}
    ) {
        self.invoke = invoke
        self.invalidate = invalidate
    }

    deinit {
        refreshTask?.cancel()
        for task in actions.values { task.cancel() }
        let invalidate = invalidate
        Task { @MainActor in invalidate() }
    }

    func observe() async {
        await refreshAndWait()
        while !stopped && !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(1)) } catch { return }
            await read("calendar.ui.metadata")
        }
    }

    func refresh() {
        guard !stopped else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.refreshAndWait() }
    }

    func refreshAndWait() async {
        await read("calendar.ui.list")
    }

    func loadMore() {
        guard !stopped, days < CalendarEventQuery.maximumDays else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in await self?.read("calendar.ui.loadMore") }
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
            do {
                _ = try await invoke("calendar.ui.navigate", Data("{}".utf8))
                try Task.checkCancellation()
            } catch {
                if !stopped, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func suspend() {
        generation &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        for task in actions.values { task.cancel() }
        actions.removeAll()
    }

    func shutdown() {
        guard !stopped else { return }
        stopped = true
        suspend()
        invalidate()
        events = []
        groupedDays = []
        authorized = false
        blurEvents = true
    }

    private func read(_ operation: String, payload: Data = Data("{}".utf8)) async {
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
                snapshot.authorized || snapshot.events.isEmpty,
                snapshot.events.allSatisfy({
                    !$0.id.isEmpty && $0.start.timeIntervalSince1970.isFinite
                        && $0.end.timeIntervalSince1970.isFinite
                })
            else { throw ExtensionPeerError.invalidRequest }
            blurEvents = snapshot.blurEvents
            authorized = snapshot.authorized
            days = snapshot.days
            events = CalendarDayEvents.sorted(CalendarDayEvents.deduplicated(snapshot.events))
            groupedDays = CalendarDayEvents.groupedByDay(events)
            error = nil
            loaded = true
        } catch {
            guard !stopped, request == generation, !Task.isCancelled else { return }
            self.error = error.localizedDescription
        }
    }
}
