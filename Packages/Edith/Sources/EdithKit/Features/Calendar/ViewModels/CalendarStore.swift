import AppKit
import EventKit
import Observation

@MainActor
@Observable
public final class CalendarStore: FeatureModule {
    public private(set) var events: [CalendarEventPayload] = []
    public private(set) var authStatus: EKAuthorizationStatus

    private var daysLoaded = 14
    private static let maxDays = 120

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
            guard let self, let fetched = await self.fetchEvents() else { return }
            guard !Task.isCancelled else { return }
            self.events = fetched
        }
    }

    @discardableResult
    public func refreshAndWait() async -> [CalendarEventPayload] {
        fetchTask?.cancel()
        fetchTask = nil
        guard let fetched = await fetchEvents() else { return events }
        events = fetched
        return fetched
    }

    private func fetchEvents() async -> [CalendarEventPayload]? {
        guard authStatus == .fullAccess else { return nil }
        let start = Calendar.current.startOfDay(for: Date())
        guard let end = Calendar.current.date(byAdding: .day, value: daysLoaded, to: start) else {
            return nil
        }
        return await Task.detached(priority: .userInitiated) {
            let store = EKEventStore()
            let predicate = store.predicateForEvents(
                withStart: start, end: end, calendars: store.calendars(for: .event))
            let events = store.events(matching: predicate).map(CalendarEventPayload.init(event:))
            return CalendarDayEvents.sorted(CalendarDayEvents.deduplicated(events))
        }.value
    }

    public func loadMore() {
        guard daysLoaded < Self.maxDays else { return }
        daysLoaded = min(daysLoaded + 14, Self.maxDays)
        refresh()
    }

}
