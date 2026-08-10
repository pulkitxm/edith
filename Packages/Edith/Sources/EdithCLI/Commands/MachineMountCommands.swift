import ArgumentParser
import EdithKit
import Foundation

enum MountBridge {
    static func failure(_ error: Error, machine: Machine) -> CLIFailure {
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
            let remote = path.flatMap { $0.isEmpty ? nil : $0 } ?? "/"
            let destination = at.map { URL(fileURLWithPath: $0.expandingTilde()) }
            if path == nil, at == nil {
                switch await MachineMounts.restore(machine: runner.machine) {
                case let .remounted(landed):
                    guard !json else {
                        CLIOut.json(MountBridge.report(landed, machine: runner.machine))
                        return
                    }
                    CLIOut.out("remounted \(landed.source)  ->  \(landed.mountPoint)")
                    return
                case let .healthy(landed):
                    throw MountBridge.failure(
                        MachineMountError.alreadyMounted(landed.mountPoint),
                        machine: runner.machine)
                case let .failed(record, message):
                    throw CLIFailure(
                        "could not put \(runner.machine.name) back at \(record.mountPoint)",
                        hint: message)
                case .nothingToDo:
                    break
                }
            }
            do {
                let mounted = try await MachineMounts.mount(
                    machine: runner.machine, remotePath: remote, at: destination,
                    readOnly: readOnly)
                guard !json else {
                    CLIOut.json(MountBridge.report(mounted, machine: runner.machine))
                    return
                }
                CLIOut.out("\(mounted.source)  ->  \(mounted.mountPoint)")
            } catch {
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
            do {
                let released = try await MachineMounts.unmount(machine: found)
                guard !json else {
                    CLIOut.json(MountBridge.report(released, machine: found))
                    return
                }
                CLIOut.out("unmounted \(released.mountPoint)")
            } catch {
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
