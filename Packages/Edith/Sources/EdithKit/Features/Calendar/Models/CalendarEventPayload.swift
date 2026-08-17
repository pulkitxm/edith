import AppKit
import EventKit
import Foundation

public struct CalendarColorPayload: Codable, Equatable, Sendable {
    public var red: Double
    public var green: Double
    public var blue: Double
    public var alpha: Double

    public init(red: Double, green: Double, blue: Double, alpha: Double) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }
}

public struct CalendarParticipantPayload: Codable, Equatable, Sendable {
    public var name: String?
    public var address: String?
    public var status: String
    public var role: String
    public var isCurrentUser: Bool

    public init(
        name: String?, address: String?, status: String, role: String, isCurrentUser: Bool
    ) {
        self.name = name
        self.address = address
        self.status = status
        self.role = role
        self.isCurrentUser = isCurrentUser
    }
}

public struct CalendarEventPayload: Codable, Equatable, Identifiable, Sendable {
    public var id: String
    public var title: String
    public var calendar: String
    public var calendarColor: CalendarColorPayload?
    public var start: Date
    public var end: Date
    public var isAllDay: Bool
    public var location: String?
    public var latitude: Double?
    public var longitude: Double?
    public var meetingURL: String?
    public var url: String?
    public var notes: String?
    public var organizer: CalendarParticipantPayload?
    public var attendees: [CalendarParticipantPayload]
    public var isRecurring: Bool
    public var status: String
    public var availability: String
    public var timeZone: String?
    public var hasAlarms: Bool

    public init(
        id: String = UUID().uuidString,
        title: String,
        calendar: String = "",
        calendarColor: CalendarColorPayload? = nil,
        start: Date,
        end: Date,
        isAllDay: Bool,
        location: String? = nil,
        latitude: Double? = nil,
        longitude: Double? = nil,
        meetingURL: String? = nil,
        url: String? = nil,
        notes: String? = nil,
        organizer: CalendarParticipantPayload? = nil,
        attendees: [CalendarParticipantPayload] = [],
        isRecurring: Bool = false,
        status: String = "none",
        availability: String = "notSupported",
        timeZone: String? = nil,
        hasAlarms: Bool = false
    ) {
        self.id = id
        self.title = title
        self.calendar = calendar
        self.calendarColor = calendarColor
        self.start = start
        self.end = end
        self.isAllDay = isAllDay
        self.location = location
        self.latitude = latitude
        self.longitude = longitude
        self.meetingURL = meetingURL
        self.url = url
        self.notes = notes
        self.organizer = organizer
        self.attendees = attendees
        self.isRecurring = isRecurring
        self.status = status
        self.availability = availability
        self.timeZone = timeZone
        self.hasAlarms = hasAlarms
    }

    public init(event: EKEvent) {
        let coordinate = event.structuredLocation?.geoLocation?.coordinate
        id = event.eventIdentifier ?? event.calendarItemExternalIdentifier ?? UUID().uuidString
        title = event.title ?? "Untitled"
        calendar = event.calendar?.title ?? ""
        calendarColor = Self.color(event.calendar?.cgColor)
        start = event.startDate
        end = event.endDate
        isAllDay = event.isAllDay
        location = event.location
        latitude = coordinate?.latitude
        longitude = coordinate?.longitude
        meetingURL = MeetingLink.url(for: event)?.absoluteString
        url = event.url?.absoluteString
        notes = event.notes
        organizer = event.organizer.map(Self.participant)
        attendees = event.attendees?.map(Self.participant) ?? []
        isRecurring = event.hasRecurrenceRules
        status = Self.status(event.status)
        availability = Self.availability(event.availability)
        timeZone = event.timeZone?.identifier
        hasAlarms = !(event.alarms?.isEmpty ?? true)
    }

    private static func color(_ cgColor: CGColor?) -> CalendarColorPayload? {
        guard let cgColor, let color = NSColor(cgColor: cgColor)?.usingColorSpace(.deviceRGB)
        else { return nil }
        return CalendarColorPayload(
            red: color.redComponent,
            green: color.greenComponent,
            blue: color.blueComponent,
            alpha: color.alphaComponent)
    }

    private static func participant(_ participant: EKParticipant) -> CalendarParticipantPayload {
        CalendarParticipantPayload(
            name: participant.name,
            address: participant.url.absoluteString,
            status: participantStatus(participant.participantStatus),
            role: participantRole(participant.participantRole),
            isCurrentUser: participant.isCurrentUser)
    }

    private static func participantStatus(_ status: EKParticipantStatus) -> String {
        switch status {
        case .unknown: return "unknown"
        case .pending: return "pending"
        case .accepted: return "accepted"
        case .declined: return "declined"
        case .tentative: return "tentative"
        case .delegated: return "delegated"
        case .completed: return "completed"
        case .inProcess: return "inProcess"
        @unknown default: return "unknown"
        }
    }

    private static func participantRole(_ role: EKParticipantRole) -> String {
        switch role {
        case .unknown: return "unknown"
        case .required: return "required"
        case .optional: return "optional"
        case .chair: return "chair"
        case .nonParticipant: return "nonParticipant"
        @unknown default: return "unknown"
        }
    }

    private static func status(_ status: EKEventStatus) -> String {
        switch status {
        case .none: return "none"
        case .confirmed: return "confirmed"
        case .tentative: return "tentative"
        case .canceled: return "canceled"
        @unknown default: return "none"
        }
    }

    private static func availability(_ availability: EKEventAvailability) -> String {
        switch availability {
        case .notSupported: return "notSupported"
        case .busy: return "busy"
        case .free: return "free"
        case .tentative: return "tentative"
        case .unavailable: return "unavailable"
        @unknown default: return "notSupported"
        }
    }
}

public enum CalendarEventBridge {
    public static let payloadKey = "events"
    public static let statusKey = "status"

    public static func encode(_ payloads: [CalendarEventPayload]) -> String {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(payloads) else { return "[]" }
        return String(decoding: data, as: UTF8.self)
    }

    public static func decode(_ text: String) -> [CalendarEventPayload] {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = text.data(using: .utf8),
            let payloads = try? decoder.decode([CalendarEventPayload].self, from: data)
        else { return [] }
        return payloads
    }
}
