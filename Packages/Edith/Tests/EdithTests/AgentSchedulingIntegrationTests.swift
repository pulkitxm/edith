import Foundation
import GRDB
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct AgentSchedulingIntegrationTests {
    @Test func overlappingRefreshesShareOneExecutionAndOnePublication() async {
        let gate = CollectorGate()
        let output = SchedulerOutput()
        let scheduler = JobScheduler(publish: { output.append($0, $1) })
        await scheduler.register(AgentJob(descriptor: descriptor()) { await gate.run() })
        let first = Task { await scheduler.runNow("fixture.refresh") }
        await gate.waitForStart()
        let second = Task { await scheduler.runNow("fixture.refresh") }
        await scheduler.enqueueIfDue("fixture.refresh")
        #expect(await scheduler.snapshots.first?.phase == .running)
        await waitForJoin(scheduler)
        await gate.release()
        #expect(await first.value == Data("result".utf8))
        #expect(await second.value == Data("result".utf8))
        #expect(await gate.executions == 1)
        #expect(await scheduler.snapshots.first?.runCount == 1)
        #expect(output.count(topic: .usage) == 1)
    }

    @Test(arguments: [1, 5])
    func explicitEnqueuesDuringCollectionProduceOneFollowUp(requests: Int) async {
        let gate = CollectorGate()
        let output = SchedulerOutput()
        let scheduler = JobScheduler(publish: { output.append($0, $1) })
        await scheduler.register(AgentJob(descriptor: descriptor()) { await gate.run() })
        let first = Task { await scheduler.runNow("fixture.refresh") }
        await gate.waitForStart()
        for _ in 0..<requests { #expect(await scheduler.enqueue("fixture.refresh")) }
        await gate.release()
        #expect(await first.value == Data("result".utf8))
        #expect(
            await waitUntil {
                await scheduler.snapshots.first?.runCount == 2
            })
        #expect(await gate.executions == 2)
        #expect(output.count(topic: .usage) == 2)
        await scheduler.shutdown()
    }

    @Test(arguments: [false, true])
    func cancellingOrStoppingDiscardsPendingFollowUp(stop: Bool) async {
        let gate = CollectorGate()
        let scheduler = JobScheduler()
        await scheduler.register(AgentJob(descriptor: descriptor()) { await gate.run() })
        let first = Task { await scheduler.runNow("fixture.refresh") }
        await gate.waitForStart()
        #expect(await scheduler.enqueue("fixture.refresh"))
        if stop { await scheduler.stop() } else { await scheduler.cancel("fixture.refresh") }
        await gate.release()
        _ = await first.value
        for _ in 0..<50 { await Task.yield() }
        #expect(await gate.executions == 1)
        await scheduler.shutdown()
    }

    @Test func passiveTriggersDuringCollectionDoNotRequestAnotherRun() async {
        let gate = CollectorGate()
        let policy = SchedulerPolicy()
        let scheduler = JobScheduler(clock: { policy.date })
        await scheduler.register(
            AgentJob(descriptor: descriptor(cadence: .every(ambient: 900))) { await gate.run() })
        await scheduler.start()
        let first = Task { await scheduler.runNow("fixture.refresh") }
        await gate.waitForStart()
        policy.advance(901)
        for _ in 0..<5 {
            _ = await scheduler.enqueueIfDue("fixture.refresh")
            await scheduler.addSubscriber(topic: .usage)
            await scheduler.removeSubscriber(topic: .usage)
            await scheduler.tick()
        }
        await gate.release()
        _ = await first.value
        for _ in 0..<50 { await Task.yield() }
        #expect(await gate.executions == 1)
        await scheduler.shutdown()
    }

    @Test func subscriberChangesDoNotCancelTheRunningCollector() async {
        let gate = CollectorGate()
        let scheduler = JobScheduler()
        await scheduler.register(AgentJob(descriptor: descriptor()) { await gate.run() })
        await scheduler.start()
        let task = Task { await scheduler.runNow("fixture.refresh") }
        await gate.waitForStart()
        await scheduler.addSubscriber(topic: .usage)
        await scheduler.removeSubscriber(topic: .usage)
        await gate.release()
        #expect(await task.value != nil)
        #expect(await scheduler.snapshots.first?.runCount == 1)
        await scheduler.stop()
    }

    @Test func stoppingDiscardsAnUncooperativeCollectorsLateResult() async {
        let gate = CollectorGate()
        let output = SchedulerOutput()
        let scheduler = JobScheduler(publish: { output.append($0, $1) })
        await scheduler.register(AgentJob(descriptor: descriptor()) { await gate.run() })
        let task = Task { await scheduler.runNow("fixture.refresh") }
        await gate.waitForStart()
        await scheduler.stop()
        await gate.release()
        #expect(await task.value == nil)
        #expect(output.count(topic: .usage) == 0)
        #expect(await scheduler.snapshots.first?.phase == .idle)
    }

    @Test func aJobDisabledAtStartupCanResumeWithoutRestartingTheDaemon() async {
        let policy = SchedulerPolicy()
        let gate = CollectorGate()
        let scheduler = JobScheduler(clock: { policy.date })
        await scheduler.register(
            AgentJob(
                descriptor: descriptor(cadence: .every(ambient: 5)),
                isEnabled: { policy.enabled }
            ) { await gate.run() })
        await scheduler.start()
        #expect(await scheduler.snapshots.first?.phase == .disabled)
        policy.enable()
        await scheduler.refreshSchedule()
        policy.advance(6)
        await scheduler.tick()
        await gate.waitForStart()
        #expect(await gate.executions == 1)
        await gate.release()
        await scheduler.stop()
    }

    @Test func filesystemEnqueueRefreshesLiveSubscribersWithoutChangingAmbientCadence() async {
        let policy = SchedulerPolicy()
        let scheduler = JobScheduler(clock: { policy.date })
        await scheduler.register(
            AgentJob(descriptor: descriptor(cadence: .every(ambient: 900))) {
                Data("done".utf8)
            })
        await scheduler.start()
        _ = await scheduler.runNow("fixture.refresh")

        #expect(
            await !scheduler.enqueueFileSystemChange("fixture.refresh", topic: .usage))
        policy.advance(899)
        #expect(
            await !scheduler.enqueueFileSystemChange("fixture.refresh", topic: .usage))
        await scheduler.addSubscriber(topic: .usage)
        #expect(await scheduler.enqueueFileSystemChange("fixture.refresh", topic: .usage))
        for _ in 0..<1_000 {
            let snapshot = await scheduler.snapshots.first
            if snapshot?.runCount == 2, snapshot?.phase == .idle { break }
            await Task.yield()
        }

        #expect(await scheduler.snapshots.first?.runCount == 2)
        await scheduler.removeSubscriber(topic: .usage)
        #expect(await !scheduler.enqueueFileSystemChange("fixture.refresh", topic: .usage))
        policy.advance(901)
        #expect(await scheduler.enqueueFileSystemChange("fixture.refresh", topic: .usage))
        await scheduler.stop()
    }

    @Test func theDefaultConcurrencyLimitFollowsActiveProcessors() async {
        let scheduler = JobScheduler()
        let expected = max(2, ProcessInfo.processInfo.activeProcessorCount)
        #expect(await scheduler.concurrencyLimit == expected)
        await scheduler.shutdown()
    }

    @Test func independentJobsRunTogether() async {
        let count = 4
        let gate = AdmissionGate()
        let scheduler = JobScheduler(maxConcurrent: count)
        for index in 0..<count {
            let id = "job.\(index)"
            await scheduler.register(
                AgentJob(descriptor: descriptor(id: id)) {
                    await gate.enter()
                    return nil
                })
        }
        for index in 0..<count {
            #expect(await scheduler.enqueue("job.\(index)"))
        }
        let admitted = await waitUntil { await gate.entered >= count }
        let running = await scheduler.snapshots.filter { $0.phase == .running }.count
        await gate.release()
        #expect(admitted)
        #expect(running == count)
        #expect(await waitForCompletions(scheduler, expected: count))
        await scheduler.shutdown()
    }

    @Test func slowJobsFinishTogetherInsteadOfOneByOne() async {
        let count = 4
        let scheduler = JobScheduler(maxConcurrent: count)
        for index in 0..<count {
            let id = "sleep.\(index)"
            await scheduler.register(
                AgentJob(descriptor: descriptor(id: id)) {
                    try await Task.sleep(for: .milliseconds(200))
                    return nil
                })
        }
        let started = ContinuousClock.now
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { _ = await scheduler.runNow("sleep.\(index)") }
            }
        }
        let elapsed = ContinuousClock.now - started
        #expect(elapsed < .milliseconds(750))
        #expect(await scheduler.snapshots.allSatisfy { $0.runCount == 1 })
        await scheduler.shutdown()
    }

    @Test func theSchedulerNeverExceedsItsCap() async {
        let cap = 2
        let count = 6
        let gate = AdmissionGate()
        let scheduler = JobScheduler(maxConcurrent: cap)
        for index in 0..<count {
            let id = "job.\(index)"
            await scheduler.register(
                AgentJob(descriptor: descriptor(id: id)) {
                    await gate.enter()
                    return nil
                })
        }
        for index in 0..<count {
            #expect(await scheduler.enqueue("job.\(index)"))
        }
        let admitted = await waitUntil { await gate.entered >= cap }
        let entered = await gate.entered
        let running = await scheduler.snapshots.filter { $0.phase == .running }.count
        #expect(admitted)
        #expect(entered == cap)
        #expect(running == cap)
        await gate.release()
        #expect(await waitForCompletions(scheduler, expected: count))
        await scheduler.shutdown()
    }

    @Test func aClockJumpKeepsInFlightWorkInsideTheCap() async {
        let cap = 2
        let count = 8
        let gate = AdmissionGate()
        let policy = SchedulerPolicy()
        let scheduler = JobScheduler(maxConcurrent: cap, clock: { policy.date })
        for index in 0..<count {
            let id = "job.\(index)"
            await scheduler.register(
                AgentJob(descriptor: descriptor(id: id, cadence: .every(ambient: 30))) {
                    await gate.enter()
                    return nil
                })
        }
        await scheduler.start()
        policy.advance(86_400)
        await scheduler.tick()
        let admitted = await waitUntil { await gate.entered >= cap }
        let entered = await gate.entered
        let running = await scheduler.snapshots.filter { $0.phase == .running }.count
        #expect(admitted)
        #expect(entered == cap)
        #expect(running == cap)
        await gate.release()
        #expect(await waitForCompletions(scheduler, expected: count))
        await scheduler.shutdown()
    }

    @Test func lowPowerStretchesAnAlreadyStoredNextRun() async {
        let power = MutablePower()
        let policy = SchedulerPolicy()
        let counter = RunCounter()
        let scheduler = JobScheduler(power: power, clock: { policy.date })
        await scheduler.register(
            AgentJob(descriptor: descriptor(cadence: .every(ambient: 900))) {
                counter.bump()
                return nil
            })
        await scheduler.start()
        policy.advance(800)
        power.set(constrained: true)
        await scheduler.refreshSchedule()
        policy.advance(200)
        await scheduler.tick()
        #expect(
            await waitUntil(attempts: 15, pause: .milliseconds(10)) { counter.value > 0 } == false)
        policy.advance(2_500)
        await scheduler.tick()
        #expect(await waitForCompletions(scheduler, expected: 1))
        await scheduler.shutdown()
    }

    @Test func batteryPausesAScheduledJobWithoutWaitingForItToFinish() async {
        let power = MutablePower()
        let policy = SchedulerPolicy()
        let counter = RunCounter()
        let scheduler = JobScheduler(power: power, clock: { policy.date })
        await scheduler.register(
            AgentJob(
                descriptor: descriptor(cadence: .every(ambient: 100), power: .pauseOnBattery)
            ) {
                counter.bump()
                return nil
            })
        await scheduler.start()
        #expect(await scheduler.snapshots.first?.phase == .idle)
        power.set(battery: true)
        await scheduler.refreshSchedule()
        #expect(await scheduler.snapshots.first?.phase == .paused)
        policy.advance(10_000)
        await scheduler.tick()
        #expect(
            await waitUntil(attempts: 15, pause: .milliseconds(10)) { counter.value > 0 } == false)
        await scheduler.shutdown()
    }

    @Test func lockingPausesAScheduledJobImmediately() async {
        let power = MutablePower()
        let policy = SchedulerPolicy()
        let counter = RunCounter()
        let scheduler = JobScheduler(power: power, clock: { policy.date })
        await scheduler.register(
            AgentJob(descriptor: descriptor(cadence: .every(ambient: 100), power: .pauseOnLock)) {
                counter.bump()
                return nil
            })
        await scheduler.start()
        power.set(locked: true)
        await scheduler.refreshSchedule()
        #expect(await scheduler.snapshots.first?.phase == .paused)
        policy.advance(10_000)
        await scheduler.tick()
        #expect(
            await waitUntil(attempts: 15, pause: .milliseconds(10)) { counter.value > 0 } == false)
        await scheduler.shutdown()
    }

    @Test func lowPowerLeavesLiveCadenceShort() async {
        let power = MutablePower()
        let policy = SchedulerPolicy()
        let counter = RunCounter()
        let scheduler = JobScheduler(power: power, clock: { policy.date })
        await scheduler.register(
            AgentJob(descriptor: descriptor(cadence: .every(ambient: 900, live: 10))) {
                counter.bump()
                return nil
            })
        await scheduler.addSubscriber(topic: .usage)
        await scheduler.start()
        power.set(constrained: true)
        await scheduler.refreshSchedule()
        policy.advance(10)
        await scheduler.tick()
        #expect(await waitForCompletions(scheduler, expected: 1))
        await scheduler.shutdown()
    }

    @Test func mixedBusAndTopicSubscriptionsKeepTheirRelayUntilBothAreRemoved() async {
        let runtime = AgentRuntime(build: "fixture", store: nil)
        let peer = UUID()
        let listener = DiagnosticSubscriber()
        await runtime.subscribeBus(peer: peer, channel: "fixture", subscriber: listener)
        await runtime.subscribe(peer: peer, topic: .usage, subscriber: listener)
        await runtime.unsubscribe(peer: peer, topic: .usage)
        await runtime.publishBus(AgentBusMessage(channel: "fixture", body: Data()), from: nil)
        #expect(listener.count(topic: "bus:fixture") == 1)
        await runtime.unsubscribeBus(peer: peer, channel: "fixture")
        #expect(await runtime.runtimeSnapshot().subscriberCount == 0)
    }

    @Test func eventHistoryIsBoundedAndSurvivesARuntimeRestart() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = try AgentStore(
            url: root.appendingPathComponent("edith.sqlite"), build: "fixture")
        let runtime = AgentRuntime(build: "fixture", store: store)
        let taskID = UUID()
        for index in 0..<(AgentDiagnostics.capacity + 5) {
            await runtime.record(
                AgentEvent(category: "fixture", name: "step", message: "\(index)", taskID: taskID))
        }
        await runtime.flushJournal()
        let restarted = AgentRuntime(build: "fixture", store: store)
        let events = try AgentPayload.decode(
            [AgentEvent].self, from: await restarted.snapshot(topic: .events))
        #expect(events.count == AgentDiagnostics.capacity)
        #expect(events.first?.message == "5")
        #expect(events.last?.message == "504")
        #expect(events.allSatisfy { $0.taskID == taskID })
        #expect(
            try store.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM agent_event") } == 500)
        try store.close()
    }

    @Test func migrationBackupIncludesCommittedWALRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("edith.sqlite")
        let old = try AgentStore(url: url, build: "old")
        try old.write { database in
            try database.execute(sql: "DROP TABLE agent_event")
            try database.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = '0003-agent-events'")
            try database.execute(sql: "PRAGMA user_version = 2")
            try database.execute(
                sql: "INSERT INTO download_item VALUES ('fixture', ?, 'queued', ?)",
                arguments: [Date(), Data("retained".utf8)])
        }
        let upgraded = try AgentStore(url: url, build: "new")
        let backup = try DatabaseQueue(
            path: AgentStoreLayout.backupURL(root: root, build: "new").path)
        #expect(
            try backup.read {
                try String.fetchOne(
                    $0, sql: "SELECT status FROM download_item WHERE id = 'fixture'")
            } == "queued")
        #expect(try backup.read { try Int.fetchOne($0, sql: "PRAGMA user_version") } == 2)
        #expect(upgraded.schemaVersion == AgentSchema.version)
        try backup.close()
        try upgraded.close()
        try old.close()
    }

    private func descriptor(
        id: String = "fixture.refresh", cadence: AgentCadence = .onDemand,
        power: AgentPowerPolicy = .any
    ) -> AgentJobDescriptor {
        AgentJobDescriptor(
            id: id, title: id, trigger: .timer, topic: .usage, cadence: cadence, power: power)
    }
}

private func waitUntil(
    attempts: Int = 50, pause: Duration = .milliseconds(20),
    _ ready: @Sendable () async -> Bool
) async -> Bool {
    for _ in 0..<attempts {
        if await ready() { return true }
        try? await Task.sleep(for: pause)
    }
    return false
}

private func waitForCompletions(_ scheduler: JobScheduler, expected: Int) async -> Bool {
    await waitUntil {
        let done = await scheduler.snapshots.filter { $0.runCount >= 1 }.count
        return done >= expected
    }
}

private func waitForJoin(
    _ scheduler: JobScheduler, id: String = "fixture.refresh", attempts: Int = 1_000
) async {
    for _ in 0..<attempts {
        if await scheduler.joinedRuns[id, default: 0] > 0 { return }
        await Task.yield()
    }
    Issue.record("no second caller joined the run in flight")
}

private actor AdmissionGate {
    private(set) var entered = 0
    private var parked: [CheckedContinuation<Void, Never>] = []
    private var open = false

    func enter() async {
        entered += 1
        if open {
            entered -= 1
            return
        }
        await withCheckedContinuation { parked.append($0) }
        entered -= 1
    }

    func release() {
        open = true
        let waiting = parked
        parked.removeAll()
        for waiter in waiting { waiter.resume() }
    }
}

private actor CollectorGate {
    var executions = 0
    private var started: [CheckedContinuation<Void, Never>] = []
    private var finish: CheckedContinuation<Data?, Never>?

    func run() async -> Data? {
        executions += 1
        if executions > 1 { return Data("result".utf8) }
        for waiter in started { waiter.resume() }
        started.removeAll()
        return await withCheckedContinuation { finish = $0 }
    }

    func waitForStart() async {
        guard executions == 0 else { return }
        await withCheckedContinuation { started.append($0) }
    }

    func release() {
        finish?.resume(returning: Data("result".utf8))
        finish = nil
    }
}

private final class SchedulerOutput: @unchecked Sendable {
    private let lock = NSLock()
    private var topics: [AgentTopic] = []

    func append(_ topic: AgentTopic, _ data: Data) { lock.withLock { topics.append(topic) } }
    func count(topic: AgentTopic) -> Int { lock.withLock { topics.filter { $0 == topic }.count } }
}

private final class MutablePower: AgentPowerSource, @unchecked Sendable {
    private let lock = NSLock()
    private var battery = false
    private var locked = false
    private var constrained = false

    var isOnBattery: Bool { lock.withLock { battery } }
    var isScreenLocked: Bool { lock.withLock { locked } }
    var isConstrained: Bool { lock.withLock { constrained } }

    func set(battery: Bool? = nil, locked: Bool? = nil, constrained: Bool? = nil) {
        lock.withLock {
            if let battery { self.battery = battery }
            if let locked { self.locked = locked }
            if let constrained { self.constrained = constrained }
        }
    }
}

private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.withLock { count } }
    func bump() { lock.withLock { count += 1 } }
}

private final class SchedulerPolicy: @unchecked Sendable {
    private let lock = NSLock()
    private var current = Date()
    private var active = false
    var date: Date { lock.withLock { current } }
    var enabled: Bool { lock.withLock { active } }
    func enable() { lock.withLock { active = true } }
    func advance(_ seconds: TimeInterval) { lock.withLock { current += seconds } }
}

private final class DiagnosticSubscriber: NSObject, EdithAgentSubscriberXPC, @unchecked Sendable {
    private let lock = NSLock()
    private var topics: [String] = []
    func topicChanged(topic: String, payload: Data) { lock.withLock { topics.append(topic) } }
    func count(topic: String) -> Int { lock.withLock { topics.filter { $0 == topic }.count } }
}
