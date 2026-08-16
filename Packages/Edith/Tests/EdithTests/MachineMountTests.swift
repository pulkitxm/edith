import Foundation
import Testing

@testable import EdithKit

@Suite struct MachineMountTests {
    private let machine = Machine(
        id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!, name: "tuf",
        host: "10.0.0.4", port: 2222, username: "pulkit")

    @Test func everyMountedVolumeIsRead() {
        let output = """
            /dev/disk3s1s1 on / (apfs, sealed, local, read-only, journaled)
            pulkit@10.0.0.4:/home/pulkit on /Users/pulkit/Edith/tuf (macfuse, nodev, nosuid)
            map auto_home on /System/Volumes/Data/home (autofs, automounted)
            """
        let volumes = MachineMounts.parse(output)
        #expect(volumes.count == 3)
        let fuse = volumes.filter(\.looksLikeFUSE)
        #expect(fuse.count == 1)
        #expect(fuse.first?.mountPoint == "/Users/pulkit/Edith/tuf")
        #expect(volumes.first?.isReadOnly == true)
    }

    @Test func aMacFuseMountNobodyRecordedIsStillRecognised() {
        let volumes = MachineMounts.parse(
            "pulkit@10.0.0.4:/home/pulkit on /Users/pulkit/Edith/tuf (macfuse, nodev)")
        let mounts = MachineMounts.reconcile(records: [], with: volumes)
        #expect(mounts.count == 1)
        #expect(MachineMounts.mount(for: machine, in: mounts)?.remotePath == "/home/pulkit")
        let other = Machine(name: "pi", host: "box", username: "pi")
        #expect(MachineMounts.mount(for: other, in: mounts) == nil)
    }

    @Test func aRecordedMountIsMatchedByItsMountPointWhateverTheSourceSays() {
        let record = MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: "/srv",
            mountPoint: "/Users/pulkit/Edith/tuf")
        let volumes = MachineMounts.parse(
            "fuse-t:/sshfs on /Users/pulkit/Edith/tuf (nfs, nodev, read-only)")
        let mounts = MachineMounts.reconcile(records: [record], with: volumes)
        #expect(mounts.count == 1)
        #expect(MachineMounts.mount(for: machine, in: mounts)?.remotePath == "/srv")
        #expect(mounts.first?.isReadOnly == true)
    }

    @Test func aRecordWhoseMountHasGoneIsDropped() {
        let record = MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: "/srv",
            mountPoint: "/Users/pulkit/Edith/tuf")
        let volumes = MachineMounts.parse("/dev/disk3s1s1 on / (apfs, local)")
        #expect(MachineMounts.reconcile(records: [record], with: volumes).isEmpty)
    }

    @Test func theMountPointIsNamedAfterTheMachine() {
        #expect(MachineMounts.mountPoint(for: machine).lastPathComponent == "tuf")
        let awkward = Machine(name: "web/prod", host: "h")
        #expect(MachineMounts.folderName(for: awkward) == "web-prod")
    }

    @Test func theMountRidesTheSharedControlSocket() {
        let arguments = MachineMounts.mountArguments(
            machine: machine, remotePath: "/srv", mountPoint: "/Users/pulkit/Edith/tuf",
            readOnly: false)
        #expect(arguments.first == "pulkit@10.0.0.4:/srv")
        #expect(arguments[1] == "/Users/pulkit/Edith/tuf")
        #expect(
            arguments.contains(
                "ControlPath=\"\(MachinePaths.socketFile(for: machine.id).path)\""),
            "the socket path is quoted, or ssh breaks on the space in Application Support")
        #expect(arguments.contains("ControlMaster=no"))
        #expect(arguments.contains("BatchMode=yes"))
        #expect(arguments.contains("volname=tuf"))
        #expect(!arguments.contains("ro"))
    }

    @Test func theSecondAttemptDropsTheOptionsOnlyMacFuseKnows() {
        let arguments = MachineMounts.mountArguments(
            machine: machine, remotePath: "/srv", mountPoint: "/mnt/tuf", readOnly: true,
            minimal: true, useFSKit: true)
        #expect(!arguments.contains("volname=tuf"))
        #expect(!arguments.contains("defer_permissions"))
        #expect(!arguments.contains("backend=fskit"))
        #expect(arguments.contains("ControlMaster=no"))
        #expect(arguments.contains("ro"))
    }

    @Test func macOS26MountsUseFSKitWithoutMetadataWrites() {
        let options = MachineMounts.options(
            machine: machine, readOnly: false, useFSKit: true)
        #expect(options.contains("backend=fskit"))
        #expect(options.contains("noatime"))
    }

    @Test func earlierSystemsDoNotRequestFSKit() {
        let options = MachineMounts.options(
            machine: machine, readOnly: false, useFSKit: false)
        #expect(!options.contains("backend=fskit"))
    }

    @Test func fuseTHelpersAreMatchedToTheExactMountPoint() {
        let output = """
            29352 /usr/local/bin/go-nfsv4 --volname tuf /Users/pulkit/Edith/tuf
            40777 /usr/local/bin/go-nfsv4 /Users/pulkit/Edith/tuf-old
            44073 /Library/Application Support/fuse-t/bin/go-nfsv4-1.2.7 /Users/pulkit/Edith/tuf
            57020 /usr/bin/ssh tuf
            """
        #expect(
            MachineMounts.fuseTHelperPIDs(in: output, mountedAt: "/Users/pulkit/Edith/tuf")
                == [29352, 44073])
    }

    @Test func aManualMachineCarriesItsPortAndKey() {
        var keyed = machine
        keyed.auth = .keyFile(path: "/tmp/id_ed25519", hasPassphrase: false)
        let arguments = MachineMounts.mountArguments(
            machine: keyed, remotePath: "/srv", mountPoint: "/mnt/tuf", readOnly: true)
        #expect(arguments.contains("-p"))
        #expect(arguments.contains("2222"))
        #expect(arguments.contains("IdentityFile=/tmp/id_ed25519"))
        #expect(arguments.contains("ro"))
    }

    @Test func anAliasMachineIsLeftToTheSSHConfig() {
        var alias = machine
        alias.source = .sshConfigAlias("tuf-alias")
        let arguments = MachineMounts.mountArguments(
            machine: alias, remotePath: "/srv", mountPoint: "/mnt/tuf", readOnly: false)
        #expect(arguments.first == "tuf-alias:/srv")
        #expect(!arguments.contains("-p"))
    }

    @Test func healthSaysWhatARepairWouldHaveToDo() {
        #expect(MountHealth.mounted.needsRepair == false)
        #expect(MountHealth.stale.needsRepair)
        #expect(MountHealth.gone.needsRepair)
        #expect(MountHealth.stale.describes == "not answering")
    }

    private func scratchFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathComponent("mounts.json")
    }

    @Test func aRecordSurvivesTheMountGoingAwaySoItCanBePutBack() {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        let record = MachineMount(
            machineID: machine.id, target: machine.sshTarget, remotePath: "/",
            mountPoint: "/Users/pulkit/Edith/tuf", isReadOnly: true)
        MachineMounts.remember([record], in: file)
        #expect(MachineMounts.recorded(for: machine, in: file) == record)
        let other = Machine(name: "pi", host: "box")
        #expect(MachineMounts.recorded(for: other, in: file) == nil)
    }

    @Test func anAdoptedMountIsNeverPutBackBecauseEdithDidNotMakeIt() {
        let file = scratchFile()
        defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
        MachineMounts.remember(
            [MachineMount(target: "pulkit@10.0.0.4", remotePath: "/", mountPoint: "/mnt/x")],
            in: file)
        #expect(MachineMounts.records(in: file).isEmpty)
        #expect(MachineMounts.recorded(for: machine, in: file) == nil)
    }

    @Test func aPasswordMachineKeepsItsAskpassRatherThanBatchMode() {
        var secret = machine
        secret.auth = .password
        let options = MachineMounts.options(machine: secret, readOnly: false)
        #expect(!options.contains("BatchMode=yes"))
        #expect(options.contains("reconnect"))
        let agent = MachineMounts.options(machine: machine, readOnly: false)
        #expect(agent.contains("BatchMode=yes"))
    }

    @Test func aMountPointWithSomethingInItIsRefused() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(throws: Never.self) { try MachineMounts.prepare(directory) }
        FileManager.default.createFile(
            atPath: directory.appendingPathComponent("busy").path, contents: Data())
        #expect(throws: MachineMountError.mountPointBusy(directory.path)) {
            try MachineMounts.prepare(directory)
        }
    }
}
