import EdithExtensionSupport
import Foundation
import Testing
@testable import CodeStatsExtension

@MainActor @Suite struct CodeStatsAmbientPolicyTests {
    private let job = CodeStatsScheduleLifecycle.jobID
    @Test func pausedPeriodicChecksResumeAtOriginalCadenceWithoutLiveException() async throws {
        let clock = AmbientClock(); var checks = 0; var reads = 0
        let policy = policy(job, ambient: 600, battery: { true })
        try policy.apply(context: context(job, paused: true, subscribers: 1))
        let lifecycle = CodeStatsScheduleLifecycle(
            interval: {
                reads += 1; return policy.interval(for: self.job)
            }, check: { checks += 1 }, now: { clock.now }, sleep: clock.sleep)
        try policy.start { lifecycle.reschedule() }; lifecycle.start()
        try await clock.settle { reads > 0 }
        #expect(checks == 0 && clock.requested.isEmpty)
        try policy.apply(context: context(job, paused: false))
        try await clock.settle { clock.waiterCount == 1 }
        #expect(checks == 1 && clock.requested.last == .seconds(600))
        clock.fire()
        try await clock.settle { checks == 2 && clock.waiterCount == 1 }
        policy.stop(); await lifecycle.shutdown()
        #expect(clock.waiterCount == 0)
        lifecycle.start()
        #expect(checks == 2)
    }
    @Test func policyChangeDoesNotCancelScheduledWorkAndExplicitCheckIsIndependent() async throws {
        let clock = AmbientClock(); let probe = AmbientProbe(); await probe.setHold(true)
        let policy = policy(job, ambient: 600, battery: { true })
        try policy.apply(context: context(job, paused: false))
        var completions = 0
        let lifecycle = CodeStatsScheduleLifecycle(
            interval: { policy.interval(for: self.job) },
            check: {
                await probe.run(); completions += 1
            }, now: { clock.now }, sleep: clock.sleep)
        try policy.start { lifecycle.reschedule() }; lifecycle.start()
        try await probe.awaitFirst()
        try policy.apply(context: context(job, paused: true))
        await probe.release()
        try await clock.settle { completions == 1 }
        #expect(await probe.cancelled == false)
        await lifecycle.runExplicit()
        #expect(await probe.count == 2)
        #expect(clock.requested.isEmpty)
        policy.stop(); await lifecycle.shutdown()
    }

    @Test func policyOnlySynchronizationDoesNotWakeSettingsWork() {
        var wakes = 0
        let runtime = ExtensionRuntime(settingsWake: { wakes += 1 })
        for paused in [false, true, true, false] {
            let input =
                context(CodeStatsScheduleLifecycle.jobID, paused: paused).mutableCopy()
                as! NSMutableDictionary
            input["operation"] = "synchronize"
            input["ambientPolicyOnly"] = true
            #expect((runtime.execute(input) as? NSDictionary)?["ok"] as? Bool == true)
        }
        #expect(wakes == 0)
        for paused in [false, true, true, false] {
            let input =
                context(CodeStatsScheduleLifecycle.jobID, paused: paused).mutableCopy()
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
