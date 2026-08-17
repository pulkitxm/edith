import AppKit
import Foundation

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
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(
            at: calendarApplicationURL,
            configuration: configuration)
    }

    @MainActor
    public static func openLocation(_ event: CalendarEventPayload) {
        guard let url = locationURL(for: event) else { return }
        NSWorkspace.shared.open(url)
    }
}
