import Foundation
import Testing

@testable import EdithKit

@Suite struct ScheduledTaskTests {
    @Test func intervalsParseWholeNumbersWithAUnit() throws {
        #expect(try AgentSchedule.seconds("90s") == 90)
        #expect(try AgentSchedule.seconds("15m") == 900)
        #expect(try AgentSchedule.seconds("6h") == 21_600)
        #expect(try AgentSchedule.seconds("7d") == 604_800)
    }

    @Test func intervalsOutsideTheSupportedRangeAreRefused() {
        for text in ["30s", "8d", "0m", "-5m", "1.5h", "15", "m", "", "5w"] {
            #expect(throws: AgentError.self) { _ = try AgentSchedule.seconds(text) }
        }
    }

    @Test func aScheduleNeedsExactlyOneOfIntervalOrCron() throws {
        #expect(try AgentSchedule.parse(every: "15m", cron: nil) == .interval(seconds: 900))
        #expect(
            try AgentSchedule.parse(every: nil, cron: " 0  3 * * * ")
                == .cron(expression: "0 3 * * *"))
        #expect(throws: AgentError.self) { _ = try AgentSchedule.parse(every: nil, cron: nil) }
        #expect(throws: AgentError.self) {
            _ = try AgentSchedule.parse(every: "15m", cron: "0 3 * * *")
        }
        #expect(throws: AgentError.self) { _ = try AgentSchedule.parse(every: nil, cron: "nope") }
    }

    @Test func textDescribesTheSchedule() {
        #expect(AgentSchedule.interval(seconds: 900).text == "every 15m")
        #expect(AgentSchedule.interval(seconds: 90).text == "every 90s")
        #expect(AgentSchedule.interval(seconds: 7_200).text == "every 2h")
        #expect(AgentSchedule.cron(expression: "0 3 * * *").text == "cron 0 3 * * *")
    }

    @Test func intervalsAdvanceFromTheGivenInstant() {
        let start = Date(timeIntervalSince1970: 1_000)
        #expect(
            AgentSchedule.interval(seconds: 600).next(after: start) == start.addingTimeInterval(600)
        )
    }

    @Test func namesUseLowercaseLettersDigitsAndSeparators() {
        for name in ["a", "backup", "nightly-2", "sync.v1", "x_y", "9lives"] {
            #expect(ScheduledTaskDefinition.isValid(name: name))
        }
        for name in [
            "", "Backup", "-leading", "has space", "a/b", "é", String(repeating: "a", count: 65),
        ] {
            #expect(!ScheduledTaskDefinition.isValid(name: name))
        }
    }

    @Test func definitionsRequireAbsolutePathsAndABoundedTimeout() throws {
        let schedule = AgentSchedule.interval(seconds: 600)
        _ = try ScheduledTaskDefinition(
            name: "ok", schedule: schedule, executablePath: "/usr/bin/true", arguments: [])
        #expect(throws: AgentError.self) {
            _ = try ScheduledTaskDefinition(
                name: "bad", schedule: schedule, executablePath: "true", arguments: [])
        }
        #expect(throws: AgentError.self) {
            _ = try ScheduledTaskDefinition(
                name: "bad", schedule: schedule, executablePath: "/usr/bin/true", arguments: [],
                workingDirectory: "relative")
        }
        for timeout in [0, -1, 7_201, Double.infinity] {
            #expect(throws: AgentError.self) {
                _ = try ScheduledTaskDefinition(
                    name: "bad", schedule: schedule, executablePath: "/usr/bin/true",
                    arguments: [], timeout: timeout)
            }
        }
    }

    @Test func definitionsSurviveTheAgentPayloadRoundTrip() throws {
        let definition = try ScheduledTaskDefinition(
            name: "nightly", schedule: .cron(expression: "30 2 * * *"),
            executablePath: "/usr/bin/true", arguments: ["--flag", "value"],
            workingDirectory: "/tmp", timeout: 600)
        let decoded = try AgentPayload.decode(
            ScheduledTaskDefinition.self, from: AgentPayload.encode(definition))
        #expect(decoded == definition)
    }
}
