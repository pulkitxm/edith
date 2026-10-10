import Foundation
import Testing

@testable import EdithHostCore

@Suite struct HostScheduledTaskTests {
    @Test func intervalsParseWholeNumbersWithAUnit() throws {
        #expect(try HostAgentSchedule.seconds("90s") == 90)
        #expect(try HostAgentSchedule.seconds("15m") == 900)
        #expect(try HostAgentSchedule.seconds("6h") == 21_600)
        #expect(try HostAgentSchedule.seconds("7d") == 604_800)
    }

    @Test func intervalsOutsideTheSupportedRangeAreRefused() {
        for text in ["30s", "8d", "0m", "-5m", "1.5h", "15", "m", "", "5w"] {
            #expect(throws: HostAgentCommandError.self) { _ = try HostAgentSchedule.seconds(text) }
        }
    }

    @Test func aScheduleNeedsExactlyOneOfIntervalOrCron() throws {
        #expect(try HostAgentSchedule.parse(every: "15m", cron: nil) == .interval(seconds: 900))
        #expect(
            try HostAgentSchedule.parse(every: nil, cron: " 0  3 * * * ")
                == .cron(expression: "0 3 * * *"))
        #expect(throws: HostAgentCommandError.self) {
            _ = try HostAgentSchedule.parse(every: nil, cron: nil)
        }
        #expect(throws: HostAgentCommandError.self) {
            _ = try HostAgentSchedule.parse(every: "15m", cron: "0 3 * * *")
        }
        #expect(throws: HostAgentCommandError.self) {
            _ = try HostAgentSchedule.parse(every: nil, cron: "nope")
        }
    }

    @Test func textDescribesTheSchedule() {
        #expect(HostAgentSchedule.interval(seconds: 900).text == "every 15m")
        #expect(HostAgentSchedule.interval(seconds: 90).text == "every 90s")
        #expect(HostAgentSchedule.interval(seconds: 7_200).text == "every 2h")
        #expect(HostAgentSchedule.cron(expression: "0 3 * * *").text == "cron 0 3 * * *")
    }

    @Test func intervalsAdvanceFromTheGivenInstant() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(
            HostAgentSchedule.interval(seconds: 600).next(after: start)
                == start.addingTimeInterval(600)
        )
    }

    @Test func namesUseLowercaseLettersDigitsAndSeparators() {
        for name in ["a", "backup", "nightly-2", "sync.v1", "x_y", "9lives"] {
            #expect(HostScheduledTaskDefinition.isValid(name: name))
        }
        for name in [
            "", "Backup", "-leading", "has space", "a/b", "é", String(repeating: "a", count: 65),
        ] {
            #expect(!HostScheduledTaskDefinition.isValid(name: name))
        }
    }

    @Test func definitionsRequireAbsolutePathsAndABoundedTimeout() throws {
        let schedule = HostAgentSchedule.interval(seconds: 600)
        _ = try HostScheduledTaskDefinition(
            name: "ok", schedule: schedule, executablePath: "/usr/bin/true", arguments: [])
        #expect(throws: HostAgentCommandError.self) {
            _ = try HostScheduledTaskDefinition(
                name: "bad", schedule: schedule, executablePath: "true", arguments: [])
        }
        #expect(throws: HostAgentCommandError.self) {
            _ = try HostScheduledTaskDefinition(
                name: "bad", schedule: schedule, executablePath: "/usr/bin/true", arguments: [],
                workingDirectory: "relative")
        }
        for timeout in [0, -1, 7_201, Double.infinity] {
            #expect(throws: HostAgentCommandError.self) {
                _ = try HostScheduledTaskDefinition(
                    name: "bad", schedule: schedule, executablePath: "/usr/bin/true",
                    arguments: [], timeout: timeout)
            }
        }
    }

    @Test func definitionsSurviveTheHostAgentPayloadRoundTrip() throws {
        let definition = try HostScheduledTaskDefinition(
            name: "nightly", schedule: .cron(expression: "30 2 * * *"),
            executablePath: "/usr/bin/true", arguments: ["--flag", "value"],
            workingDirectory: "/tmp", timeout: 600)
        let decoded = try HostAgentPayload.decode(
            HostScheduledTaskDefinition.self, from: HostAgentPayload.encode(definition))
        #expect(decoded == definition)
    }
}
