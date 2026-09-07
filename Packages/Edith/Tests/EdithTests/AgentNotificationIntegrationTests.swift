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
        defaults.set(false, forKey: AppStorageKeys.General.smartColor)
        defaults.set(false, forKey: AppStorageKeys.Notify.pacingHot)
        defaults.set(false, forKey: AppStorageKeys.Notify.pacingWarning)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        service = AgentNotificationService(
            url: root.appendingPathComponent("outbox.json"), defaults: defaults, changed: {})
    }

    func close() {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }

    func limits(percent: Double = 95, error: String? = nil) -> LimitsTopicSnapshot {
        LimitsTopicSnapshot(
            refreshedAt: now,
            providers: [
                LimitsProviderSnapshot(
                    provider: .claude,
                    session: error == nil
                        ? LimitWindow(percent: percent, resetsAt: now.addingTimeInterval(7200))
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
        #expect(deliveries.map(\.identifier) == ["limits.escalation_session"])
        #expect(deliveries.first?.notification?.title == "5h almost capped")
    }

    @Test func pendingAlertsSurviveDaemonRestartAndDeduplicateRepeatedSamples() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        try await fixture.service.evaluateLimits(fixture.limits(), now: fixture.now)
        let before = try await fixture.service.pending(now: fixture.now)
        let restarted = AgentNotificationService(
            url: fixture.root.appendingPathComponent("outbox.json"),
            defaults: fixture.defaults, changed: {})
        #expect(try await restarted.pending(now: fixture.now) == before)
        try await restarted.acknowledge(before.map(\.id))
        try await restarted.evaluateLimits(fixture.limits(), now: fixture.now)
        #expect(try await restarted.pending(now: fixture.now).isEmpty)
        try await restarted.evaluateLimits(fixture.limits(percent: 5), now: fixture.now)
        #expect(
            try await restarted.pending(now: fixture.now).map(\.identifier)
                == ["limits.recovery_session"])
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

    @Test func daemonSchedulesAndCancelsResetRemindersWhenSettingsChange() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: AppStorageKeys.Notify.reminderSession)
        try await fixture.service.evaluateLimits(fixture.limits(percent: 5), now: fixture.now)
        let scheduled = try await fixture.service.pending(now: fixture.now)
        let reminder = try #require(scheduled.first { $0.identifier == "reminder_session" })
        #expect(reminder.fireAt == fixture.now.addingTimeInterval(5400))
        try await fixture.service.acknowledge(scheduled.map(\.id))
        try await fixture.service.reconcileSettings(now: fixture.now.addingTimeInterval(5500))
        #expect(
            try await fixture.service.pending(now: fixture.now.addingTimeInterval(5500)).isEmpty)
        fixture.defaults.set(false, forKey: AppStorageKeys.Notify.master)
        let cancelled = try await fixture.service.pending(now: fixture.now)
        #expect(cancelled.map(\.identifier) == ["reminder_session"])
        #expect(cancelled.first?.notification == nil)
    }

    @Test func pendingReminderReplaysAfterItsFireTimeUntilTheReset() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        fixture.defaults.set(true, forKey: AppStorageKeys.Notify.reminderSession)
        try await fixture.service.evaluateLimits(fixture.limits(percent: 5), now: fixture.now)
        let pending = try await fixture.service.pending(now: fixture.now.addingTimeInterval(6000))
        #expect(pending.contains { $0.identifier == "reminder_session" && $0.notification != nil })
        let expired = try await fixture.service.pending(now: fixture.now.addingTimeInterval(7300))
        #expect(!expired.contains { $0.notification != nil })
    }

    @Test func expiredTokenAlertsAreGeneratedAndThrottledByTheCollector() async throws {
        let fixture = try NotificationFixture()
        defer { fixture.close() }
        let snapshot = fixture.limits(error: "Claude session expired - run claude to re-login")
        try await fixture.service.evaluateLimits(snapshot, now: fixture.now)
        let alerts = try await fixture.service.pending(now: fixture.now)
        #expect(alerts.map(\.identifier) == ["limits.token_expired"])
        try await fixture.service.acknowledge(alerts.map(\.id))
        try await fixture.service.evaluateLimits(snapshot, now: fixture.now.addingTimeInterval(100))
        #expect(try await fixture.service.pending(now: fixture.now).isEmpty)
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
                if case .local = scope {} else { Issue.record("Expected local ambient collection") }
                return hosts
            })
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
        let service = AgentNotificationService(
            url: blocker.appendingPathComponent("outbox.json"), defaults: fixture.defaults,
            changed: {})
        await #expect(throws: (any Error).self) {
            try await service.evaluateLimits(fixture.limits(), now: fixture.now)
        }
        try FileManager.default.removeItem(at: blocker)
        try await service.evaluateLimits(fixture.limits(), now: fixture.now)
        #expect(try await service.pending(now: fixture.now).count == 1)
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
