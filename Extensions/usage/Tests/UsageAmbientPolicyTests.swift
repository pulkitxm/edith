import EdithExtensionSupport
import Foundation
import Testing

@testable import UsageExtension

@MainActor @Suite(.serialized)
struct UsageAmbientPolicyTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func policyOnlySynchronizationDoesNotPerformExplicitSettingsWork() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        var explicitCalls = 0
        let context = NSMutableDictionary(
            dictionary: Fixture.context(paused: true) as! [AnyHashable: Any])
        context["ambientPolicyOnly"] = true
        try fixture.controller.synchronizeAmbientPolicy(context: context) { explicitCalls += 1 }
        #expect(explicitCalls == 0)
        #expect(fixture.controller.nextPeriodicDelay(now: now) == nil)
        #expect(await fixture.counts.snapshot() == [0, 0])
        context["ambientPolicyOnly"] = false
        try fixture.controller.synchronizeAmbientPolicy(context: context) { explicitCalls += 1 }
        context.removeObject(forKey: "ambientPolicyOnly")
        try fixture.controller.synchronizeAmbientPolicy(context: context) { explicitCalls += 1 }
        #expect(explicitCalls == 2)
        context["ambientPolicyOnly"] = 1
        #expect(throws: (any Error).self) {
            try fixture.controller.synchronizeAmbientPolicy(context: context) { explicitCalls += 1 }
        }
        #expect(explicitCalls == 2)
        #expect(fixture.controller.nextPeriodicDelay(now: now) == nil)
        await fixture.controller.shutdown()
    }

    @Test func batteryPauseBlocksPeriodicWorkButNotExplicitRefreshes() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.apply(paused: true)
        try fixture.controller.requestPeriodicCollection(now: now)
        #expect(await fixture.counts.snapshot() == [0, 0])
        #expect(fixture.controller.nextPeriodicDelay(now: now) == nil)
        _ = try fixture.controller.requestRefresh()
        try fixture.controller.requestLimitsRefresh()
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [1, 1])
        await fixture.controller.shutdown()
    }

    @Test func onlyOwnedLimitsDemandBypassesPauseAndReleasesWithoutStartingUsage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.apply(paused: true, refresh: 128, limits: 1)
        try fixture.controller.requestPeriodicCollection(now: now)
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [0, 1])
        #expect(fixture.controller.nextPeriodicDelay(now: now) == 300)
        try fixture.controller.requestPeriodicCollection(now: now.addingTimeInterval(299))
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [0, 1])
        try fixture.controller.requestPeriodicCollection(now: now.addingTimeInterval(300))
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [0, 2])
        try fixture.apply(paused: true)
        try fixture.controller.requestPeriodicCollection(now: now.addingTimeInterval(900))
        #expect(fixture.controller.nextPeriodicDelay(now: now) == nil)
        #expect(await fixture.counts.snapshot() == [0, 2])
        await fixture.controller.shutdown()
    }

    @Test func defaultAndOffBatteryCadencesRemainNineHundredSeconds() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        try fixture.controller.requestPeriodicCollection(now: now)
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [1, 1])
        #expect(fixture.controller.nextPeriodicDelay(now: now) == 900)
        try fixture.apply(paused: true)
        fixture.power.onBattery = false
        try fixture.controller.requestPeriodicCollection(now: now.addingTimeInterval(899))
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [1, 1])
        try fixture.controller.requestPeriodicCollection(now: now.addingTimeInterval(900))
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [2, 2])
        await fixture.controller.shutdown()
    }

    @Test func constrainedAmbientCadenceAndMalformedUpdatesDoNotWeakenAdmission() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        fixture.power.constrained = true
        try fixture.controller.requestPeriodicCollection(now: now)
        await fixture.drain()
        #expect(fixture.controller.nextPeriodicDelay(now: now) == 2700)
        try fixture.apply(paused: true)
        #expect(throws: (any Error).self) {
            try fixture.controller.applyAmbientPolicy(context: [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": false,
                    "subscribers": ["usage.refresh": 0, "usage.limits": true],
                ]
            ])
        }
        #expect(fixture.controller.nextPeriodicDelay(now: now) == nil)
        await fixture.controller.shutdown()
    }

    @Test func policyChangesRetainInFlightWorkAndStopRejectsFutureAdmissions() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let policy = ExtensionAmbientPolicy(
            jobs: Fixture.jobs, onBattery: { true }, constrained: { false },
            notificationCenter: NotificationCenter(), observeBatteryChanges: { _ in {} })
        let gate = CollectionGate()
        let controller = UsageWorkerController(
            dataDirectory: root,
            fetchLimits: { _ in .init(refreshedAt: Date(), providers: [], failure: nil) },
            ambientPolicy: policy
        ) { _, _ in
            await gate.wait()
            try Task.checkCancellation()
            return try usageDocument()
        }
        try controller.requestPeriodicCollection(now: now)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await gate.started) {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        try controller.applyAmbientPolicy(context: Fixture.context(paused: true))
        #expect(controller.refreshing)
        await gate.release()
        await controller.waitForRefresh()
        #expect(controller.failure == nil)
        #expect(
            FileManager.default.fileExists(atPath: root.appendingPathComponent("usage.json").path))
        await controller.shutdown()
        #expect(throws: (any Error).self) { try controller.requestPeriodicCollection(now: now) }
        #expect(throws: (any Error).self) {
            try controller.applyAmbientPolicy(context: Fixture.context(paused: false))
        }
    }

    @Test func policyChangeReschedulesOnlyTheOwnedSleeperAndShutdownDrainsIt() async throws {
        let sleep = UsageRecordedSleep()
        let fixture = try Fixture(sleep: { try await sleep.wait($0) })
        defer { fixture.remove() }
        try fixture.apply(paused: true)
        fixture.controller.startBackgroundCollection()
        #expect(await fixture.counts.snapshot() == [0, 0])
        try fixture.apply(paused: false)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while await sleep.count == 0 {
            try #require(ContinuousClock.now < deadline)
            await Task.yield()
        }
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [1, 1])
        #expect(await sleep.duration == .seconds(900))
        await fixture.controller.shutdown()
        #expect(await sleep.cancelled)
        #expect(fixture.controller.nextPeriodicDelay(now: now) == nil)
    }

    @Test func failedPowerObservationReportsFailureWithoutStartingAutomaticWork() async throws {
        let fixture = try Fixture(observe: { _ in throw CocoaError(.featureUnsupported) })
        defer { fixture.remove() }
        fixture.controller.startBackgroundCollection()
        #expect(fixture.controller.failure != nil)
        #expect(await fixture.counts.snapshot() == [0, 0])
        _ = try fixture.controller.requestRefresh()
        await fixture.drain()
        #expect(await fixture.counts.snapshot() == [1, 0])
        await fixture.controller.shutdown()
    }

    @MainActor private final class Power {
        var onBattery = true
        var constrained = false
    }

    @MainActor private struct Fixture {
        static let jobs = [
            "usage.refresh": ExtensionAmbientCadence(ambient: 900),
            "usage.limits": ExtensionAmbientCadence(ambient: 900, live: 300),
        ]
        let root: URL
        let counts: InvocationCounts
        let power: Power
        let controller: UsageWorkerController

        init(
            sleep: @escaping @Sendable (Duration) async throws -> Void = {
                try await Task.sleep(for: $0)
            },
            observe: @escaping ExtensionAmbientPolicy.BatteryObservation = { _ in {} }
        ) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            counts = InvocationCounts()
            power = Power()
            let power = power, counts = counts
            controller = UsageWorkerController(
                dataDirectory: root,
                fetchLimits: { _ in
                    await counts.limits()
                    return .init(refreshedAt: Date(), providers: [], failure: nil)
                },
                ambientPolicy: ExtensionAmbientPolicy(
                    jobs: Self.jobs, onBattery: { power.onBattery },
                    constrained: { power.constrained }, notificationCenter: NotificationCenter(),
                    observeBatteryChanges: observe),
                allowsBackgroundCollection: { true },
                clock: { Date(timeIntervalSince1970: 1_800_000_000) }, sleep: sleep
            ) { _, _ in
                await counts.usage()
                return try usageDocument()
            }
        }

        static func context(paused: Bool, refresh: Int = 0, limits: Int = 0) -> NSDictionary {
            [
                "ambientPolicy": [
                    "pauseAmbientOnBattery": paused,
                    "subscribers": ["usage.refresh": refresh, "usage.limits": limits],
                ]
            ]
        }

        func apply(paused: Bool, refresh: Int = 0, limits: Int = 0) throws {
            try controller.applyAmbientPolicy(
                context: Self.context(paused: paused, refresh: refresh, limits: limits))
        }

        func drain() async {
            await controller.waitForRefresh()
            try? await controller.waitForLimitsRefresh()
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }
}

private actor InvocationCounts {
    private var usageCount = 0
    private var limitsCount = 0
    func usage() { usageCount += 1 }
    func limits() { limitsCount += 1 }
    func snapshot() -> [Int] { [usageCount, limitsCount] }
}

private actor CollectionGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var started = false
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}

private func usageDocument() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "schemaVersion": 8, "generatedAt": "2026-10-09T12:00:00Z", "sources": [],
        "defaultSources": [], "sourceMeta": [:], "sessions": [], "daily": [], "pricing": [:],
        "totals": [
            "cost": 0, "tokens": 0, "inputTokens": 0, "outputTokens": 0,
            "cacheCreationTokens": 0, "cacheReadTokens": 0, "bySource": [:],
        ],
    ])
}

private actor UsageRecordedSleep {
    private(set) var count = 0
    private(set) var duration: Duration?
    private(set) var cancelled = false
    func wait(_ duration: Duration) async throws {
        count += 1
        self.duration = duration
        do { try await Task.sleep(for: .seconds(30)) } catch {
            cancelled = Task.isCancelled
            throw error
        }
    }
}
