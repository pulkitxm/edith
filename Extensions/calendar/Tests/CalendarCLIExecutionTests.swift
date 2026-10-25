import EdithExtensionCommands
import EdithExtensionSupport
import Foundation
import Testing

@testable import CalendarExtension

@Suite(.serialized) @MainActor struct CalendarCLIExecutionTests {
    @Test func defaultListAndAliasPreserveJSONFieldsAndQueryBounds() async throws {
        var queries: [CalendarEventQuery] = []
        let events = Self.events()
        let request = try ExtensionCLIRequest(arguments: ["list", "--json", "--days", "7"])
        let reply = try await CalendarCLIExecution.run(request) {
            queries.append($0); return events + [events[0]]
        }
        #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
        #expect(queries.map(\.days) == [7])
        let rows = try #require(
            JSONSerialization.jsonObject(with: Data(reply.stdout.utf8)) as? [[String: Any]])
        #expect(rows.count == 2)
        #expect(rows[0]["id"] as? String == "meeting-one")
        #expect(rows[0]["meetingURL"] as? String == "https://example.invalid/meeting")
        #expect(rows[0]["location"] as? String == "Synthetic Place & Hall")
        #expect(rows[0]["allDay"] as? Bool == false)
        #expect(rows[0]["attendees"] as? [String] == [])
        let table = try await CalendarCLIExecution.run(.init(arguments: [])) { _ in events }
        #expect(table.exitCode == 0 && table.stderr.isEmpty)
        #expect(table.stdout.contains("WHEN") && table.stdout.contains("Synthetic standup"))
    }

    @Test func helpAndInvalidArgumentsNeverReadTheCalendar() async throws {
        var reads = 0
        for arguments in [["--help"], ["ls", "--help"], ["join", "--help"]] {
            let reply = try await CalendarCLIExecution.run(.init(arguments: arguments)) { _ in
                reads += 1; return []
            }
            #expect(reply.exitCode == 0 && reply.stderr.isEmpty)
            #expect(reply.stdout.contains("USAGE: calendar"))
        }
        for arguments in [
            ["ls", "--days", "121"], ["ls", "--days", "-1"], ["join"], ["--unknown"],
        ] {
            let reply = try await CalendarCLIExecution.run(.init(arguments: arguments)) { _ in
                reads += 1; return []
            }
            #expect(reply.exitCode == 2 && reply.stdout.isEmpty && !reply.stderr.isEmpty)
        }
        #expect(reads == 0)
    }

    @Test func deniedPermissionKeepsTheOriginalUnavailableExitAndHint() async throws {
        let reply = try await CalendarCLIExecution.run(.init(arguments: ["ls", "--json"])) { _ in
            throw CLIFailure.unavailable(
                "macOS has not granted Edith calendar access",
                hint: "run `ed permissions request calendar`")
        }
        #expect(reply.exitCode == 4 && reply.stdout.isEmpty)
        #expect(reply.stderr.contains("error: macOS has not granted Edith calendar access\n"))
        #expect(reply.stderr.contains("hint: run `ed permissions request calendar`\n"))
    }

    @Test func actionsUseResolvedWorkerRecordsAndOriginalRouteAlias() async throws {
        let previousURL = CalendarCLIEnvironment.openURL
        let previousCalendar = CalendarCLIEnvironment.openCalendar
        var opened: [URL] = []
        CalendarCLIEnvironment.openURL = {
            opened.append($0); return true
        }
        CalendarCLIEnvironment.openCalendar = { opened.append($0) }
        defer {
            CalendarCLIEnvironment.openURL = previousURL
            CalendarCLIEnvironment.openCalendar = previousCalendar
        }
        let join = try await CalendarCLIExecution.run(
            .init(arguments: ["join", "meeting-one", "--json"])
        ) { _ in Self.events() }
        #expect(join.exitCode == 0 && join.stderr.isEmpty)
        #expect(opened == [URL(string: "https://example.invalid/meeting")!])
        let directions = try await CalendarCLIExecution.run(
            .init(arguments: ["route", "meeting-one", "--json"])
        ) { _ in Self.events() }
        #expect(directions.exitCode == 0 && directions.stderr.isEmpty)
        let components = try #require(URLComponents(url: opened[1], resolvingAgainstBaseURL: false))
        #expect(components.host == "maps.apple.com")
        #expect(components.queryItems?.first { $0.name == "q" }?.value == "Synthetic Place & Hall")
        let launch = try await CalendarCLIExecution.run(
            .init(arguments: ["open", "--json"])
        ) { _ in
            Issue.record("Opening Calendar must not read calendar data"); return []
        }
        #expect(launch.exitCode == 0 && launch.stderr.isEmpty)
        #expect(opened.last == CalendarEventActions.calendarApplicationURL)
    }

    @Test func ambiguousMissingAndUnavailableActionsDoNotOpenAnything() async throws {
        let previous = CalendarCLIEnvironment.openURL
        var opened = 0
        CalendarCLIEnvironment.openURL = { _ in
            opened += 1; return true
        }
        defer { CalendarCLIEnvironment.openURL = previous }
        for (arguments, code) in [
            (["join", "Synthetic standup"], Int32(3)),
            (["join", "missing"], 3), (["join", "meeting-two"], 4),
            (["directions", "meeting-two"], 4),
        ] {
            let reply = try await CalendarCLIExecution.run(.init(arguments: arguments)) { _ in
                Self.events()
            }
            #expect(reply.exitCode == code && reply.stdout.isEmpty && !reply.stderr.isEmpty)
        }
        #expect(opened == 0)
    }

    @Test func cancellationDrainsTheReadAndRestoresExecutionContext() async throws {
        var reading = false
        let request = try ExtensionCLIRequest(arguments: ["ls"])
        let command = Task {
            try await CalendarCLIExecution.run(request) { _ in
                reading = true
                try await Task.sleep(for: .seconds(30))
                return []
            }
        }
        while !reading { await Task.yield() }
        command.cancel()
        await #expect(throws: CancellationError.self) { try await command.value }
        let next = try await CalendarCLIExecution.run(request) { _ in Self.events() }
        #expect(next.exitCode == 0 && next.stdout.contains("Synthetic standup"))
    }

    private static func events() -> [CalendarEventPayload] {
        let now = Date()
        return [
            .init(
                id: "meeting-one", title: "Synthetic standup", calendar: "Synthetic calendar",
                start: now.addingTimeInterval(600), end: now.addingTimeInterval(1_200),
                isAllDay: false, location: "Synthetic Place & Hall",
                meetingURL: "https://example.invalid/meeting"),
            .init(
                id: "meeting-two", title: "Synthetic standup", calendar: "Synthetic calendar",
                start: now.addingTimeInterval(1_800), end: now.addingTimeInterval(2_400),
                isAllDay: false),
        ]
    }
}
