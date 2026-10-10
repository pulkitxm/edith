import EdithExtensionSupport
import Foundation
import Testing
@testable import MachinesExtension

@MainActor @Suite struct MachineHealthAmbientPolicyTests {
    private let job = MachineHealthLifecycle.jobID
    private func monitor(_ probe: AmbientProbe) -> MachineHealthMonitor {
        let machine = Machine(name: "Synthetic", host: "synthetic.invalid")
        return MachineHealthMonitor(
            machines: { [machine] },
            settings: { .init(notifyDown: true, notifyDiskFull: true, diskThreshold: 90) },
            probe: { _, _ in
                await probe.run(); return (.init(reachable: true), [], nil)
            },
            notify: { _ in }, load: { [:] }, save: { _ in })
    }
    @Test func batteryPauseBlocksPeriodicButManualRefreshAndNoLiveExceptionArePreserved()
        async throws
    {
        let clock = AmbientClock(); let probe = AmbientProbe()
        let policy = policy(job, ambient: 300, battery: { true })
        try policy.apply(context: context(job, paused: true, subscribers: 1))
        var reads = 0
        let lifecycle = MachineHealthLifecycle(
            monitor: monitor(probe),
            interval: {
                reads += 1; return policy.interval(for: self.job)
            }, settings: { .init(notifyDown: true, notifyDiskFull: true, diskThreshold: 90) },
            now: { clock.now }, sleep: clock.sleep)
        try policy.start { lifecycle.reschedule() }; lifecycle.start()
        try await clock.settle { reads > 0 }
        #expect(await probe.count == 0)
        #expect(clock.requested.isEmpty)
        _ = await lifecycle.refresh()
        #expect(await probe.count == 1)
        try policy.apply(context: context(job, paused: false))
        try await clock.settle { clock.waiterCount == 1 }
        #expect(clock.requested.last == .seconds(300))
        clock.fire()
        try await clock.settle { lifecycle.latest != nil && clock.requested.count == 2 }
        #expect(await probe.count == 2)
        policy.stop(); await lifecycle.stop()
        #expect(clock.waiterCount == 0)
    }
    @Test func reschedulingRetainsAdmittedProbeAndDisableDrainsTheTimer() async throws {
        let clock = AmbientClock(); let probe = AmbientProbe(); await probe.setHold(true)
        let policy = policy(job, ambient: 300, battery: { true })
        try policy.apply(context: context(job, paused: false))
        let lifecycle = MachineHealthLifecycle(
            monitor: monitor(probe), interval: { policy.interval(for: self.job) },
            settings: { .init(notifyDown: true, notifyDiskFull: true, diskThreshold: 90) },
            now: { clock.now }, sleep: clock.sleep)
        try policy.start { lifecycle.reschedule() }; lifecycle.start()
        try await probe.awaitFirst()
        try policy.apply(context: context(job, paused: true))
        await probe.release()
        try await clock.settle { lifecycle.latest != nil }
        #expect(await probe.cancelled == false)
        #expect(await probe.count == 1)
        policy.stop(); await lifecycle.stop()
        lifecycle.start()
        _ = await lifecycle.refresh()
        #expect(await probe.count == 1)
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
