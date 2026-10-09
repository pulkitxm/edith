import EdithExtensionSupport
import Foundation
import Testing
@testable import UsageExtension

@Suite struct UsageLimitAlertServiceTests {
    actor Delivered {
        var alerts: [LimitAlert] = []
        var attempts = 0
        let failsFirst: Bool
        init(failsFirst: Bool = false) { self.failsFirst = failsFirst }
        func send(_ alerts: [LimitAlert], _ scheduled: [LimitAlert]) throws {
            attempts += 1
            if failsFirst && attempts == 1 { throw CocoaError(.fileWriteUnknown) }
            self.alerts += alerts
        }
    }

    @Test func deliveryDeduplicatesPerWindowAndPersistsOnlySuccessfulNotifications() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "usage-alert-fixture-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(true, forKey: AppStorageKeys.Notify.master)
        let delivered = Delivered(failsFirst: true)
        let url = root.appendingPathComponent("notifications.json")
        let service = UsageLimitAlerts(
            url: url, defaults: defaults, historyURL: root.appendingPathComponent("history"),
            delivery: { try await delivered.send($0, $1) }, jev: { nil })
        let now = Date()
        let snapshot = LimitsTopicSnapshot(
            refreshedAt: now,
            providers: [
                .init(
                    provider: .codex,
                    session: .init(percent: 100, resetsAt: now.addingTimeInterval(3_600)), week: nil
                )
            ], failure: nil)
        await #expect(throws: CocoaError.self) { try await service.evaluate(snapshot, now: now) }
        #expect(!FileManager.default.fileExists(atPath: url.path))
        try await service.evaluate(snapshot, now: now)
        let count = await delivered.alerts.count
        #expect(count > 0)
        try await service.evaluate(snapshot, now: now)
        #expect(await delivered.alerts.count == count)
        #expect(LimitAlertLedger.load(from: url) != nil)
        await service.shutdown()
        await #expect(throws: CancellationError.self) {
            try await service.evaluate(snapshot, now: now)
        }
    }

    @Test func cancelledEvaluationNeverSchedulesOrPublishesAnAlert() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let delivered = Delivered()
        let service = UsageLimitAlerts(
            url: root.appendingPathComponent("notifications.json"),
            historyURL: root.appendingPathComponent("history"),
            delivery: { try await delivered.send($0, $1) }, jev: { nil })
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await service.evaluate(.init(refreshedAt: Date(), providers: [], failure: nil))
        }
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(await delivered.attempts == 0)
        await service.shutdown()
    }
}
