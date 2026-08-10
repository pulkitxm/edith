import Foundation
import Testing

@testable import EdithHelper
@testable import EdithKit

@Suite struct MachineMonitorTests {
    private let disks = [
        MachineFilesystem(
            fs: "/dev/nvme0n1p2", mount: "/", totalKB: 100, usedKB: 95, availKB: 5),
        MachineFilesystem(
            fs: "/dev/nvme0n1p3", mount: "/home", totalKB: 100, usedKB: 40, availKB: 60),
    ]

    @Test func parsesDfOutput() {
        let parsed = MachineMonitor.parseDisks(
            """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            /dev/nvme0n1p2   500000000 250000000 225000000      50% /
            /dev/sda1              100        50        50      50% /mnt/My Disk
            """)
        #expect(parsed.count == 2)
        #expect(parsed[0].mount == "/")
        #expect(parsed[0].usedPercent == 50.0)
        #expect(parsed[1].mount == "/mnt/My Disk")
    }

    @Test func skipsReadOnlyFilesystemsThatAreAlwaysFull() {
        let parsed = MachineMonitor.parseDisks(
            """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            /dev/nvme0n1p5   503648256 289598472 188392392      61% /
            /dev/sr0                5638      5638         0     100% /media/pulkit/SanDisk Unlocker
            \(MachineMonitor.mountsMarker)
            /dev/nvme0n1p5 on / type ext4 (rw,relatime,errors=remount-ro)
            /dev/sr0 on /media/pulkit/SanDisk Unlocker type udf (ro,nosuid,nodev,uid=1000)
            """)
        #expect(parsed.map(\.mount) == ["/"])
    }

    @Test func readsReadOnlyMountsFromBothMountFormats() {
        let linux = MachineMonitor.readOnlyMounts(
            """
            /dev/sr0 on /media/pulkit/SanDisk Unlocker type udf (ro,nosuid,nodev)
            /dev/nvme0n1p5 on / type ext4 (rw,relatime,stripe=32)
            /dev/nvme0n1p1 on /boot/efi type vfat (rw,relatime,errors=remount-ro)
            """)
        #expect(linux == ["/media/pulkit/SanDisk Unlocker"])

        let macOS = MachineMonitor.readOnlyMounts(
            """
            /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
            /dev/disk3s5 on /System/Volumes/Data (apfs, local, journaled, nobrowse)
            """)
        #expect(macOS == ["/"])
    }

    @Test func theDiskProbeOnlyAsksAboutFilesystemsItUnderstands() {
        let command = MachineMonitor.diskCommand
        #expect(command.contains("-t ext4"))
        #expect(command.contains("-t btrfs"))
        #expect(command.contains("[ -r /proc/mounts ]"))
    }

    @Test func stillParsesOutputThatCarriesTheStalledSection() {
        let parsed = MachineMonitor.parseDisks(
            """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            /dev/nvme0n1p5   503648256 289598472 188392392      61% /
            \(MachineMonitor.mountsMarker)
            /dev/nvme0n1p5 on / type ext4 (rw,relatime)
            \(MachineMonitor.stalledMarker)
            7
            """)
        #expect(parsed.map(\.mount) == ["/"])
    }

    @Test func readsTheStalledProcessCount() {
        let output = """
            Filesystem     1024-blocks      Used Available Capacity Mounted on
            \(MachineMonitor.mountsMarker)
            \(MachineMonitor.stalledMarker)
            39
            """
        #expect(MachineMonitor.parseStalledProcesses(output) == 39)
        #expect(MachineMonitor.parseStalledProcesses("no markers here") == 0)
    }

    @Test func warnsOnceWhenProcessesWedgeOnAFilesystem() {
        let healthy = MachineHealth(reachable: true, stalledProcesses: 0)
        let stalled = MachineHealth(reachable: true, stalledProcesses: 39)
        let first = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: healthy, current: stalled, disks: [], threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(first == [.filesystemStalled(machine: "Tuf", stuckProcesses: 39)])

        let repeated = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: stalled, current: stalled, disks: [], threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(repeated.isEmpty)
    }

    @Test func ignoresTheHandfulOfProcessesThatBlockOnOrdinaryIO() {
        let alerts = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: MachineHealth(reachable: true),
            current: MachineHealth(reachable: true, stalledProcesses: 1), disks: [],
            threshold: 90, notifyDown: true, notifyDisk: true)
        #expect(alerts.isEmpty)
    }

    @Test func theStalledAlertReadsLikeSomethingActionable() {
        let alert = MachineAlert.filesystemStalled(machine: "Tuf", stuckProcesses: 39)
        #expect(alert.title == "Tuf has a stalled filesystem")
        #expect(alert.body.contains("39 processes are stuck"))
        #expect(alert.body.contains("restart"))
    }

    @Test func flagsMountsOverThreshold() {
        #expect(MachineMonitorLogic.fullMounts(disks: disks, threshold: 90) == ["/"])
        #expect(MachineMonitorLogic.fullMounts(disks: disks, threshold: 99).isEmpty)
    }

    @Test func notifiesOnceWhenAMachineGoesOffline() {
        let previous = MachineHealth(reachable: true)
        let current = MachineHealth(reachable: false)
        let first = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: previous, current: current, disks: [], threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(first == [.unreachable(machine: "Tuf")])

        let repeated = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: current, current: current, disks: [], threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(repeated.isEmpty)
    }

    @Test func notifiesOnRecovery() {
        let alerts = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: MachineHealth(reachable: false),
            current: MachineHealth(reachable: true), disks: [], threshold: 90, notifyDown: true,
            notifyDisk: true)
        #expect(alerts == [.recovered(machine: "Tuf")])
    }

    @Test func notifiesOncePerNewlyFullDisk() {
        let previous = MachineHealth(reachable: true, fullMounts: [])
        let current = MachineHealth(reachable: true, fullMounts: ["/"])
        let alerts = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: previous, current: current, disks: disks, threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(alerts == [.diskFull(machine: "Tuf", mount: "/", percent: 95)])

        let repeated = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: current, current: current, disks: disks, threshold: 90,
            notifyDown: true, notifyDisk: true)
        #expect(repeated.isEmpty)
    }

    @Test func respectsDisabledToggles() {
        let alerts = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: MachineHealth(reachable: true),
            current: MachineHealth(reachable: false), disks: disks, threshold: 90,
            notifyDown: false, notifyDisk: false)
        #expect(alerts.isEmpty)
    }

    @Test func skipsDiskAlertsWhileUnreachable() {
        let alerts = MachineMonitorLogic.alerts(
            machineName: "Tuf", previous: MachineHealth(reachable: true, fullMounts: []),
            current: MachineHealth(reachable: false, fullMounts: ["/"]), disks: disks,
            threshold: 90, notifyDown: false, notifyDisk: true)
        #expect(alerts.isEmpty)
    }

    @Test func alertIdentifiersAreStablePerConcern() {
        #expect(
            MachineAlert.unreachable(machine: "Tuf").identifier
                == MachineAlert.recovered(machine: "Tuf").identifier)
        #expect(
            MachineAlert.diskFull(machine: "Tuf", mount: "/", percent: 95).identifier
                != MachineAlert.diskFull(machine: "Tuf", mount: "/home", percent: 95).identifier)
    }

    @Test func alertCopyIsUserFacing() {
        let alert = MachineAlert.diskFull(machine: "Tuf", mount: "/", percent: 94.6)
        #expect(alert.title == "Tuf is running out of space")
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
