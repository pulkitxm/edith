import AppKit
import EdithExtensionSupport
import EventKit
import Observation

@MainActor
@Observable
public final class CalendarStore: FeatureModule {
    public private(set) var events: [CalendarEventPayload] = []
    public private(set) var groupedDays: [(day: Date, events: [CalendarEventPayload])] = []
    public private(set) var authStatus: EKAuthorizationStatus

    public private(set) var pagination = CalendarEventPagination()

    private var generation: UInt64 = 0
    private var stopped = false
    private static let eventStore = EKEventStore()
    private let snapshotStore: CalendarAgendaSnapshotStore
    private let fetchOverride: (@Sendable (CalendarEventQuery) async -> [CalendarEventPayload]?)?
    @ObservationIgnored private nonisolated(unsafe) var changeObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var wakeObserver: NSObjectProtocol?
    @ObservationIgnored private nonisolated(unsafe) var wakeCenter: NotificationCenter?
    @ObservationIgnored private nonisolated(unsafe) var refreshDebounce: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var fetchTask: Task<Void, Never>?
    @ObservationIgnored private nonisolated(unsafe) var snapshotTask: Task<Void, Never>?

    public convenience init() {
        self.init(startImmediately: true)
    }

    public convenience init(startImmediately: Bool) {
        self.init(snapshotStore: .standard, fetch: nil)
        if startImmediately { start() }
    }

    public init(
        snapshotStore: CalendarAgendaSnapshotStore,
        fetch: (@Sendable (CalendarEventQuery) async -> [CalendarEventPayload]?)?
    ) {
        self.snapshotStore = snapshotStore
        fetchOverride = fetch
        authStatus = EKEventStore.authorizationStatus(for: .event)
    }

    deinit {
        refreshDebounce?.cancel()
        fetchTask?.cancel()
        snapshotTask?.cancel()
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let wakeObserver { wakeCenter?.removeObserver(wakeObserver) }
    }

    public func start() {
        guard changeObserver == nil else { return }
        stopped = false
        authStatus = EKEventStore.authorizationStatus(for: .event)
        if fetchOverride == nil {
            if authStatus == .fullAccess {
                refresh()
            } else {
                fetchTask = Task { [weak self] in await self?.restoreCachedAgenda() }
            }
        }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: Self.eventStore, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        wakeCenter = NSWorkspace.shared.notificationCenter
        wakeObserver = wakeCenter?.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        guard changeObserver != nil else { return }
        refreshDebounce?.cancel()
        refreshDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            guard let self, self.changeObserver != nil else { return }
            self.refresh()
        }
    }

    public func shutdown() {
        stopped = true
        generation &+= 1
        refreshDebounce?.cancel()
        refreshDebounce = nil
        fetchTask?.cancel()
        fetchTask = nil
        snapshotTask?.cancel()
        snapshotTask = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let wakeObserver { wakeCenter?.removeObserver(wakeObserver) }
        changeObserver = nil
        wakeObserver = nil
        wakeCenter = nil
    }

    public func refreshAuthStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status != authStatus else { return }
        authStatus = status
        if status == .fullAccess, changeObserver != nil { refresh() }
    }

    public func restoreCachedAgenda() async {
        guard !stopped, events.isEmpty, let cached = await snapshotStore.load(), !cached.isEmpty,
            !stopped, events.isEmpty, !Task.isCancelled
        else {
            return
        }
        publish(cached, persist: false)
    }

    public func refresh() {
        guard !stopped else { return }
        let request = beginFetch()
        fetchTask = Task { [weak self] in
            await self?.restoreCachedAgenda()
            guard let self, self.authStatus == .fullAccess || self.fetchOverride != nil else {
                return
            }
            guard let fetched = await self.fetchEvents(self.pagination.query()) else { return }
            guard self.owns(request) else { return }
            self.publish(fetched, persist: true)
        }
    }

    @discardableResult
    public func refreshAndWait() async -> [CalendarEventPayload] {
        guard !stopped else { return events }
        let request = beginFetch()
        await restoreCachedAgenda()
        guard authStatus == .fullAccess || fetchOverride != nil else { return events }
        guard let fetched = await fetchEvents(pagination.query()), owns(request) else {
            return events
        }
        publish(fetched, persist: true)
        return fetched
    }

    public func events(_ query: CalendarEventQuery) async -> [CalendarEventPayload] {
        guard !stopped, let fetched = await fetchEvents(query), !stopped, !Task.isCancelled else {
            return []
        }
        return fetched
    }

    private func fetchEvents(_ query: CalendarEventQuery) async -> [CalendarEventPayload]? {
        if let fetchOverride { return await fetchOverride(query) }
        guard authStatus == .fullAccess else { return nil }
        let eventStore = Self.eventStore
        return await CalendarEventOperationExecution.events(query) { query in
            await Task.detached(priority: .userInitiated) {
                let predicate = eventStore.predicateForEvents(
                    withStart: query.start, end: query.end,
                    calendars: eventStore.calendars(for: .event))
                return eventStore.events(matching: predicate).map(CalendarEventPayload.init(event:))
            }.value
        }
    }

    public func loadMore() {
        guard !stopped, pagination.loadMore() else { return }
        appendPage()
    }

    public func loadMoreAndWait() async {
        guard !stopped, pagination.loadMore() else { return }
        await appendPageAndWait()
    }

    private func appendPage() {
        let request = beginFetch()
        let baseline = events
        let query = pagination.query()
        fetchTask = Task { [weak self] in
            guard let self, let fetched = await self.fetchEvents(query) else { return }
            guard self.owns(request) else { return }
            self.publish(self.appended(baseline, fetched), persist: true)
        }
    }

    private func appendPageAndWait() async {
        let request = beginFetch()
        let baseline = events
        guard let fetched = await fetchEvents(pagination.query()), owns(request) else { return }
        publish(appended(baseline, fetched), persist: true)
    }

    private func appended(
        _ baseline: [CalendarEventPayload], _ fetched: [CalendarEventPayload]
    ) -> [CalendarEventPayload] {
        var known = Set<String>()
        for event in baseline {
            known.insert(event.id)
        }
        var next = baseline
        for event in fetched where !known.contains(event.id) {
            next.append(event)
        }
        return next
    }

    private func beginFetch() -> UInt64 {
        fetchTask?.cancel()
        fetchTask = nil
        generation &+= 1
        return generation
    }

    private func owns(_ request: UInt64) -> Bool {
        !stopped && request == generation && !Task.isCancelled
    }

    private func publish(_ next: [CalendarEventPayload], persist: Bool) {
        guard !stopped else { return }
        events = next
        groupedDays = CalendarDayEvents.groupedByDay(next)
        guard persist else { return }
        snapshotTask?.cancel()
        let store = snapshotStore
        snapshotTask = Task {
            await store.save(next)
        }
    }

}
