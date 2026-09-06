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
        await scheduler.enqueue("fixture.refresh")
        #expect(await scheduler.snapshots.first?.phase == .running)
        await gate.release()
        #expect(await first.value == Data("result".utf8))
        #expect(await second.value == Data("result".utf8))
        #expect(await gate.executions == 1)
        #expect(await scheduler.snapshots.first?.runCount == 1)
        #expect(output.count(topic: .usage) == 1)
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

    @Test func filesystemEnqueueHonorsTheAmbientCadenceAfterACompletedRun() async {
        let policy = SchedulerPolicy()
        let scheduler = JobScheduler(clock: { policy.date })
        await scheduler.register(
            AgentJob(descriptor: descriptor(cadence: .every(ambient: 900))) {
                Data("done".utf8)
            })
        await scheduler.start()
        _ = await scheduler.runNow("fixture.refresh")

        #expect(await !scheduler.enqueueIfDue("fixture.refresh"))
        policy.advance(899)
        #expect(await !scheduler.enqueueIfDue("fixture.refresh"))
        policy.advance(2)
        #expect(await scheduler.enqueueIfDue("fixture.refresh"))
        _ = await scheduler.enqueueIfDue("fixture.refresh")
        _ = await scheduler.enqueueIfDue("fixture.refresh")
        for _ in 0..<1_000 {
            let snapshot = await scheduler.snapshots.first
            if snapshot?.runCount == 2, snapshot?.phase == .idle { break }
            await Task.yield()
        }

        #expect(await scheduler.snapshots.first?.runCount == 2)
        await scheduler.stop()
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

    private func descriptor(cadence: AgentCadence = .onDemand) -> AgentJobDescriptor {
        AgentJobDescriptor(
            id: "fixture.refresh", title: "Fixture", trigger: .timer, topic: .usage,
            cadence: cadence)
    }
}

private actor CollectorGate {
    var executions = 0
    private var started: [CheckedContinuation<Void, Never>] = []
    private var finish: CheckedContinuation<Data?, Never>?

    func run() async -> Data? {
        executions += 1
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
