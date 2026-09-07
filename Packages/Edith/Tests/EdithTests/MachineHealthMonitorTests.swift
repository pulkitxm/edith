import Foundation
import Testing

@testable import EdithAgent
@testable import EdithKit

@Suite struct MachineHealthMonitorTests {
    private func machine(_ name: String) -> Machine {
        Machine(name: name, host: "\(name).local")
    }

    private func settings(
        notifyDown: Bool = true, notifyDisk: Bool = true
    ) -> MachineHealthPolicySettings {
        MachineHealthPolicySettings(
            notifyDown: notifyDown, notifyDiskFull: notifyDisk, diskThreshold: 90)
    }

    @Test func noMachinesMeansNoProbe() async {
        let probed = Recorder()
        let monitor = MachineHealthMonitor(
            machines: { [] }, settings: { self.settings() },
            probe: { _, _ in
                probed.add("probed")
                return (MachineHealth(), [], nil)
            }, notify: { _ in }, load: { [:] }, save: { _ in })

        let snapshot = await monitor.run()

        #expect(snapshot.skipped)
        #expect(snapshot.machines.isEmpty)
        #expect(probed.values.isEmpty)
    }

    @Test func anUnreachableMachineIsReportedAsSuch() async {
        let box = machine("tuf")
        let monitor = MachineHealthMonitor(
            machines: { [box] }, settings: { self.settings() },
            probe: { _, _ in
                (MachineHealth(reachable: false, fullMounts: []), [], "connection refused")
            }, notify: { _ in }, load: { [:] }, save: { _ in })

        let snapshot = await monitor.run()

        #expect(!snapshot.skipped)
        #expect(snapshot.machines.count == 1)
        #expect(snapshot.machines.first?.reachable == false)
        #expect(snapshot.machines.first?.detail == "connection refused")
    }

    @Test func goingOfflineRaisesExactlyOneAlert() async {
        let box = machine("tuf")
        let alerts = Recorder()
        let monitor = MachineHealthMonitor(
            machines: { [box] }, settings: { self.settings() },
            probe: { _, _ in (MachineHealth(reachable: false), [], "down") },
            notify: { alerts.add($0.identifier) },
            load: { [box.id: MachineHealth(reachable: true)] }, save: { _ in })

        _ = await monitor.run()

        #expect(alerts.values == ["machine.reachability.tuf"])
    }

    @Test func aMachineThatWasAlreadyOfflineStaysQuiet() async {
        let box = machine("tuf")
        let alerts = Recorder()
        let monitor = MachineHealthMonitor(
            machines: { [box] }, settings: { self.settings() },
            probe: { _, _ in (MachineHealth(reachable: false), [], "down") },
            notify: { alerts.add($0.identifier) },
            load: { [box.id: MachineHealth(reachable: false)] }, save: { _ in })

        _ = await monitor.run()

        #expect(alerts.values.isEmpty)
    }

    @Test func comingBackRaisesARecovery() async {
        let box = machine("tuf")
        let alerts = Recorder()
        let monitor = MachineHealthMonitor(
            machines: { [box] }, settings: { self.settings() },
            probe: { _, _ in (MachineHealth(reachable: true), [], nil) },
            notify: { alerts.add($0.title) },
            load: { [box.id: MachineHealth(reachable: false)] }, save: { _ in })

        _ = await monitor.run()

        #expect(alerts.values == ["tuf is back"])
    }

    @Test func alertsAreSilencedWhenTheSettingIsOff() async {
        let box = machine("tuf")
        let alerts = Recorder()
        let monitor = MachineHealthMonitor(
            machines: { [box] }, settings: { self.settings(notifyDown: false) },
            probe: { _, _ in (MachineHealth(reachable: false), [], "down") },
            notify: { alerts.add($0.identifier) },
            load: { [box.id: MachineHealth(reachable: true)] }, save: { _ in })

        _ = await monitor.run()

        #expect(alerts.values.isEmpty)
    }

    @Test func healthForMachinesYouDeletedIsForgotten() async {
        let box = machine("tuf")
        let stale = UUID()
        let saved = Store()
        let monitor = MachineHealthMonitor(
            machines: { [box] }, settings: { self.settings() },
            probe: { _, _ in (MachineHealth(reachable: true), [], nil) }, notify: { _ in },
            load: { [stale: MachineHealth(reachable: false)] }, save: { saved.store($0) })

        _ = await monitor.run()

        #expect(saved.value?.keys.contains(stale) == false)
        #expect(saved.value?.keys.contains(box.id) == true)
    }

    @Test func aFillingDiskRaisesOneAlertPerMount() async {
        let box = machine("tuf")
        let alerts = Recorder()
        let disks = [
            MachineFilesystem(fs: "/dev/sda1", mount: "/", totalKB: 100, usedKB: 95, availKB: 5)
        ]
        let monitor = MachineHealthMonitor(
            machines: { [box] }, settings: { self.settings() },
            probe: { _, threshold in
                (
                    MachineHealth(
                        reachable: true,
                        fullMounts: MachineMonitorLogic.fullMounts(
                            disks: disks, threshold: threshold)), disks, nil
                )
            }, notify: { alerts.add($0.identifier) },
            load: { [box.id: MachineHealth(reachable: true)] }, save: { _ in })

        _ = await monitor.run()

        #expect(alerts.values == ["machine.disk.tuf./"])
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    var values: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func add(_ value: String) {
        lock.lock()
        stored.append(value)
        lock.unlock()
    }
}

private final class Store: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [UUID: MachineHealth]?

    var value: [UUID: MachineHealth]? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(_ value: [UUID: MachineHealth]) {
        lock.lock()
        stored = value
        lock.unlock()
    }
}
