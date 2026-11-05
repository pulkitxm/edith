import Foundation
import Testing

@testable import EdithHost

@MainActor @Suite(.serialized) struct HostBackgroundOverviewTests {
    private func job(
        _ id: String, phase: String = "idle", ability: String? = nil, ambient: Double? = 900,
        runs: Int = 1, lastRun: Double? = 100
    ) throws -> HostBackgroundJob {
        let abilityJSON = ability.map { "\"\($0)\"" } ?? "null"
        let ambientJSON = ambient.map { String($0) } ?? "null"
        let lastRunJSON = lastRun.map { String($0) } ?? "null"
        return try JSONDecoder().decode(
            HostBackgroundJob.self,
            from: Data(
                """
                {"descriptor":{"id":"\(id)","title":"Job \(id)","trigger":"timer","topic":null,"cadence":{"ambient":\(ambientJSON),"live":null},"power":"pauseOnBattery","abilityID":\(abilityJSON)},"phase":"\(phase)","subscribers":0,"lastRun":\(lastRunJSON),"lastDuration":1,"lastError":null,"runCount":\(runs)}
                """.utf8))
    }

    private func model(
        _ states: [[HostBackgroundJob]], reads: FixtureReads, controls: FixtureReads
    ) -> HostBackgroundModel {
        HostBackgroundModel(
            environment: .init(
                identity: { "core:1" },
                read: {
                    let index = min(reads.count, states.count - 1)
                    reads.count += 1
                    return .init(jobs: states[index], events: [], unavailable: nil)
                },
                control: { _, _ in controls.count += 1 },
                settle: {}, settleAttempts: 3))
    }

    @MainActor final class FixtureReads { var count = 0 }

    @Test func ownersComeFromTheAbilityOrTheJobIdentifierPrefix() throws {
        let usage = try job("usage.refresh")
        let herdr = try job("sessions.discover", ability: "herdr")
        let solo = try job("solo")
        #expect(usage.ownerID == "usage")
        #expect(herdr.ownerID == "herdr")
        #expect(solo.ownerID == "solo")
        #expect(try job("backup.sync").ownerID == "")
        #expect(try job("storage.inspect").ownerID == "")
        #expect(HostBackgroundModel.fallbackTitle("") == "Built into Edith")
    }

    @Test func detailsReadAsOneLineOfPlainFacts() throws {
        let now = Date(timeIntervalSinceReferenceDate: 400)
        let scheduled = try job("usage.refresh", lastRun: 160)
        #expect(scheduled.details(now: now) == "Every 15 min · Pauses on battery · Last ran 4m ago")
        let fresh = try job("usage.refresh", ambient: nil, lastRun: nil)
        #expect(fresh.details(now: now) == "Runs when needed · Pauses on battery · Not run yet")
    }

    @Test func builtInJobsAreGroupedLast() async throws {
        let reads = FixtureReads()
        let model = model(
            [[try job("backup.sync"), try job("zeta.run"), try job("alpha.run")]], reads: reads,
            controls: FixtureReads())
        await model.refresh()
        #expect(model.groups { _ in nil }.map(\.title) == ["Alpha", "Zeta", "Built into Edith"])
    }

    @Test func statusLabelsAreWrittenForPeople() throws {
        let running = try job("a.b", phase: "running")
        let failed = try job("a.b", phase: "failed")
        let idle = try job("a.b", phase: "idle")
        let onDemand = try job("a.b", phase: "idle", ambient: nil)
        let paused = try job("a.b", phase: "paused")
        let off = try job("a.b", phase: "disabled")
        #expect(running.statusTitle == "Running")
        #expect(failed.statusTitle == "Failed")
        #expect(idle.statusTitle == "Scheduled")
        #expect(onDemand.statusTitle == "On demand")
        #expect(onDemand.scheduleSentence == "Runs when needed")
        #expect(idle.pauseReason == "Pauses on battery")
        #expect(running.actionTitle == "Stop")
        #expect(paused.actionTitle == "Run now")
        #expect(off.actionTitle == nil)
    }

    @Test func overviewCountsRunningFailedAndActiveTasks() throws {
        let jobs = [
            try job("a.b", phase: "running"), try job("c.d", phase: "failed"), try job("e.f"),
        ]
        let overview = HostBackgroundOverview(jobs: jobs, activeTasks: 2)
        #expect(overview.running == 3 && overview.needingAttention == 1 && overview.total == 3)
        #expect(overview.sentence == "3 scheduled jobs, 3 running now, 1 needs attention.")
        #expect(HostBackgroundOverview(jobs: []).sentence == "No scheduled jobs yet.")
        #expect(HostBackgroundOverview(jobs: [], activeTasks: 2).sentence == "2 running now.")
        let calm = HostBackgroundOverview(jobs: [try job("e.f")])
        #expect(calm.sentence == "1 scheduled job, none running right now.")
    }

    @Test func groupsAreNamedByOwnerWithRunningAndFailedJobsFirst() async throws {
        let jobs = [
            try job("usage.z"), try job("usage.a", phase: "failed"),
            try job("usage.m", phase: "running"), try job("herdr.x"),
        ]
        let reads = FixtureReads()
        let model = model([jobs], reads: reads, controls: FixtureReads())
        await model.refresh()
        let groups = model.groups { $0 == "usage" ? "Usage" : nil }
        #expect(groups.map(\.title) == ["Herdr", "Usage"])
        #expect(groups[1].jobs.map(\.id) == ["usage.m", "usage.a", "usage.z"])
    }

    @Test func runningAJobKeepsReadingUntilTheOwnerReportsIt() async throws {
        let before = try job("usage.refresh")
        let running = try job("usage.refresh", phase: "running")
        let reads = FixtureReads(), controls = FixtureReads()
        let model = model([[before], [before], [running]], reads: reads, controls: controls)
        await model.refresh()
        await model.control(before)
        #expect(controls.count == 1)
        #expect(reads.count == 3)
        #expect(model.jobs.first?.phase == "running")
        #expect(model.action == nil)
    }

    @Test func stoppingAJobStopsReadingOnceItLeavesRunning() async throws {
        let running = try job("usage.refresh", phase: "running")
        let idle = try job("usage.refresh")
        let reads = FixtureReads(), controls = FixtureReads()
        let model = model([[running], [idle]], reads: reads, controls: controls)
        await model.refresh()
        await model.control(running)
        #expect(reads.count == 2)
        #expect(model.jobs.first?.phase == "idle")
    }

    @Test func settlingGivesUpAfterItsAttempts() async throws {
        let before = try job("usage.refresh")
        let reads = FixtureReads()
        let model = model([[before]], reads: reads, controls: FixtureReads())
        await model.refresh()
        await model.control(before)
        #expect(reads.count == 1 + 1 + 3)
    }
}
