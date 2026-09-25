import Foundation
import Testing

@testable import EdithAgent
@testable import EdithHelper
@testable import EdithKit

private final class NotificationDeliveryProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var accepted: [UUID] = []

    func record(_ ids: [UUID]) {
        lock.lock()
        defer { lock.unlock() }
        accepted.append(contentsOf: ids)
    }

    var ids: [UUID] {
        lock.lock()
        defer { lock.unlock() }
        return accepted
    }
}

private struct NotificationFixture {
    let root: URL
    let suite: String
    let defaults: UserDefaults
    let service: AgentNotificationService
    let now = Date(timeIntervalSince1970: 1_800_000_000)

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("NotificationIntegration.\(UUID().uuidString)")
        suite = "NotificationIntegration.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)!
        defaults.set(true, forKey: AppStorageKeys.Notify.master)
        defaults.set(true, forKey: AppStorageKeys.Tabs.usageEnabled)
        defaults.set(true, forKey: AppStorageKeys.Tabs.herdrEnabled)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = Self.service(root: root, defaults: defaults)
    }

    static func service(
        root: URL, defaults: UserDefaults,
        history: @escaping AgentNotificationService.HistoryLoader = { _ in [:] },
        jev: @escaping AgentNotificationService.JevResolver = { nil }
    ) -> AgentNotificationService {
        AgentNotificationService(
            url: root.appendingPathComponent("outbox.json"), defaults: defaults, changed: {},
            history: history, jev: jev, clock: { LimitAlertScenario.clock($0) },
            attention: AgentAttention(
                inspect: { _ in [:] }, decider: { nil }, appIsRunning: { false },
                openAgent: { _ in }))
    }

    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func limits(
        percent: Double = 95, error: String? = nil, resetsAt: Date? = nil
    ) -> LimitsTopicSnapshot {
        LimitsTopicSnapshot(
            refreshedAt: now,
            providers: [
                LimitsProviderSnapshot(
                    provider: .claude,
                    session: error == nil
                        ? LimitWindow(
                            percent: percent, resetsAt: resetsAt ?? now.addingTimeInterval(7200))
                        : nil,
                    week: nil, error: error)
            ], failure: error)
    }

    func host(status: HerdrAgentStatus, reachable: Bool = true) -> HerdrHostSnapshot {
        HerdrHostSnapshot(
            id: "local", name: "This Mac", isLocal: true,
            herdrPresent: true, reachable: reachable,
            agents: [
                HerdrAgent(
                    id: "local|session|pane", machineID: "local", machineName: "This Mac",
                    machineIsLocal: true, sshTarget: nil, session: "session", pane: "pane",
                    kind: "agent", status: status, title: "Build", workspace: "repo", cwd: "/tmp")
            ])
    }
}

@Suite struct AgentNotificationIntegrationTests {
    @Test func limitCollectionPersistsNotificationWithoutTheHelper() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let snapshot = fixture.limits()
        let job = LimitsCollectorJob(
            notify: { try await fixture.service.evaluateLimits($0, now: fixture.now) },
            refresh: { snapshot })

        let result = try #require(try await job.run())
        #expect(try AgentPayload.decode(LimitsTopicSnapshot.self, from: result) == snapshot)
        let deliveries = try await fixture.service.pending(now: fixture.now)
        #expect(
            deliveries.map(\.identifier)
                == ["limits.almost_capped.claude.session", "limits.back.claude.session"])
        #expect(deliveries.first?.notification?.title == "Claude 5h at 95%")
        #expect(deliveries.last?.fireAt == fixture.now.addingTimeInterval(7200))
    }

    @Test func pendingAlertsSurviveDaemonRestartAndOnlyARealResetBringsThemBack() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        try await fixture.service.evaluateLimits(fixture.limits(), now: fixture.now)
        let before = try await fixture.service.pending(now: fixture.now)
        let restarted = NotificationFixture.service(root: fixture.root, defaults: fixture.defaults)
        #expect(try await restarted.pending(now: fixture.now) == before)
        try await restarted.acknowledge(before.map(\.id))
        try await restarted.evaluateLimits(fixture.limits(), now: fixture.now)
        #expect(try await restarted.pending(now: fixture.now).isEmpty)
        for minute in 1...30 {
            let later = fixture.now.addingTimeInterval(Double(minute) * 60)
            #expect(try await restarted.pending(now: later).isEmpty)
        }
        try await restarted.evaluateLimits(fixture.limits(percent: 5), now: fixture.now)
        #expect(try await restarted.pending(now: fixture.now).isEmpty)
        let fresh = fixture.limits(percent: 5, resetsAt: fixture.now.addingTimeInterval(5 * 3600))
        try await restarted.evaluateLimits(fresh, now: fixture.now)
        let back = try await restarted.pending(now: fixture.now)
        #expect(back.map(\.identifier) == ["limits.back.claude.session"])
        #expect(back.first?.fireAt == nil)
        #expect(back.first?.notification?.body.contains("reset early") == true)
    }

    @Test func staleAcknowledgementCannotDeleteAReplacement() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let first = AgentNotification(identifier: "machine", title: "Offline", body: "Lost contact")
        try await fixture.service.enqueue(first, now: fixture.now)
        let before = try await fixture.service.pending(now: fixture.now)
        try await fixture.service.enqueue(
            AgentNotification(identifier: "machine", title: "Online", body: "Connected"),
            now: fixture.now)
        try await fixture.service.acknowledge(before.map(\.id))
        let after = try await fixture.service.pending(now: fixture.now)
        #expect(after.first?.notification?.title == "Online")
        #expect(after.first?.id != before.first?.id)
    }

    @Test func togglingAnAlertOffPurgesQueuedAndScheduledDeliveries() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        try await fixture.service.evaluateLimits(fixture.limits(), now: fixture.now)
        let queued = try await fixture.service.pending(now: fixture.now)
        #expect(queued.count == 2)
        try await fixture.service.acknowledge(
            queued.filter { $0.fireAt != nil }.map(\.id))
        fixture.defaults.set(false, forKey: AppStorageKeys.Notify.almostCapped)
        let purged = try await fixture.service.pending(now: fixture.now)
        #expect(purged.isEmpty)
        fixture.defaults.set(false, forKey: AppStorageKeys.Notify.back)
        let cancelled = try await fixture.service.pending(now: fixture.now)
        #expect(cancelled.map(\.identifier) == ["limits.back.claude.session"])
        #expect(cancelled.first?.notification == nil)
    }

    @Test func loginProblemsNotifyOnceUntilTheProviderRecovers() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let snapshot = fixture.limits(error: "Claude session expired - run claude to re-login")
        try await fixture.service.evaluateLimits(snapshot, now: fixture.now)
        let alerts = try await fixture.service.pending(now: fixture.now)
        #expect(alerts.map(\.identifier) == ["limits.login.claude"])
        #expect(alerts.first?.notification?.title == "Claude session expired")
        try await fixture.service.acknowledge(alerts.map(\.id))
        for hour in 1...6 {
            try await fixture.service.evaluateLimits(
                snapshot, now: fixture.now.addingTimeInterval(Double(hour) * 3600))
        }
        #expect(try await fixture.service.pending(now: fixture.now).isEmpty)
        try await fixture.service.evaluateLimits(fixture.limits(percent: 10), now: fixture.now)
        try await fixture.service.evaluateLimits(snapshot, now: fixture.now)
        #expect(
            try await fixture.service.pending(now: fixture.now).map(\.identifier)
                == ["limits.login.claude"])
    }

    @Test func jevOnlyHoldsBackNonCriticalAlerts() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let probe = LimitAlertJevProbe(score: 0.1)
        let reset = fixture.now.addingTimeInterval(3 * 3600)
        let windowStart = reset.addingTimeInterval(-5 * 3600)
        let history = LimitAlertScenario.samples(reset, from: windowStart, to: fixture.now) {
            30 * $0.timeIntervalSince(windowStart) / 3600
        }
        let target = LimitAlertTarget(.claude, .session)
        let service = NotificationFixture.service(
            root: fixture.root, defaults: fixture.defaults, history: { _ in [target: history] },
            jev: { probe })
        try await service.evaluateLimits(
            fixture.limits(percent: 60, resetsAt: reset), now: fixture.now)
        #expect(probe.calls == 1)
        #expect(try await service.pending(now: fixture.now).isEmpty)
        try await service.evaluateLimits(
            fixture.limits(percent: 100, resetsAt: reset), now: fixture.now.addingTimeInterval(300))
        #expect(probe.calls == 1)
        let capped = try await service.pending(now: fixture.now)
        #expect(capped.map(\.identifier).contains("limits.capped.claude.session"))
    }

    @Test func noJevKeyMeansNoJevCalls() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let factory = LimitAlertClientCounter()
        let engine = JevEngine(
            store: LimitAlertEmptyKeyStore(),
            makeClient: { key in
                factory.record()
                return JevClient(apiKey: key)
            })
        let reset = fixture.now.addingTimeInterval(3 * 3600)
        let windowStart = reset.addingTimeInterval(-5 * 3600)
        let history = LimitAlertScenario.samples(reset, from: windowStart, to: fixture.now) {
            30 * $0.timeIntervalSince(windowStart) / 3600
        }
        let target = LimitAlertTarget(.claude, .session)
        let service = NotificationFixture.service(
            root: fixture.root, defaults: fixture.defaults, history: { _ in [target: history] },
            jev: { await AgentNotificationService.decider(engine) })
        try await service.evaluateLimits(
            fixture.limits(percent: 60, resetsAt: reset), now: fixture.now)
        let delivered = try await service.pending(now: fixture.now)
        #expect(delivered.map(\.identifier) == ["limits.on_pace.claude.session"])
        #expect(factory.count == 0)
        #expect(await engine.status(probe: false).decisions == 0)
    }

    @Test func blockedSessionsAreDiscoveredWithoutASubscriber() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: AgentSettingsKeys.notifyWhenBlocked)
        let hosts = [fixture.host(status: .blocked)]
        let job = SessionsJob(
            store: nil, isSubscribed: { false }, defaults: fixture.defaults,
            notify: { try await fixture.service.evaluateSessions($0, now: fixture.now) },
            collect: { scope in
                if case .machine = scope { Issue.record("Expected an ambient collection") }
                return hosts
            }, now: { fixture.now })
        #expect(try await job.run() != nil)
        let deliveries = try await fixture.service.pending(now: fixture.now)
        #expect(deliveries.map(\.identifier) == ["session.blocked.local|session|pane"])
        let descriptor = try #require(
            AgentJobPlan.descriptors.first { $0.id == "sessions.discover" })
        #expect(descriptor.cadence.ambient == 30)
    }

    @Test func blockedTransitionsDeduplicateAcrossFailuresAndAllowASecondBlock() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: AgentSettingsKeys.notifyWhenBlocked)
        try await fixture.service.evaluateSessions(
            [fixture.host(status: .blocked)], now: fixture.now)
        let first = try await fixture.service.pending(now: fixture.now)
        try await fixture.service.acknowledge(first.map(\.id))
        try await fixture.service.evaluateSessions(
            [fixture.host(status: .idle, reachable: false)], now: fixture.now)
        try await fixture.service.evaluateSessions(
            [fixture.host(status: .blocked)], now: fixture.now)
        #expect(try await fixture.service.pending(now: fixture.now).isEmpty)
        try await fixture.service.evaluateSessions(
            [fixture.host(status: .working)], now: fixture.now)
        try await fixture.service.evaluateSessions(
            [fixture.host(status: .blocked)], now: fixture.now)
        #expect(try await fixture.service.pending(now: fixture.now).count == 1)
        fixture.defaults.set(false, forKey: AgentSettingsKeys.notifyWhenBlocked)
        #expect(try await fixture.service.pending(now: fixture.now).isEmpty)
    }

    @Test func notificationPersistenceFailureLeavesTheDecisionRetryable() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let blocker = fixture.root.appendingPathComponent("blocked")
        try Data().write(to: blocker)
        let service = NotificationFixture.service(root: blocker, defaults: fixture.defaults)
        await #expect(throws: (any Error).self) {
            try await service.evaluateLimits(fixture.limits(), now: fixture.now)
        }
        try FileManager.default.removeItem(at: blocker)
        try await service.evaluateLimits(fixture.limits(), now: fixture.now)
        #expect(
            try await service.pending(now: fixture.now).map(\.identifier).contains(
                "limits.almost_capped.claude.session"))
    }

    @Test func helperAcknowledgesOnlySuccessfulPresentation() async throws {
        let good = AgentNotificationDelivery(
            identifier: "accepted",
            notification: AgentNotification(identifier: "accepted", title: "Ready", body: "Done"))
        let failed = AgentNotificationDelivery(
            identifier: "retry",
            notification: AgentNotification(identifier: "retry", title: "Ready", body: "Done"))
        let probe = NotificationDeliveryProbe()
        let success = await AgentNotificationDeliveryWorker.deliverPending(
            load: { [good, failed] },
            present: { delivery in
                if delivery.id == failed.id { throw CocoaError(.userCancelled) }
            }, acknowledge: { probe.record($0) })
        #expect(!success)
        #expect(probe.ids == [good.id])
    }

    @Test func registeredNotificationOperationsReplayAndAcknowledgeDurableWork() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let runtime = AgentRuntime(build: "test", store: nil)
        await AgentNotificationOperations.register(on: runtime, service: fixture.service)
        try await fixture.service.enqueue(
            AgentNotification(identifier: "integration", title: "Ready", body: "Done"))
        let payload = try await runtime.perform(
            operation: AgentNotificationOperation.pending, payload: Data())
        let deliveries = try AgentPayload.decode([AgentNotificationDelivery].self, from: payload)
        #expect(deliveries.map(\.identifier) == ["integration"])
        _ = try await runtime.perform(
            operation: AgentNotificationOperation.acknowledge,
            payload: AgentPayload.encode(deliveries.map(\.id)))
        let empty = try await runtime.perform(
            operation: AgentNotificationOperation.pending, payload: Data())
        #expect(try AgentPayload.decode([AgentNotificationDelivery].self, from: empty).isEmpty)
    }
}

private final class LimitAlertClientCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var made = 0

    func record() { lock.withLock { made += 1 } }
    var count: Int { lock.withLock { made } }
}

private struct LimitAlertEmptyKeyStore: JevKeyStore {
    func read() -> JevKeyRead { .missing }
    func write(_ key: String?) -> Bool { true }
}
