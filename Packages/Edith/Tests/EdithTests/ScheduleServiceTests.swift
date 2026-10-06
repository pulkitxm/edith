import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct ScheduleServiceTests {
    private final class Clock: @unchecked Sendable {
        private let lock = NSLock()
        private var current: Date

        init(_ start: Date) { current = start }

        var now: Date { lock.withLock { current } }

        func advance(_ seconds: TimeInterval) {
            lock.withLock { current = current.addingTimeInterval(seconds) }
        }
    }

    private actor Launches {
        private(set) var requests: [CLICommandRequest] = []
        private var gate: CheckedContinuation<Void, Never>?
        var holds = false

        func hold() { holds = true }

        func record(_ request: CLICommandRequest) async {
            requests.append(request)
            if holds { await withCheckedContinuation { gate = $0 } }
        }

        func release() {
            holds = false
            gate?.resume()
            gate = nil
        }
    }

    private struct Fixture {
        let directory: URL
        let store: AgentStore
        let tasks: AgentTaskService
        let clock: Clock
        let launches: Launches
        let service: ScheduleService

        func cleanUp() async {
            await service.shutdown()
            await tasks.shutdown()
            try? store.close()
            try? FileManager.default.removeItem(at: directory)
        }
    }

    private static let origin = Date(timeIntervalSince1970: 1_800_000_000)

    private func makeFixture(clock: Clock? = nil, reusing directory: URL? = nil) async throws
        -> Fixture
    {
        let directory =
            directory
            ?? FileManager.default.temporaryDirectory.appendingPathComponent(
                "schedule-tests-\(UUID().uuidString)")
        let store = try AgentStore(
            url: directory.appendingPathComponent("store.sqlite"), build: "test")
        let tasks = try AgentTaskService(directory: nil)
        let launches = Launches()
        await tasks.register(operation: AgentTaskOperation.command) { payload, _ in
            let request = try AgentPayload.decode(CLICommandRequest.self, from: payload)
            await launches.record(request)
            return Data()
        }
        let clock = clock ?? Clock(Self.origin)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let service = ScheduleService(
            store: store, tasks: tasks, now: { clock.now }, calendar: calendar,
            sleep: { _ in try await Task.sleep(for: .seconds(3_600)) })
        return Fixture(
            directory: directory, store: store, tasks: tasks, clock: clock, launches: launches,
            service: service)
    }

    private func definition(
        _ name: String = "sync", every: String = "5m"
    ) throws -> ScheduledTaskDefinition {
        try ScheduledTaskDefinition(
            name: name, schedule: AgentSchedule.parse(every: every, cron: nil),
            executablePath: "/usr/bin/true", arguments: ["--quiet"], workingDirectory: "/tmp",
            timeout: 120)
    }

    private func eventually(_ condition: @escaping @Sendable () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await condition())
    }

    @Test func addingASchedulePlansTheNextRunAndRefusesDuplicates() async throws {
        let fixture = try await makeFixture()
        let added = try await fixture.service.add(definition())
        #expect(added.enabled)
        #expect(added.nextRunAt == Self.origin.addingTimeInterval(300))
        #expect(added.lastRunAt == nil)
        await #expect(throws: AgentError.self) { _ = try await fixture.service.add(definition()) }
        #expect(try await fixture.service.list().map(\.definition.name) == ["sync"])
        await fixture.cleanUp()
    }

    @Test func aScheduleThatNeverFiresIsRefused() async throws {
        let fixture = try await makeFixture()
        let never = try ScheduledTaskDefinition(
            name: "never", schedule: .cron(expression: "0 0 31 2 *"),
            executablePath: "/usr/bin/true", arguments: [])
        await #expect(throws: AgentError.self) { _ = try await fixture.service.add(never) }
        await fixture.cleanUp()
    }

    @Test func aDueScheduleRunsOnceThroughTheTaskQueueAndMovesForward() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.service.add(definition())
        await fixture.service.fireDue()
        #expect(await fixture.launches.requests.isEmpty)

        fixture.clock.advance(301)
        let firstNextRunAt = fixture.clock.now.addingTimeInterval(300)
        try await eventually {
            await fixture.service.fireDue()
            let recorded = try? await fixture.service.list().first
            guard await fixture.launches.requests.count == 1 else { return false }
            return recorded?.lastTaskID != nil && recorded?.nextRunAt == firstNextRunAt
        }
        let request = try #require(await fixture.launches.requests.first)
        #expect(request.executableURL.path == "/usr/bin/true")
        #expect(request.arguments == ["--quiet"])
        #expect(request.currentDirectoryURL?.path == "/tmp")
        #expect(request.timeout == 120)
        #expect(request.terminatesProcessGroup)

        let listed = try #require(try await fixture.service.list().first)
        #expect(listed.lastRunAt == fixture.clock.now)
        #expect(listed.lastTaskID != nil)
        #expect(listed.nextRunAt == fixture.clock.now.addingTimeInterval(300))
        try await eventually {
            (try? await fixture.service.list().first?.lastState) == .succeeded
        }

        await fixture.service.fireDue()
        #expect(await fixture.launches.requests.count == 1)
        await fixture.cleanUp()
    }

    @Test func aRunIsSkippedWhileThePreviousOneIsStillGoing() async throws {
        let fixture = try await makeFixture()
        await fixture.launches.hold()
        _ = try await fixture.service.add(definition())
        fixture.clock.advance(301)
        let firstNextRunAt = fixture.clock.now.addingTimeInterval(300)
        try await eventually {
            await fixture.service.fireDue()
            let recorded = try? await fixture.service.list().first
            guard await fixture.launches.requests.count == 1 else { return false }
            return recorded?.lastTaskID != nil && recorded?.nextRunAt == firstNextRunAt
        }

        fixture.clock.advance(300)
        let skippedNextRunAt = fixture.clock.now.addingTimeInterval(300)
        try await eventually {
            await fixture.service.fireDue()
            return (try? await fixture.service.list().first?.nextRunAt) == skippedNextRunAt
        }
        #expect(await fixture.launches.requests.count == 1)
        let skipped = try #require(try await fixture.service.list().first)
        #expect(skipped.nextRunAt == fixture.clock.now.addingTimeInterval(300))

        await #expect(throws: AgentError.self) { _ = try await fixture.service.runNow("sync") }
        await fixture.launches.release()
        try await eventually {
            (try? await fixture.service.list().first?.lastState) == .succeeded
        }
        await fixture.cleanUp()
    }

    @Test func disablingStopsRunsAndEnablingPlansFromNow() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.service.add(definition())
        let paused = try await fixture.service.setEnabled("sync", false)
        #expect(!paused.enabled)
        #expect(paused.nextRunAt == nil)
        fixture.clock.advance(3_600)
        await fixture.service.fireDue()
        #expect(await fixture.launches.requests.isEmpty)

        let resumed = try await fixture.service.setEnabled("sync", true)
        #expect(resumed.nextRunAt == fixture.clock.now.addingTimeInterval(300))
        await fixture.cleanUp()
    }

    @Test func runNowQueuesTheCommandWithoutMovingTheSchedule() async throws {
        let fixture = try await makeFixture()
        let added = try await fixture.service.add(definition())
        let task = try await fixture.service.runNow("sync")
        #expect(task.operation == AgentTaskOperation.command)
        try await eventually { await fixture.launches.requests.count == 1 }
        let listed = try #require(try await fixture.service.list().first)
        #expect(listed.nextRunAt == added.nextRunAt)
        #expect(listed.lastTaskID == task.id)
        await fixture.cleanUp()
    }

    @Test func removingAScheduleDeletesItAndUnknownNamesFail() async throws {
        let fixture = try await makeFixture()
        _ = try await fixture.service.add(definition())
        try await fixture.service.remove("sync")
        #expect(try await fixture.service.list().isEmpty)
        await #expect(throws: AgentError.self) { try await fixture.service.remove("sync") }
        await #expect(throws: AgentError.self) { _ = try await fixture.service.runNow("sync") }
        await #expect(throws: AgentError.self) {
            _ = try await fixture.service.setEnabled("sync", false)
        }
        await fixture.cleanUp()
    }

    @Test func schedulesSurviveARestartAndMissedRunsAreSkipped() async throws {
        let first = try await makeFixture()
        _ = try await first.service.add(definition())
        let directory = first.directory
        let clock = first.clock
        await first.service.shutdown()
        await first.tasks.shutdown()
        try first.store.close()

        clock.advance(7_200)
        let second = try await makeFixture(clock: clock, reusing: directory)
        await second.service.start()
        let listed = try #require(try await second.service.list().first)
        #expect(listed.definition.name == "sync")
        #expect(listed.nextRunAt == clock.now.addingTimeInterval(300))
        #expect(listed.lastRunAt == nil)
        await second.service.fireDue()
        #expect(await second.launches.requests.isEmpty)
        await second.cleanUp()
    }

    @Test func theNumberOfSchedulesIsBounded() async throws {
        let fixture = try await makeFixture()
        for index in 0..<ScheduleService.maximumSchedules {
            _ = try await fixture.service.add(definition("job-\(index)"))
        }
        await #expect(throws: AgentError.self) {
            _ = try await fixture.service.add(definition("one-too-many"))
        }
        await fixture.cleanUp()
    }
}
