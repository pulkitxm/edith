import ArgumentParser
import EdithKit
import Foundation

struct CalendarCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "calendar",
        abstract: "Your schedule, as the Edith app sees it.",
        discussion: """
            The calendar grant belongs to the Edith app, not to this binary, so events
            are fetched from the running app. If the app is not running, or the Calendar
            extension is off, or macOS has not granted calendar access, this exits 4 and
            says which.
            """,
        subcommands: [CalendarListCommand.self],
        defaultSubcommand: CalendarListCommand.self)
}

struct CalendarListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Upcoming events.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only events starting within this many days.")
    var days: Int = 7

    func run() async throws {
        try await execute {
            let days = try ArgumentChecks.nonNegative(self.days, "--days")
            try AppBridge.requireHelper("reading the calendar")
            guard
                let reply = await AppBridge.awaitReply(
                    IPC.Name.calendarEvents, timeout: 4,
                    trigger: { AppBridge.post(IPC.Name.requestCalendarEvents) })
            else {
                throw AppBridge.silence(
                    "the calendar", extensionKey: AppStorageKeys.Tabs.calendarEnabled,
                    permission: "calendar")
            }
            switch reply[CalendarEventBridge.statusKey] as? String {
            case "extensionOff":
                throw CLIFailure.unavailable(
                    "the Calendar extension is off", hint: "run `ed extensions enable calendar`")
            case "notAuthorized":
                throw CLIFailure.unavailable(
                    "macOS has not granted Edith calendar access",
                    hint: "run `ed permissions request calendar`")
            default:
                break
            }
            let text = reply[CalendarEventBridge.payloadKey] as? String ?? "[]"
            let cutoff = Calendar.current.date(byAdding: .day, value: days, to: Date()) ?? Date()
            let events = CalendarEventBridge.decode(text).filter { $0.start <= cutoff }
            guard !json else {
                CLIOut.json(
                    .array(
                        events.map { event in
                            .object([
                                "id": .string(event.id),
                                "title": .string(event.title),
                                "calendar": .string(event.calendar),
                                "calendarColor": color(event.calendarColor),
                                "start": .date(event.start),
                                "end": .date(event.end),
                                "allDay": .bool(event.isAllDay),
                                "location": .optional(event.location),
                                "latitude": .optional(event.latitude),
                                "longitude": .optional(event.longitude),
                                "meetingURL": .optional(event.meetingURL),
                                "url": .optional(event.url),
                                "notes": .optional(event.notes),
                                "organizer": event.organizer.map(participant) ?? .null,
                                "attendees": .array(event.attendees.map(participant)),
                                "recurring": .bool(event.isRecurring),
                                "status": .string(event.status),
                                "availability": .string(event.availability),
                                "timeZone": .optional(event.timeZone),
                                "hasAlarms": .bool(event.hasAlarms),
                            ])
                        }))
                return
            }
            let formatter = DateFormatter()
            formatter.dateFormat = "EEE d MMM HH:mm"
            let rows = events.map { event in
                [
                    event.isAllDay ? "all day" : formatter.string(from: event.start),
                    event.title, event.calendar, event.meetingURL ?? "",
                ]
            }
            CLIOut.out(
                TextTable.render(headers: ["WHEN", "TITLE", "CALENDAR", "LINK"], rows: rows))
        }
    }

    private func color(_ color: CalendarColorPayload?) -> JSONValue {
        guard let color else { return .null }
        return .object([
            "red": .double(color.red),
            "green": .double(color.green),
            "blue": .double(color.blue),
            "alpha": .double(color.alpha),
        ])
    }

    private func participant(_ participant: CalendarParticipantPayload) -> JSONValue {
        .object([
            "name": .optional(participant.name),
            "address": .optional(participant.address),
            "status": .string(participant.status),
            "role": .string(participant.role),
            "isCurrentUser": .bool(participant.isCurrentUser),
        ])
    }
}
