import AppKit
import EdithCore
import Foundation

public enum CalendarEventOperation: String, CaseIterable, Sendable {
    case list
    case open
    case join
    case directions

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .list:
            return UserOperationDescriptor(
                id: UserOperationID(rawValue: "calendar.event.list"),
                summary: "Read upcoming events.", cli: ["calendar", "ls"], effect: .read)
        case .open:
            return UserOperationDescriptor(
                id: UserOperationID(rawValue: "calendar.event.open"),
                summary: "Open Calendar.", cli: ["calendar", "open"], effect: .interactive)
        case .join:
            return UserOperationDescriptor(
                id: UserOperationID(rawValue: "calendar.event.join"),
                summary: "Join an event's meeting.", cli: ["calendar", "join"],
                effect: .interactive)
        case .directions:
            return UserOperationDescriptor(
                id: UserOperationID(rawValue: "calendar.event.directions"),
                summary: "Open directions to an event.", cli: ["calendar", "directions"],
                effect: .interactive)
        }
    }
}

public enum CalendarEventOperationExecution {
    public static func events(
        _ query: CalendarEventQuery,
        using read: (CalendarEventQuery) async throws -> [CalendarEventPayload]
    ) async rethrows -> [CalendarEventPayload] {
        let events = try await read(query).filter(query.contains)
        return CalendarDayEvents.sorted(CalendarDayEvents.deduplicated(events))
    }

    @MainActor
    @discardableResult
    public static func openCalendar(
        using open: @MainActor (URL) -> Void = { url in
            let configuration = NSWorkspace.OpenConfiguration()
            configuration.activates = true
            NSWorkspace.shared.openApplication(at: url, configuration: configuration)
        }
    ) -> URL {
        open(CalendarEventActions.calendarApplicationURL)
        return CalendarEventActions.calendarApplicationURL
    }

    @MainActor
    @discardableResult
    public static func join(
        _ url: URL, using open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> Bool {
        open(url)
    }

    @MainActor
    public static func directions(
        _ event: CalendarEventPayload,
        using open: @MainActor (URL) -> Bool = { NSWorkspace.shared.open($0) }
    ) -> (url: URL, opened: Bool)? {
        guard let url = CalendarEventActions.locationURL(for: event) else { return nil }
        return (url, open(url))
    }
}

public enum CalendarEventActions {
    public static let calendarApplicationURL = URL(
        fileURLWithPath: "/System/Applications/Calendar.app", isDirectory: true)

    public static func locationURL(for event: CalendarEventPayload) -> URL? {
        guard let location = event.location?.trimmingCharacters(in: .whitespacesAndNewlines),
            !location.isEmpty
        else { return nil }
        var components = URLComponents()
        components.scheme = "https"
        components.host = "maps.apple.com"
        components.path = "/"
        var items = [URLQueryItem(name: "q", value: location)]
        if let latitude = event.latitude, let longitude = event.longitude {
            items.append(URLQueryItem(name: "ll", value: "\(latitude),\(longitude)"))
        }
        components.queryItems = items
        return components.url
    }

    @MainActor
    public static func openCalendar() {
        CalendarEventOperationExecution.openCalendar()
    }

    @MainActor
    @discardableResult
    public static func join(_ url: URL) -> Bool {
        CalendarEventOperationExecution.join(url)
    }

    @MainActor
    public static func openLocation(_ event: CalendarEventPayload) {
        _ = CalendarEventOperationExecution.directions(event)
    }
}
