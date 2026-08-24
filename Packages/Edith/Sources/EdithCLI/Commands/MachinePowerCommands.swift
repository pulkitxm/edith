import ArgumentParser
import EdithKit
import Foundation

struct MachinesPowerCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "power",
        abstract: "Restart, shut down or wake a machine.",
        discussion: """
            Restart and shut down use the remote machine's shutdown command and need privilege:
            `ed` tries `sudo -n` unless a sudo password is saved. A machine that
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
        _ operation: MachinePowerOperation, machine name: String, json: Bool, yes: Bool
    ) async throws {
        try await execute {
            let target = try MachineResolver.machine(name)
            let request = MachinePowerOperationExecution.command(
                for: operation, machineID: target.id)
            let command = request?.command ?? ""
            guard yes else {
                guard !json else {
                    CLIOut.json(
                        .object([
                            "machine": .string(target.name),
                            "action": .string(operation.rawValue),
                            "applied": .bool(false),
                            "command": .string(command),
                        ]))
                    return
                }
                CLIOut.out(
                    operation == .reboot
                        ? "would restart \(target.name)" : "would shut \(target.name) down")
                CLIOut.note("nothing was done; pass --yes to go ahead")
                return
            }
            let runner = try await MachineResolver.runner(name)
            let outcome = await MachinePowerOperationExecution.perform(
                operation, machine: target,
                sudoPassword: { _ in request?.stdin },
                run: { command, stdin, timeout in
                    do {
                        let result = try await runner.ssh.run(
                            command, stdin: stdin, timeout: timeout)
                        guard result.succeeded else {
                            return .failure(
                                SSHConnectionError.commandFailed(
                                    command: command, status: result.status,
                                    stderr: result.combinedText))
                        }
                        return .success(result.combinedText)
                    } catch {
                        return .failure(error)
                    }
                })
            switch outcome {
            case .success:
                try report(operation, machine: target.name, json: json)
            case let .failure(error):
                throw refusal(
                    operation, machine: target.name, detail: PowerOutcome.explain(error))
            }
        }
    }

    static func refusal(
        _ operation: MachinePowerOperation, machine: String, detail: String
    ) -> CLIFailure {
        let trimmed = detail.trimmingCharacters(in: .whitespacesAndNewlines)
        let message = trimmed.isEmpty ? "\(machine) refused to \(operation.rawValue)" : trimmed
        return CLIFailure(
            "\(machine) did not \(operation.rawValue): \(message)",
            hint: SudoPassword.hint(forRefusal: trimmed))
    }

    static func report(
        _ operation: MachinePowerOperation, machine: String, json: Bool
    ) throws {
        guard !json else {
            CLIOut.json(
                .object([
                    "machine": .string(machine),
                    "action": .string(operation.rawValue),
                    "applied": .bool(true),
                ]))
            return
        }
        CLIOut.out(
            operation == .reboot
                ? "\(machine) is restarting" : "\(machine) is shutting down")
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
        try await PowerBridge.apply(.reboot, machine: machine, json: json, yes: yes)
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
        try await PowerBridge.apply(.shutdown, machine: machine, json: json, yes: yes)
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
            let outcome = await MachinePowerOperationExecution.perform(
                .wake, machine: target)
            let result: MachinePowerResult
            switch outcome {
            case let .success(value):
                result = value
            case let .failure(error as MachinePowerOperationError):
                guard case .missingWakeAddress = error else {
                    throw CLIFailure(error.localizedDescription)
                }
                throw CLIFailure.unavailable(
                    "no MAC address is stored for \(target.name)",
                    hint:
                        "open the machine in Edith while it is up so it can learn one, or set it "
                        + "with `ed machines edit \(target.name) --mac <address>`")
            case let .failure(error):
                throw CLIFailure(error.localizedDescription)
            }
            let mac = result.macAddress ?? ""
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
    static func apply(
        _ operation: MachineServiceOperation, machine name: String, unit: String, json: Bool
    )
        async throws
    {
        try await execute {
            let runner = try await MachineResolver.runner(name)
            let stdin = SudoPassword.stdin(machineID: runner.machine.id)
            let result = await MachineServiceOperationExecution.perform(
                operation, unit: unit, sudoPassword: stdin,
                using: { command, stdin, timeout in
                    do {
                        let output = try await runner.run(
                            command, stdin: stdin, timeout: timeout)
                        let detail = output.combinedText.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        guard output.succeeded, !PowerOutcome.needsPrivilege(detail) else {
                            return .failure(
                                CLIFailure(
                                    "could not \(operation.rawValue) \(unit) on "
                                        + runner.machine.name
                                        + (detail.isEmpty ? "" : ": \(detail)"),
                                    hint: SudoPassword.hint(forRefusal: detail)))
                        }
                        return .success(output.combinedText)
                    } catch {
                        return .failure(error)
                    }
                })
            if case let .failure(error) = result {
                throw error
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "unit": .string(unit),
                        "action": .string(operation.rawValue),
                        "applied": .bool(true),
                    ]))
                return
            }
            CLIOut.out("\(operation.rawValue)ed \(unit) on \(runner.machine.name)")
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
        try await ServiceBridge.apply(.start, machine: machine, unit: unit, json: json)
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
        try await ServiceBridge.apply(.stop, machine: machine, unit: unit, json: json)
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
        try await ServiceBridge.apply(.restart, machine: machine, unit: unit, json: json)
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

    @Flag(help: "Actually send KILL. TERM and other signals do not require this.")
    var yes = false

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
            let target = try MachineResolver.machine(machine)
            let plan =
                named == "KILL"
                ? CLIDestructivePlan(
                    action: "send SIGKILL", targets: ["\(target.name):pid:\(pid)"],
                    confirmed: yes, json: json,
                    fields: [
                        "machine": .string(target.name), "pid": .int(pid),
                        "signal": .string(named),
                    ])
                : nil
            guard plan?.shouldApply() ?? true else { return }
            let runner = try await MachineResolver.runner(machine)
            let result = await MachineProcessOperationExecution.perform(
                pid: pid, signal: named,
                using: { command, timeout in
                    do {
                        let output = try await runner.run(command, timeout: timeout)
                        let detail = output.combinedText.trimmingCharacters(
                            in: .whitespacesAndNewlines)
                        guard output.succeeded else {
                            return .failure(
                                CLIFailure(
                                    "could not signal \(pid) on \(runner.machine.name)"
                                        + (detail.isEmpty ? "" : ": \(detail)")))
                        }
                        return .success(output.combinedText)
                    } catch {
                        return .failure(error)
                    }
                })
            let outcome: MachineProcessOperationResult
            switch result {
            case let .success(value):
                outcome = value
            case let .failure(error):
                throw error
            }
            let gone = outcome.alreadyExited
            if let plan {
                plan.finish(
                    changed: !gone,
                    plain: gone
                        ? "\(pid) had already exited on \(runner.machine.name)"
                        : "sent SIG\(named) to \(pid) on \(runner.machine.name)",
                    fields: ["sent": .bool(!gone), "alreadyExited": .bool(gone)])
                return
            }
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
            let plan: MachineBroadcastPlan
            switch MachineBroadcastOperationExecution.plan(words: command) {
            case let .success(value):
                plan = value
            case .failure(MachineBroadcastOperationError.emptyCommand):
                throw CLIFailure("give a command to run")
            case let .failure(error):
                throw error
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
                    let result = try await runner.run(plan.command, timeout: 120)
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

struct MachinesTerminalCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "terminal",
        abstract: "Act on terminal tabs that are open in the Edith app.",
        subcommands: [MachinesTerminalBroadcastCommand.self],
        defaultSubcommand: MachinesTerminalBroadcastCommand.self)
}

enum MachineTerminalBroadcastCLI {
    static func machine(_ query: String) throws -> Machine {
        if UsageMachineFilter.isLocal(query) { return .local }
        let machines = [Machine.local] + MachineDirectory.load().filter { $0.id != Machine.localID }
        return try MachineDirectory.resolve(query, in: machines)
    }

    static func send(
        _ plan: MachineBroadcastPlan, to machine: Machine, timeout: TimeInterval = 5
    ) async throws -> Int {
        try Task.checkCancellation()
        try AppBridge.requireMainApp("broadcasting to open machine terminals")
        let requestID = UUID().uuidString
        let payload: [String: Any] = [
            MachineTerminalBroadcastIPC.requestIDKey: requestID,
            MachineTerminalBroadcastIPC.machineIDKey: machine.id.uuidString,
            MachineTerminalBroadcastIPC.commandKey: plan.command,
        ]
        try Task.checkCancellation()
        guard
            let reply = await AppBridge.awaitReply(
                IPC.Name.machineTerminalBroadcastResult, timeout: timeout,
                matching: {
                    $0[MachineTerminalBroadcastIPC.requestIDKey] as? String == requestID
                },
                trigger: {
                    AppBridge.post(
                        IPC.Name.requestMachineTerminalBroadcast, userInfo: payload)
                })
        else {
            throw AppBridge.silence("the terminal broadcast")
        }
        guard reply[MachineTerminalBroadcastIPC.requestIDKey] as? String == requestID else {
            throw CLIFailure("Edith returned an unrelated terminal broadcast result")
        }
        guard reply[MachineTerminalBroadcastIPC.okKey] as? Bool == true else {
            let detail =
                reply[MachineTerminalBroadcastIPC.errorKey] as? String
                ?? "the terminal broadcast failed"
            if reply[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.noOpenTabsCode
            {
                throw CLIFailure.notFound(
                    detail,
                    hint: "open a terminal tab for \(machine.name) in Edith, then retry")
            }
            if reply[MachineTerminalBroadcastIPC.errorCodeKey] as? String
                == MachineTerminalBroadcastIPC.noLiveTabsCode
            {
                throw CLIFailure.notFound(
                    detail,
                    hint: "start a terminal tab for \(machine.name) in Edith, then retry")
            }
            throw CLIFailure(detail)
        }
        guard let count = reply[MachineTerminalBroadcastIPC.tabCountKey] as? Int, count > 0 else {
            throw CLIFailure("Edith returned an invalid terminal broadcast result")
        }
        return count
    }
}

struct MachinesTerminalBroadcastCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "broadcast",
        abstract: "Send one line to every open terminal tab for one machine.",
        discussion: """
            This uses the terminal sessions already open in the Edith main app. Use
            `ed machines broadcast` to run a separate SSH command across the configured fleet.
            Put `--` before a command that contains flags.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(parsing: .remaining, help: "The line to send to every open terminal tab.")
    var command: [String]

    func run() async throws {
        try await execute {
            let target = try MachineTerminalBroadcastCLI.machine(machine)
            let plan: MachineBroadcastPlan
            switch MachineBroadcastOperationExecution.plan(words: command) {
            case let .success(value):
                plan = value
            case .failure(MachineBroadcastOperationError.emptyCommand):
                throw CLIFailure.usage("give a command to broadcast to the open tabs")
            case let .failure(error):
                throw error
            }
            let tabCount = try await MachineTerminalBroadcastCLI.send(plan, to: target)
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(target.name),
                        "machineID": .string(target.id.uuidString),
                        "command": .string(plan.command),
                        "tabs": .int(tabCount),
                    ]))
                return
            }
            let noun = tabCount == 1 ? "tab" : "tabs"
            CLIOut.out("sent to \(tabCount) open \(noun) on \(target.name): \(plan.command)")
        }
    }
}
