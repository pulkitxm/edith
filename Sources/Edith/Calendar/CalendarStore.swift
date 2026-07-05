import AppKit
import EventKit

@MainActor
final class CalendarStore: ObservableObject {
    @Published private(set) var events: [EKEvent] = []
    @Published private(set) var authStatus: EKAuthorizationStatus

    private var daysLoaded = 14
    private static let maxDays = 120

    private let store = EKEventStore()
    private var changeObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?

    init() {
        authStatus = EKEventStore.authorizationStatus(for: .event)
        if authStatus == .fullAccess { refresh() }
        changeObserver = NotificationCenter.default.addObserver(
            forName: .EKEventStoreChanged, object: store, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func shutdown() {
        if let changeObserver { NotificationCenter.default.removeObserver(changeObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        changeObserver = nil
        wakeObserver = nil
    }

    func requestAccess() {
        Task { @MainActor in
            _ = try? await store.requestFullAccessToEvents()
            refreshAuthStatus()
        }
        openCalendarSettings()
    }

    func refreshAuthStatus() {
        let status = EKEventStore.authorizationStatus(for: .event)
        guard status != authStatus else { return }
        authStatus = status
        if status == .fullAccess { refresh() }
    }

    func refresh() {
        guard authStatus == .fullAccess else { return }
        let start = Calendar.current.startOfDay(for: Date())
        let end = Calendar.current.date(byAdding: .day, value: daysLoaded, to: start)!
        let predicate = store.predicateForEvents(
            withStart: start, end: end, calendars: store.calendars(for: .event))
        events = CalendarDayEvents.sorted(store.events(matching: predicate))
    }

    func loadMore() {
        guard daysLoaded < Self.maxDays else { return }
        daysLoaded = min(daysLoaded + 14, Self.maxDays)
        refresh()
    }

    func openCalendarSettings() {
        NSWorkspace.shared.open(
            URL(
                string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars")!)
    }
}
