import AppKit
import EventKit
import Observation

@MainActor
@Observable
public final class CalendarStore: FeatureModule {
    public private(set) var events: [CalendarEventPayload] = []
    public private(set) var authStatus: EKAuthorizationStatus

    public private(set) var pagination = CalendarEventPagination()

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var refreshDebounce: Task<Void, Never>?
    private var fetchTask: Task<Void, Never>?

    public init() {
        authStatus = EKEventStore.authorizationStatus(for: .event)
        if authStatus == .fullAccess { refresh() }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.scheduleRefresh() }
        }
    }

    private func scheduleRefresh() {
        refreshDebounce?.cancel()
        refreshDebounce = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    public func shutdown() {
        refreshDebounce?.cancel()
        refreshDebounce = nil
        fetchTask?.cancel()
        fetchTask = nil
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        changeObserver = nil
        wakeObserver = nil
    }

    public func refreshAuthStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status != authStatus else { return }
        authStatus = status
        if status == .fullAccess { refresh() }
    }

    public func refresh() {
        fetchTask?.cancel()
        guard authStatus == .fullAccess else { return }
        fetchTask = Task { [weak self] in
            guard let self, let fetched = await self.fetchEvents(pagination.query()) else { return }
            guard !Task.isCancelled else { return }
            self.events = fetched
        }
    }

    @discardableResult
    public func refreshAndWait() async -> [CalendarEventPayload] {
        fetchTask?.cancel()
        fetchTask = nil
        guard let fetched = await fetchEvents(pagination.query()) else { return events }
        events = fetched
        return fetched
    }

    public func events(_ query: CalendarEventQuery) async -> [CalendarEventPayload] {
        await fetchEvents(query) ?? []
    }

    private func fetchEvents(_ query: CalendarEventQuery) async -> [CalendarEventPayload]? {
        guard authStatus == .fullAccess else { return nil }
        return await CalendarEventOperationExecution.events(query) { query in
            await Task.detached(priority: .userInitiated) {
                let store = EKEventStore()
                let predicate = store.predicateForEvents(
                    withStart: query.start, end: query.end,
                    calendars: store.calendars(for: .event))
                return store.events(matching: predicate).map(CalendarEventPayload.init(event:))
            }.value
        }
    }

    public func loadMore() {
        guard pagination.loadMore() else { return }
        refresh()
    }

}
