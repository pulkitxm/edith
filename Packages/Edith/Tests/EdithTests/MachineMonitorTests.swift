import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct MachineMonitorTests {
    private let disks = [
        MachineFilesystem(
            fs: "/dev/disk3s1s1", mount: "/", totalKB: 100, usedKB: 95, availKB: 5),
        MachineFilesystem(
            fs: "/dev/disk3s5", mount: "/System/Volumes/Data", totalKB: 100, usedKB: 40,
            availKB: 60),
    ]

    @Test func parsesDfOutput() {
        let parsed = MachineMonitor.parseDisks(
            """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            /dev/disk3s1s1   500000000 250000000 225000000      50% /
            /dev/disk5s1           100        50        50      50% /Volumes/My Disk
            """)
        #expect(parsed.count == 2)
        #expect(parsed[0].mount == "/")
        #expect(parsed[0].usedPercent == 50.0)
        #expect(parsed[1].mount == "/Volumes/My Disk")
    }

    @Test func skipsReadOnlyFilesystemsThatAreAlwaysFull() {
        let parsed = MachineMonitor.parseDisks(
            """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            /dev/disk3s5   503648256 289598472 188392392      61% /System/Volumes/Data
            /dev/disk5s1        5638      5638         0     100% /Volumes/Installer
            \(MachineMonitor.mountsMarker)
            /dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse)
            /dev/disk5s1 on /Volumes/Installer (hfs, local, nodev, read-only, noowners)
            """)
        #expect(parsed.map(\.mount) == ["/System/Volumes/Data"])
    }

    @Test func readsReadOnlyMounts() {
        let mounts = MachineMonitor.readOnlyMounts(
            """
            /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
            /dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse)
            """)
        #expect(mounts == ["/"])
    }

    @Test func theDiskProbeUsesMacCommands() {
        let command = MachineMonitor.diskCommand
        #expect(command.contains("df -Pk"))
        #expect(command.contains("mount"))
    }

    @Test func flagsMountsOverThreshold() {
        #expect(MachineMonitorLogic.fullMounts(disks: disks, threshold: 90) == ["/"])
        #expect(MachineMonitorLogic.fullMounts(disks: disks, threshold: 99).isEmpty)
    }

    @Test func notifiesOnceWhenAMachineGoesOffline() {
        let previous = MachineHealth(reachable: true)
        let current = MachineHealth(reachable: false)
        let first = MachineMonitorLogic.alerts(
            machineName: "studio", previous: previous, current: current, disks: [], threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(first == [.unreachable(machine: "studio")])

        let repeated = MachineMonitorLogic.alerts(
            machineName: "studio", previous: current, current: current, disks: [], threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(repeated.isEmpty)
    }

    @Test func notifiesOnRecovery() {
        let alerts = MachineMonitorLogic.alerts(
            machineName: "studio", previous: MachineHealth(reachable: false),
            current: MachineHealth(reachable: true), disks: [], threshold: 90, notifyDown: true,
            notifyDisk: true)
        #expect(alerts == [.recovered(machine: "studio")])
    }

    @Test func notifiesOncePerNewlyFullDisk() {
        let previous = MachineHealth(reachable: true, fullMounts: [])
        let current = MachineHealth(reachable: true, fullMounts: ["/"])
        let alerts = MachineMonitorLogic.alerts(
            machineName: "studio", previous: previous, current: current, disks: disks,
            threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(alerts == [.diskFull(machine: "studio", mount: "/", percent: 95)])

        let repeated = MachineMonitorLogic.alerts(
            machineName: "studio", previous: current, current: current, disks: disks, threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(repeated.isEmpty)
    }

    @Test func respectsDisabledToggles() {
        let alerts = MachineMonitorLogic.alerts(
            machineName: "studio", previous: MachineHealth(reachable: true),
            current: MachineHealth(reachable: false), disks: disks, threshold: 90,
            notifyDown: false, notifyDisk: false)
        #expect(alerts.isEmpty)
    }

    @Test func skipsDiskAlertsWhileUnreachable() {
        let alerts = MachineMonitorLogic.alerts(
            machineName: "studio", previous: MachineHealth(reachable: true, fullMounts: []),
            current: MachineHealth(reachable: false, fullMounts: ["/"]), disks: disks,
            threshold: 90, notifyDown: false, notifyDisk: true)
        #expect(alerts.isEmpty)
    }

    @Test func alertIdentifiersAreStablePerConcern() {
        #expect(
            MachineAlert.unreachable(machine: "studio").identifier
                == MachineAlert.recovered(machine: "studio").identifier)
        #expect(
            MachineAlert.diskFull(machine: "studio", mount: "/", percent: 95).identifier
                != MachineAlert.diskFull(machine: "studio", mount: "/home", percent: 95).identifier)
    }

    @Test func alertCopyIsUserFacing() {
        let alert = MachineAlert.diskFull(machine: "studio", mount: "/", percent: 94.6)
        #expect(alert.title == "studio is running out of space")
        #expect(alert.body == "/ is 95% full.")
    }
}

@Suite struct MetricsStreamRecoveryTests {
    @Test func aStreamThatKeepsFailingIsRetriedLessOften() {
        #expect(MachineSession.metricsRestartDelay(failures: 0) == 3)
        #expect(MachineSession.metricsRestartDelay(failures: 1) == 6)
        #expect(MachineSession.metricsRestartDelay(failures: 2) == 12)
    }

    @Test func theRetryDelayIsCappedSoAMachineIsNeverAbandoned() {
        #expect(MachineSession.metricsRestartDelay(failures: 20) == 60)
        #expect(MachineSession.metricsRestartDelay(failures: -1) == 3)
    }

    @Test func silenceIsJudgedGenerouslyAgainstTheTwoSecondCadence() {
        #expect(MachineSession.metricsSilenceLimit >= 10)
    }
}

@Suite @MainActor struct MetricHistoryShapeTests {
    @Test func theFirstSampleFillsTheWholeWindow() {
        let seeded = MachineSession.appending(42, to: [])
        #expect(seeded.count == MachineSession.historyLength)
        #expect(seeded.allSatisfy { $0 == 42 })
    }

    @Test func laterSamplesKeepTheWindowLengthConstant() {
        var history = MachineSession.appending(10, to: [])
        for value in 1...20 {
            history = MachineSession.appending(Double(value), to: history)
            #expect(history.count == MachineSession.historyLength)
        }
        #expect(history.last == 20)
        #expect(history.suffix(3) == [18, 19, 20])
    }

    @Test func aFullWindowScrollsByExactlyOneSample() {
        var history = MachineSession.appending(0, to: [])
        for value in 1...MachineSession.historyLength {
            history = MachineSession.appending(Double(value), to: history)
        }
        let before = history
        history = MachineSession.appending(999, to: history)
        #expect(Array(history.dropLast()) == Array(before.dropFirst()))
    }
}
