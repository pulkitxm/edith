import EdithExtensionSupport
import Foundation
import Testing
@testable import CompanionExtension

@MainActor @Suite struct CompanionAmbientPolicyTests {
    private let job = CompanionMonitor.jobID
    private func monitor(
        _ probe: AmbientProbe, clock: AmbientClock, policy: ExtensionAmbientPolicy, directory: URL
    ) -> CompanionMonitor {
        let health = CompanionHealthJob(
            isConfigured: { true }, endpoint: { URL(string: "http://synthetic.invalid")! },
            probe: { _ in
                await probe.run(); return .init(ok: true, checks: [])
            }, repair: { _ in false }, deliverOutbox: { _ in })
        let delivery = CompanionOutboxDelivery(
            directory: directory, send: { _, _, _ in "synthetic" }, notify: {})
        return CompanionMonitor(
            job: health, delivery: delivery, interval: { policy.interval(for: self.job) },
            now: { clock.now }, sleep: clock.sleep)
    }
    @Test func batteryPauseUsesOnlyTrustedLiveCountsAndManualHealthStillRuns() async throws {
        let clock = AmbientClock(); let probe = AmbientProbe()
        let policy = policy(job, ambient: 60, live: 20, battery: { true })
        try policy.apply(context: context(job, paused: true))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            UUID().uuidString)
        let monitor = monitor(probe, clock: clock, policy: policy, directory: directory)
        try policy.start { monitor.reschedule() }; monitor.start()
        _ = await monitor.refresh()
        #expect(await probe.count == 1)
        #expect(clock.requested.isEmpty)
        try policy.apply(context: context(job, paused: true, subscribers: 1))
        try await clock.settle { clock.waiterCount == 1 }
        #expect(clock.requested.last == .seconds(20))
        #expect(await probe.count == 2)
        let oldWaits = clock.requested.count
        try policy.apply(context: context(job, paused: true))
        try await clock.settle { clock.waiterCount == 0 }
        #expect(clock.requested.count == oldWaits)
        try policy.apply(context: context(job, paused: false))
        try await clock.settle { clock.waiterCount == 1 }
        #expect(clock.requested.last == .seconds(60))
        policy.stop(); await monitor.stop()
        #expect(clock.waiterCount == 0)
    }
    @Test func losingLiveDemandDoesNotCancelAnAdmittedHealthCheck() async throws {
        let clock = AmbientClock(); let probe = AmbientProbe(); await probe.setHold(true)
        let policy = policy(job, ambient: 60, live: 20, battery: { true })
        try policy.apply(context: context(job, paused: true, subscribers: 1))
        let monitor = monitor(
            probe, clock: clock, policy: policy,
            directory: FileManager.default.temporaryDirectory.appendingPathComponent(
                UUID().uuidString))
        try policy.start { monitor.reschedule() }; monitor.start()
        try await probe.awaitFirst()
        try policy.apply(context: context(job, paused: true))
        await probe.release()
        try await clock.settle { monitor.latest != nil }
        #expect(await probe.cancelled == false)
        #expect(await probe.count == 1)
        policy.stop(); await monitor.stop()
        monitor.start()
        #expect(monitor.isRunning == false)
    }

    @Test func policyOnlySynchronizationDoesNotWakeSettingsWork() {
        var wakes = 0
        let runtime = ExtensionRuntime(settingsChanged: { wakes += 1 })
        for paused in [false, true, true, false] {
            let input =
                context(CompanionMonitor.jobID, paused: paused).mutableCopy()
                as! NSMutableDictionary
            input["operation"] = "synchronize"
            input["ambientPolicyOnly"] = true
            #expect((runtime.execute(input) as? NSDictionary)?["ok"] as? Bool == true)
        }
        #expect(wakes == 0)
        for paused in [false, true, true, false] {
            let input =
                context(CompanionMonitor.jobID, paused: paused).mutableCopy()
                as! NSMutableDictionary
            input["operation"] = "synchronize"
            #expect((runtime.execute(input) as? NSDictionary)?["ok"] as? Bool == true)
        }
        #expect(wakes == 4)
        #expect(
            (runtime.execute(["operation": "synchronize"]) as? NSDictionary)?["ok"] as? Bool
                == false)
        #expect(wakes == 4)
    }

    @Test func unusedCaptureShutdownDoesNotAllocateAudioResources() {
        enum UnexpectedAllocation: Error { case audio }
        var allocations = 0
        let model = CompanionCaptureModel(
            recordingFactory: {
                allocations += 1
                throw UnexpectedAllocation.audio
            }, observeOutbox: false)
        model.setCaptureActive(false)
        model.shutdown()
        model.shutdown()
        #expect(allocations == 0)
        #expect(model.phase == .idle)
    }

    private func policy(
        _ job: String, ambient: Double, live: Double? = nil,
        battery: @escaping @MainActor () -> Bool
    ) -> ExtensionAmbientPolicy {
        ExtensionAmbientPolicy(
            jobs: [job: .init(ambient: ambient, live: live)],
            onBattery: battery, constrained: { false },
            notificationCenter: NotificationCenter(), observeBatteryChanges: { _ in {} })
    }
    private func context(_ job: String, paused: Bool, subscribers: Int = 0) -> NSDictionary {
        ["ambientPolicy": ["pauseAmbientOnBattery": paused, "subscribers": [job: subscribers]]]
    }
}

@MainActor private final class AmbientClock {
    var now = Date(timeIntervalSince1970: 10_000)
    var requested: [Duration] = []
    private var waiting: [(UUID, Duration, CheckedContinuation<Void, Error>)] = []
    var waiterCount: Int { waiting.count }
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                requested.append(duration)
                waiting.append((id, duration, continuation))
            }
        } onCancel: {
            Task { @MainActor in
                if let index = self.waiting.firstIndex(where: { $0.0 == id }) {
                    self.waiting.remove(at: index).2.resume(throwing: CancellationError())
                }
            }
        }
    }
    func fire() {
        let (_, duration, continuation) = waiting.removeFirst()
        let components = duration.components
        now.addTimeInterval(Double(components.seconds) + Double(components.attoseconds) / 1e18)
        continuation.resume()
    }
    func settle(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while !condition() {
            guard ContinuousClock.now < deadline else { throw AmbientTestError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}
private enum AmbientTestError: Error { case timeout }
private actor AmbientProbe {
    private(set) var count = 0
    private(set) var cancelled = false
    var hold = false
    private var continuation: CheckedContinuation<Void, Never>?
    func setHold(_ value: Bool) { hold = value }
    func awaitFirst() async throws {
        let deadline = ContinuousClock.now + .seconds(5)
        while count == 0 {
            guard ContinuousClock.now < deadline else { throw AmbientTestError.timeout }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
    func run() async {
        count += 1
        if hold { await withCheckedContinuation { continuation = $0 } }
        cancelled = Task.isCancelled
    }
    func release() { continuation?.resume(); continuation = nil; hold = false }
}
