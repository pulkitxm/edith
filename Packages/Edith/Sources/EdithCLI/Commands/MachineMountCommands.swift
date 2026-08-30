import ArgumentParser
import EdithKit
import Foundation

enum MountBridge {
    static func failure(_ error: Error, machine: Machine) -> CLIFailure {
        if let operationError = error as? MachineMountOperationError,
            case let .restoreFailed(record, message) = operationError
        {
            return CLIFailure(
                "could not put \(machine.name) back at \(record.mountPoint)", hint: message)
        }
        guard let mount = error as? MachineMountError else {
            return CLIFailure("\(machine.name): \(error.localizedDescription)")
        }
        let message = mount.errorDescription ?? "the mount failed"
        switch mount {
        case .toolMissing, .notMounted:
            return CLIFailure.unavailable(message, hint: mount.hint)
        default:
            return CLIFailure(message, hint: mount.hint)
        }
    }

    static func report(_ mount: MachineMount, machine: Machine, state: MountHealth? = nil)
        -> JSONValue
    {
        var fields: [String: JSONValue] = [
            "machine": .string(machine.name),
            "source": .string(mount.source),
            "remotePath": .string(mount.remotePath),
            "mountPoint": .string(mount.mountPoint),
            "readOnly": .bool(mount.isReadOnly),
        ]
        if let state { fields["state"] = .string(state.rawValue) }
        return .object(fields)
    }
}

struct MachinesMountCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount",
        abstract: "Mount a machine's file system on this Mac.",
        discussion: """
            The whole file system, from `/`, appears in Finder like a disk, so every local
            tool sees the machine's files: `ls ~/Edith/tuf/etc`, `open`, an editor,
            `rsync`. It rides the same SSH connection the app and `ed` already share, so
            nothing asks for the password twice. Name a directory to mount that instead.

            This needs an sshfs on this Mac. FUSE-T is the easy one, a user space NFS
            server rather than a kernel extension:
            `brew install --cask macos-fuse-t/cask/fuse-t macos-fuse-t/cask/fuse-t-sshfs`.
            macFUSE with `gromgit/fuse/sshfs-mac` works too, once its kernel extension
            is approved.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: .long, help: "Mount it read-only.")
    var readOnly = false

    @Option(name: .long, help: "Where to mount it. Defaults to ~/Edith/<machine>.")
    var at: String?

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Remote directory to mount. Defaults to the whole file system.")
    var path: String?

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let platform = await runner.ssh.remotePlatform ?? .linux
            let remote = path.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
            let destination = at.map { URL(fileURLWithPath: $0.expandingTilde()) }
            switch await MachineMountOperationExecution.perform(
                .mount, machine: runner.machine, remotePath: remote,
                platform: platform, mountPoint: destination, readOnly: readOnly,
                restoreDefault: path == nil && at == nil)
            {
            case let .success(outcome):
                guard !json else {
                    CLIOut.json(MountBridge.report(outcome.mount, machine: runner.machine))
                    return
                }
                CLIOut.out(
                    outcome.restored
                        ? "remounted \(outcome.mount.source)  ->  \(outcome.mount.mountPoint)"
                        : "\(outcome.mount.source)  ->  \(outcome.mount.mountPoint)")
            case let .failure(error):
                throw MountBridge.failure(error, machine: runner.machine)
            }
        }
    }
}

struct MachinesUnmountCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "unmount", abstract: "Unmount a machine's file system.",
        aliases: ["umount"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let found = try MachineResolver.machine(machine)
            switch await MachineMountOperationExecution.perform(.unmount, machine: found) {
            case let .success(outcome):
                guard !json else {
                    CLIOut.json(MountBridge.report(outcome.mount, machine: found))
                    return
                }
                CLIOut.out("unmounted \(outcome.mount.mountPoint)")
            case let .failure(error):
                throw MountBridge.failure(error, machine: found)
            }
        }
    }
}

struct MachinesMountsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mounts", abstract: "Every machine file system mounted on this Mac.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let machines = MachineDirectory.load()
            let mounts = await MachineMounts.tracked()
            var named: [(String, MachineMount, MountHealth)] = []
            for mount in mounts {
                let found = machines.first {
                    $0.id == mount.machineID || $0.sshTarget == mount.target
                }
                let state = await MachineMounts.health(of: mount)
                named.append((found?.name ?? mount.target, mount, state))
            }
            guard !json else {
                CLIOut.json(
                    .array(
                        named.map { name, mount, state in
                            .object([
                                "machine": .string(name),
                                "source": .string(mount.source),
                                "remotePath": .string(mount.remotePath),
                                "mountPoint": .string(mount.mountPoint),
                                "readOnly": .bool(mount.isReadOnly),
                                "state": .string(state.rawValue),
                            ])
                        }))
                return
            }
            guard !named.isEmpty else {
                CLIOut.note("nothing is mounted; mount one with `ed machines mount <machine>`")
                return
            }
            let rows = named.map { name, mount, state in
                [
                    name, mount.remotePath, mount.mountPoint, mount.isReadOnly ? "ro" : "rw",
                    state.rawValue,
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["MACHINE", "REMOTE", "AT", "MODE", "STATE"], rows: rows))
        }
    }
}

struct MachinesMountRevealCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mount-reveal", abstract: "Reveal a mounted machine file system in Finder.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            guard let mount = await MachineMounts.current(for: target) else {
                throw CLIFailure.unavailable("\(target.name) is not mounted")
            }
            let url = URL(fileURLWithPath: mount.mountPoint)
            guard
                RemoteFileOperationExecution.present(
                    [url], action: .reveal, using: CLIEnvironment.presentURLs)
            else { throw CLIFailure.unavailable("Finder is unavailable") }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(target.name),
                        "mountPoint": .string(mount.mountPoint),
                        "revealed": .bool(true),
                    ]))
                return
            }
            CLIOut.out("revealed \(mount.mountPoint)")
        }
    }
}
