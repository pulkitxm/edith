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
        subcommands: [
            CalendarListCommand.self, CalendarOpenCommand.self, CalendarJoinCommand.self,
            CalendarDirectionsCommand.self,
        ],
        defaultSubcommand: CalendarListCommand.self)
}

enum CalendarBridge {
    static func events(
        _ query: CalendarEventQuery = CalendarEventQuery(
            days: CalendarEventQuery.initialDays),
        timeout: TimeInterval = 4
    ) async throws -> [CalendarEventPayload] {
        try await CalendarEventOperationExecution.events(query) { query in
            try AppBridge.requireHelper("reading the calendar")
            guard
                let reply = await AppBridge.awaitReply(
                    IPC.Name.calendarEvents, timeout: timeout,
                    trigger: {
                        AppBridge.post(
                            IPC.Name.requestCalendarEvents,
                            userInfo: [
                                CalendarEventBridge.queryKey: CalendarEventBridge.encode(query)
                            ])
                    })
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
                let text = reply[CalendarEventBridge.payloadKey] as? String ?? "[]"
                return CalendarEventBridge.decode(text)
            }
        }
    }

    static func event(_ query: String, in events: [CalendarEventPayload]) throws
        -> CalendarEventPayload
    {
        if let exact = events.first(where: { $0.id == query }) { return exact }
        let needle = query.lowercased()
        let exactTitles = events.filter { $0.title.lowercased() == needle }
        if exactTitles.count == 1, let event = exactTitles.first { return event }
        let matches = events.filter { $0.title.lowercased().contains(needle) }
        if matches.count == 1, let event = matches.first { return event }
        if matches.count > 1 || exactTitles.count > 1 {
            let found = exactTitles.isEmpty ? matches : exactTitles
            throw CLIFailure.notFound(
                "\(query) matches \(found.count) events",
                hint: found.prefix(5).map { "\($0.id): \($0.title)" }.joined(separator: ", "))
        }
        throw CLIFailure.notFound(
            "no event matching \(query)", hint: "run `ed calendar ls --json` to see event IDs")
    }
}

struct CalendarListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Upcoming events.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Read from today through this many days, up to 120.")
    var days: Int = 7

    func run() async throws {
        try await execute {
            let days = try CalendarCLI.days(self.days)
            let events = try await CalendarBridge.events(CalendarEventQuery(days: days))
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

struct CalendarOpenCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "open", abstract: "Open Calendar.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let url = await CalendarEventOperationExecution.openCalendar()
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("open"), "application": .string(url.path),
                        "opened": .bool(true),
                    ]))
                return
            }
            CLIOut.out("opened Calendar")
        }
    }
}

struct CalendarJoinCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "join", abstract: "Join an event's meeting.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Event ID or enough of its title to be unambiguous.")
    var event: String

    func run() async throws {
        try await execute {
            let found = try CalendarBridge.event(
                event,
                in: await CalendarBridge.events(
                    CalendarEventQuery(days: CalendarEventQuery.maximumDays)))
            guard let value = found.meetingURL, let url = URL(string: value) else {
                throw CLIFailure.unavailable(
                    "\(found.title) has no meeting link",
                    hint: "run `ed calendar ls --json` and choose an event with meetingURL")
            }
            let opened = await CalendarEventOperationExecution.join(url)
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("join"), "id": .string(found.id),
                        "title": .string(found.title), "url": .string(url.absoluteString),
                        "opened": .bool(opened),
                    ]))
                return
            }
            CLIOut.out("joining \(found.title)")
        }
    }
}

struct CalendarDirectionsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "directions", abstract: "Open directions to an event.", aliases: ["route"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Event ID or enough of its title to be unambiguous.")
    var event: String

    func run() async throws {
        try await execute {
            let found = try CalendarBridge.event(
                event,
                in: await CalendarBridge.events(
                    CalendarEventQuery(days: CalendarEventQuery.maximumDays)))
            guard
                let result = await CalendarEventOperationExecution.directions(
                    found, using: CLIEnvironment.openURL),
                let location = found.location?.trimmingCharacters(in: .whitespacesAndNewlines),
                !location.isEmpty
            else {
                throw CLIFailure.unavailable(
                    "\(found.title) has no location",
                    hint: "run `ed calendar ls --json` and choose an event with location")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "action": .string("directions"), "id": .string(found.id),
                        "title": .string(found.title), "location": .string(location),
                        "url": .string(result.url.absoluteString),
                        "opened": .bool(result.opened),
                    ]))
                return
            }
            CLIOut.out("opening directions to \(TextTable.oneLine(location))")
        }
    }
}

enum CalendarCLI {
    static func days(_ days: Int) throws -> Int {
        let days = try ArgumentChecks.nonNegative(days, "--days")
        guard days <= CalendarEventQuery.maximumDays else {
            throw CLIFailure.usage(
                "--days must be between 0 and \(CalendarEventQuery.maximumDays)")
        }
        return days
    }
}
