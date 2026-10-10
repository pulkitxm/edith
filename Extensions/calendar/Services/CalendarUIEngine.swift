import AppKit
import EdithExtensionSupport
import EventKit
import Foundation

struct CalendarUISnapshot: Codable, Equatable, Sendable {
    let authorized: Bool
    let blurEvents: Bool
    let days: Int
    let events: [CalendarEventPayload]
}

enum CalendarUIAction: String, Codable, Sendable {
    case permission
    case open
    case join
    case directions
}

struct CalendarUIActionRequest: Codable, Sendable {
    let action: CalendarUIAction
    let eventID: String?

    func validate() throws {
        if action == .join || action == .directions {
            guard let eventID, !eventID.isEmpty, eventID.utf8.count <= 2048,
                !eventID.utf8.contains(0)
            else { throw ExtensionPeerError.invalidRequest }
        } else if eventID != nil {
            throw ExtensionPeerError.invalidRequest
        }
    }
}

@MainActor
final class CalendarUIEngine {
    private let store: CalendarStore
    private let presentation: CalendarPresentationState
    private let authorized: () -> Bool
    private let open: (URL) -> Bool
    private let grant: () async throws -> Void
    private var stopped = false
    private var permissionTask: Task<Void, Error>?
    private var permissionID: UUID?

    init(
        store: CalendarStore, presentation: CalendarPresentationState,
        authorized: (() -> Bool)? = nil,
        open: @escaping (URL) -> Bool = { NSWorkspace.shared.open($0) },
        grant: @escaping () async throws -> Void = {
            _ = try await EKEventStore().requestFullAccessToEvents()
        }
    ) {
        self.store = store
        self.presentation = presentation
        self.authorized = authorized ?? { store.authStatus == .fullAccess }
        self.open = open
        self.grant = grant
    }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        guard !stopped else { throw ExtensionPeerError.unavailable }
        switch operation {
        case "calendar.ui.metadata", "calendar.ui.list", "calendar.ui.loadMore":
            try validateObject(payload, keys: [])
            presentation.refresh()
            store.refreshAuthStatus()
            if authorized() {
                if operation == "calendar.ui.list" {
                    _ = await store.refreshAndWait()
                } else if operation == "calendar.ui.loadMore" {
                    await store.loadMoreAndWait()
                }
            }
        case "calendar.ui.action":
            try validateObject(payload, keys: ["action", "eventID"])
            let request = try JSONDecoder().decode(CalendarUIActionRequest.self, from: payload)
            try request.validate()
            store.refreshAuthStatus()
            try Task.checkCancellation()
            switch request.action {
            case .permission:
                try await requestPermission()
                try Task.checkCancellation()
                guard !stopped else { throw ExtensionPeerError.unavailable }
                store.refreshAuthStatus()
                if authorized() { _ = await store.refreshAndWait() }
            case .open:
                guard open(CalendarEventActions.calendarApplicationURL) else {
                    throw ExtensionPeerError.rejected("Calendar could not open.")
                }
            case .join, .directions:
                guard authorized(),
                    let event = store.events.first(where: { $0.id == request.eventID })
                else { throw ExtensionPeerError.invalidRequest }
                let url =
                    request.action == .join
                    ? MeetingLink.url(for: event) : CalendarEventActions.locationURL(for: event)
                guard let url, url.scheme == "https" || url.scheme == "http",
                    url.host != nil, open(url)
                else { throw ExtensionPeerError.rejected("The event action could not open.") }
            }
        default:
            throw ExtensionPeerError.invalidRequest
        }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        presentation.refresh()
        return try JSONEncoder().encode(snapshot())
    }

    func snapshot() -> CalendarUISnapshot {
        let allowed = !stopped && authorized()
        let blur = presentation.blurEvents
        return CalendarUISnapshot(
            authorized: allowed, blurEvents: blur, days: store.pagination.days,
            events: allowed
                ? CalendarDayEvents.sorted(CalendarDayEvents.deduplicated(store.events)).map {
                    blur ? privateEvent($0) : $0
                } : [])
    }

    func shutdown() {
        stopped = true
        permissionTask?.cancel()
    }

    func stopAndWait() async {
        shutdown()
        if let permissionTask { _ = await permissionTask.result }
    }

    private func requestPermission() async throws {
        if let permissionTask {
            try await permissionTask.value
            return
        }
        let id = UUID()
        permissionID = id
        let grant = grant
        let task = Task { try await grant() }
        permissionTask = task
        defer {
            if permissionID == id {
                permissionTask = nil
                permissionID = nil
            }
        }
        try await task.value
    }

    private func validateObject(_ payload: Data, keys: Set<String>) throws {
        guard payload.count <= 8192,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
            Set(object.keys).isSubset(of: keys)
        else { throw ExtensionPeerError.invalidRequest }
    }

    private func privateEvent(_ event: CalendarEventPayload) -> CalendarEventPayload {
        var hidden = event
        hidden.title = "Meeting"
        hidden.calendar = "Calendar"
        hidden.location = event.location == nil ? nil : "Private location"
        hidden.latitude = nil
        hidden.longitude = nil
        if let url = MeetingLink.url(for: event) {
            var components = URLComponents()
            components.scheme = url.scheme
            components.host = url.host
            components.path = "/private"
            hidden.meetingURL = components.url?.absoluteString
        } else {
            hidden.meetingURL = nil
        }
        hidden.url = nil
        hidden.notes = event.notes == nil ? nil : "Private notes"
        hidden.organizer = event.organizer.map { privateParticipant($0) }
        hidden.attendees = event.attendees.map { privateParticipant($0) }
        return hidden
    }

    private func privateParticipant(_ participant: CalendarParticipantPayload)
        -> CalendarParticipantPayload
    {
        var hidden = participant
        hidden.name = "Participant"
        hidden.address = nil
        return hidden
    }
}
