import ArgumentParser
import EdithKit
import Foundation

struct MachinesPowerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "power",
        abstract: "Restart, shut down or wake a machine.",
        discussion: """
            Restart and shut down go through systemd and need privilege on the far side:
            `ed` tries `sudo -n` first and falls back to plain systemctl. A machine that
            asks for a password or for interactive authentication is reported as refusing,
            rather than being called done.

            Wake sends a wake-on-LAN packet to the machine's stored MAC address and needs
            nothing on the far side, so it is the one that works while the machine is off.
            """,
        subcommands: [
            MachinesPowerStatusCommand.self, MachinesRebootCommand.self,
            MachinesShutdownCommand.self, MachinesWakeCommand.self,
        ],
        defaultSubcommand: MachinesPowerStatusCommand.self)
}

struct MachinesPowerStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Whether a machine is up, and what it can be told to do.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            let reachable = MachineDirectory.hasLiveControlSocket(target)
            let mac = target.wakeMACAddress
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(target.name),
                        "connected": .bool(reachable),
                        "macAddress": .optional(mac),
                        "canWake": .bool(mac != nil),
                        "canReboot": .bool(reachable),
                        "canShutDown": .bool(reachable),
                    ]))
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["MACHINE", "CONNECTED", "MAC", "WAKE", "REBOOT"],
                    rows: [
                        [
                            target.name, reachable ? "yes" : "no", mac ?? "-",
                            mac != nil ? "yes" : "no", reachable ? "yes" : "no",
                        ]
                    ]))
        }
    }
}

enum PowerBridge {
    static func apply(
        _ action: String, machine name: String, json: Bool, yes: Bool
    ) async throws {
        try await execute {
            let target = try MachineResolver.machine(name)
            let stdin = SudoPassword.stdin(machineID: target.id)
            let command =
                action == "reboot"
                ? ServiceCommands.reboot(withSudoPassword: stdin != nil)
                : ServiceCommands.shutdown(withSudoPassword: stdin != nil)
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "machine": .string(target.name),
                            "action": .string(action),
                            "applied": .bool(false),
                            "command": .string(command),
                        ]))
                    return
                }
                CLIOut.out(
                    action == "reboot"
                        ? "would restart \(target.name)" : "would shut \(target.name) down")
                CLIOut.note("nothing was done; pass --yes to go ahead")
                return
            }
            let runner = try await MachineResolver.runner(name)
            let outcome: Result<SSHExecResult, Error>
            do {
                outcome = .success(try await runner.ssh.run(command, stdin: stdin, timeout: 20))
            } catch {
                outcome = .failure(error)
            }
            switch outcome {
            case let .success(result) where result.succeeded:
                try report(action, machine: target.name, json: json)
            case let .success(result):
                throw refusal(action, machine: target.name, detail: result.combinedText)
            case let .failure(error):
                guard PowerOutcome.hostWentAway(error) else {
                    throw refusal(
                        action, machine: target.name, detail: PowerOutcome.explain(error))
                }
                try report(action, machine: target.name, json: json)
            }
        }
    }

    static func refusal(_ action: String, machine: String, detail: String) -> CLIFailure {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty ? "\(machine) refused to \(action)" : trimmed
        return CLIFailure(
            "\(machine) did not \(action): \(message)",
            hint: SudoPassword.hint(forRefusal: trimmed))
    }

    static func report(_ action: String, machine: String, json: Bool) throws {
        guard !json else {
            CLIOut.json(
                .object([
                    "machine": .string(machine),
                    "action": .string(action),
                    "applied": .bool(true),
                ]))
            return
        }
        CLIOut.out(action == "reboot" ? "\(machine) is restarting" : "\(machine) is shutting down")
    }
}

struct MachinesRebootCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "reboot", abstract: "Restart a machine.", aliases: ["restart"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually restart it. Without this nothing is done.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await PowerBridge.apply("reboot", machine: machine, json: json, yes: yes)
    }
}

struct MachinesShutdownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "shutdown", abstract: "Shut a machine down.", aliases: ["poweroff"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Actually shut it down. Without this nothing is done.")
    var yes = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await PowerBridge.apply("shutdown", machine: machine, json: json, yes: yes)
    }
}

struct MachinesWakeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "wake",
        abstract: "Send a wake-on-LAN packet to a machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let target = try MachineResolver.machine(machine)
            guard let mac = target.wakeMACAddress else {
                throw CLIFailure.unavailable(
                    "no MAC address is stored for \(target.name)",
                    hint:
                        "open the machine in Edith while it is up so it can learn one, or set it "
                        + "with `ed machines edit \(target.name) --mac <address>`")
            }
            guard let packet = WakeOnLAN.magicPacket(macAddress: mac) else {
                throw CLIFailure("\(mac) is not a MAC address")
            }
            if let failure = MagicPacket.send(packet) {
                throw CLIFailure(failure)
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(target.name),
                        "action": .string("wake"),
                        "macAddress": .string(mac),
                        "applied": .bool(true),
                    ]))
                return
            }
            CLIOut.out("sent a wake packet to \(mac)")
        }
    }
}

struct MachinesServicesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "services",
        abstract: "systemd units on a machine.",
        subcommands: [
            MachinesServicesListCommand.self, MachinesServiceStartCommand.self,
            MachinesServiceStopCommand.self, MachinesServiceRestartCommand.self,
        ],
        defaultSubcommand: MachinesServicesListCommand.self)
}

enum ServiceBridge {
    static func apply(_ action: String, machine name: String, unit: String, json: Bool)
        async throws
    {
        try await execute {
            let runner = try await MachineResolver.runner(name)
            let stdin = SudoPassword.stdin(machineID: runner.machine.id)
            let result = try await runner.run(
                ServiceCommands.action(action, unit: unit, withSudoPassword: stdin != nil),
                stdin: stdin, timeout: 60)
            let detail = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded, !PowerOutcome.needsPrivilege(detail) else {
                throw CLIFailure(
                    "could not \(action) \(unit) on \(runner.machine.name)"
                        + (detail.isEmpty ? "" : ": \(detail)"),
                    hint: SudoPassword.hint(forRefusal: detail))
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "unit": .string(unit),
                        "action": .string(action),
                        "applied": .bool(true),
                    ]))
                return
            }
            CLIOut.out("\(action)ed \(unit) on \(runner.machine.name)")
        }
    }
}

struct MachinesServiceStartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "start", abstract: "Start a unit.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Unit name, for example nginx.service.")
    var unit: String

    func run() async throws {
        try await ServiceBridge.apply("start", machine: machine, unit: unit, json: json)
    }
}

struct MachinesServiceStopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop", abstract: "Stop a unit.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Unit name, for example nginx.service.")
    var unit: String

    func run() async throws {
        try await ServiceBridge.apply("stop", machine: machine, unit: unit, json: json)
    }
}

struct MachinesServiceRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Restart a unit.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "Unit name, for example nginx.service.")
    var unit: String

    func run() async throws {
        try await ServiceBridge.apply("restart", machine: machine, unit: unit, json: json)
    }
}

struct MachinesKillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill",
        abstract: "End a process on a machine.",
        discussion: """
            The default signal is TERM, which asks the process to stop. `--signal KILL` is
            the one it cannot refuse. `ed machines metrics <machine> --processes 20` lists
            the pids.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Signal to send: TERM, KILL, HUP, INT, QUIT, USR1 or USR2.")
    var signal: String = "TERM"

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(help: "The process id.")
    var pid: Int

    func run() async throws {
        try await execute {
            guard let named = ProcessCommands.normalizedSignal(signal) else {
                throw CLIFailure.notFound(
                    "there is no signal called \(signal)",
                    hint: "signals: " + ProcessCommands.signals.joined(separator: ", "))
            }
            guard pid > 0 else { throw CLIFailure("a process id is greater than zero") }
            let runner = try await MachineResolver.runner(machine)
            let result = try await runner.run(
                ProcessCommands.kill(pid: pid, signal: named), timeout: 30)
            let detail = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard result.succeeded else {
                throw CLIFailure(
                    "could not signal \(pid) on \(runner.machine.name)"
                        + (detail.isEmpty ? "" : ": \(detail)"))
            }
            let gone = ProcessCommands.hadAlreadyExited(detail)
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "pid": .int(pid),
                        "signal": .string(named),
                        "sent": .bool(!gone),
                        "alreadyExited": .bool(gone),
                    ]))
                return
            }
            CLIOut.out(
                gone
                    ? "\(pid) had already exited on \(runner.machine.name)"
                    : "sent SIG\(named) to \(pid) on \(runner.machine.name)")
        }
    }
}

struct MachinesBroadcastCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broadcast",
        abstract: "Run one command on every machine.",
        discussion: """
            The terminal's broadcast bar sends a line to every pane at once; this sends it
            to every configured machine instead. Each machine's output is labelled, a
            machine that cannot be reached is reported and the rest still run, and the exit
            code is 1 if any of them failed.

            Everything after the machine list is the command, verbatim, so flags belong
            before it: `ed machines broadcast --only tuf,box -- uptime`.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Only these machines, comma separated.")
    var only: String?

    @Argument(parsing: .remaining, help: "The command to run everywhere.")
    var command: [String]

    func run() async throws {
        try await execute {
            var words = command
            if words.first == "--" { words.removeFirst() }
            let line = words.joined(separator: " ")
            guard !line.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CLIFailure("give a command to run")
            }
            let all = MachineRegistry.machines()
            guard !all.isEmpty else {
                throw CLIFailure.notFound(
                    "no machines are configured", hint: "add one with `ed machines add`")
            }
            var targets = all
            if let only {
                let wanted = only.split(separator: ",").map {
                    $0.trimmingCharacters(in: .whitespaces)
                }
                targets = try wanted.map { try MachineResolver.machine($0) }
            }
            var rows: [JSONValue] = []
            var failed = false
            for machine in targets {
                let runner = RemoteRunner(machine: machine)
                var status: Int32 = 0
                var text = ""
                do {
                    try await runner.connect()
                    let result = try await runner.run(line, timeout: 120)
                    status = result.status
                    text = result.combinedText.trimmingCharacters(in: .whitespacesAndNewlines)
                } catch {
                    status = -1
                    text = error.localizedDescription
                }
                if status != 0 { failed = true }
                rows.append(
                    .object([
                        "machine": .string(machine.name),
                        "status": .int(Int(status)),
                        "output": .string(text),
                    ]))
                guard !json else { continue }
                CLIOut.out("== \(machine.name) ==")
                if !text.isEmpty { CLIOut.out(text) }
                if status != 0 { CLIOut.note("\(machine.name) exited \(status)") }
            }
            if json { CLIOut.json(.array(rows)) }
            guard failed else { return }
            throw ExitCode(ExitCodes.failure)
        }
    }
}
