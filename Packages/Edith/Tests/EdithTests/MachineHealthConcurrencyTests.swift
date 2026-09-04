import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct MachineHealthConcurrencyTests {
    private let settings = MachineHealthPolicySettings(
        notifyDown: true, notifyDiskFull: true, diskThreshold: 90)

    @Test func probesRunConcurrentlyWithinTheLimitAndKeepFleetOrder() async {
        let machines = (0..<12).map { Machine(name: String($0), host: "host-\($0)") }
        let activity = ProbeActivity()
        let monitor = MachineHealthMonitor(
            machines: { machines }, settings: { self.settings },
            probe: { machine, _ in
                await activity.enter()
                let delay = 5 * (4 - (Int(machine.name)! % 4))
                try? await Task.sleep(for: .milliseconds(delay))
                await activity.leave()
                return (MachineHealth(), [], nil)
            }, notify: { _ in }, load: { [:] }, save: { _ in },
            maximumConcurrentProbes: 3)

        let snapshot = await monitor.run()

        #expect(await activity.peak == 3)
        #expect(await activity.active == 0)
        #expect(snapshot.machines.map(\.name) == machines.map(\.name))
    }

    @Test func cancellationDoesNotSaveFalseOutagesOrStartTheRemainingFleet() async {
        let machines = (0..<12).map { Machine(name: String($0), host: "host-\($0)") }
        let activity = ProbeActivity()
        let effects = HealthEffects()
        let monitor = MachineHealthMonitor(
            machines: { machines }, settings: { self.settings },
            probe: { _, _ in
                await activity.enter()
                try? await Task.sleep(for: .seconds(30))
                await activity.leave()
                return (MachineHealth(reachable: false), [], "cancelled")
            }, notify: { _ in effects.notify() }, load: { [:] },
            save: { effects.save($0) }, maximumConcurrentProbes: 2)
        let task = Task { await monitor.run() }
        await activity.waitUntilEntered()
        task.cancel()
        let snapshot = await task.value

        #expect(snapshot.skipped)
        #expect(await activity.entered <= 2)
        #expect(effects.saved == nil)
        #expect(effects.notifications == 0)
    }

    @Test func failedDiskCollectionPreservesExistingWarnings() async {
        let machine = Machine(name: "workstation", host: "workstation")
        let previous = MachineHealth(reachable: true, fullMounts: ["/"], stalledProcesses: 4)
        let effects = HealthEffects()
        let monitor = MachineHealthMonitor(
            machines: { [machine] }, settings: { self.settings },
            probe: { _, _ in (MachineHealth(reachable: true), [], "permission denied") },
            notify: { _ in effects.notify() }, load: { [machine.id: previous] },
            save: { effects.save($0) })

        let snapshot = await monitor.run()

        #expect(snapshot.machines.first?.reachable == true)
        #expect(snapshot.machines.first?.detail == "permission denied")
        #expect(effects.saved?[machine.id] == previous)
        #expect(effects.notifications == 0)
    }

    @Test func commandFailureIsDistinctFromAnSSHTransportFailure() {
        let collection = MachineHealthProbe.outcome(
            SSHExecResult(status: 1, stdout: Data(), stderr: Data("permission denied".utf8)),
            platform: .linux, threshold: 90)
        #expect(collection.health.reachable)
        #expect(collection.failure == "permission denied")

        let transport = MachineHealthProbe.outcome(
            SSHExecResult(status: 255, stdout: Data(), stderr: Data("connection lost".utf8)),
            platform: .linux, threshold: 90)
        #expect(!transport.health.reachable)
        #expect(transport.failure == "connection lost")
    }

    @Test func windowsHealthUsesPowerShellAndDecodesDriveUsage() {
        #expect(MachineHealthProbe.command(for: .windows) != MachineHealthProbe.diskCommand)
        #expect(MachineHealthProbe.command(for: .linux) == MachineHealthProbe.diskCommand)
        let outcome = MachineHealthProbe.outcome(
            SSHExecResult(
                status: 0,
                stdout: Data(#"[{"fs":"C:","totalKB":100,"availKB":5}]"#.utf8),
                stderr: Data()),
            platform: .windows, threshold: 90)

        #expect(outcome.health.reachable)
        #expect(outcome.health.fullMounts == ["C:"])
        #expect(outcome.disks.first?.usedKB == 95)
        #expect(outcome.failure == nil)
    }

    @Test func incompleteResponsesAreReportedAsCollectionFailures() {
        for platform in [RemoteMachinePlatform.linux, .windows] {
            let outcome = MachineHealthProbe.outcome(
                SSHExecResult(status: 0, stdout: Data("unexpected output".utf8), stderr: Data()),
                platform: platform, threshold: 90)
            #expect(outcome.health.reachable)
            #expect(outcome.failure != nil)
        }
    }
}

private actor ProbeActivity {
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var entered = 0
    private var waiting: [CheckedContinuation<Void, Never>] = []

    func enter() {
        active += 1
        entered += 1
        peak = max(peak, active)
        for waiter in waiting { waiter.resume() }
        waiting.removeAll()
    }

    func leave() { active -= 1 }

    func waitUntilEntered() async {
        guard entered == 0 else { return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

private final class HealthEffects: @unchecked Sendable {
    private let lock = NSLock()
    private var state: [UUID: MachineHealth]?
    private var notificationCount = 0

    var saved: [UUID: MachineHealth]? { lock.withLock { state } }
    var notifications: Int { lock.withLock { notificationCount } }

    func save(_ value: [UUID: MachineHealth]) { lock.withLock { state = value } }
    func notify() { lock.withLock { notificationCount += 1 } }
}
