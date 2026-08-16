import ArgumentParser
import EdithKit
import Foundation

struct MachinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machines",
        abstract: "The computers Edith can reach over SSH.",
        discussion: """
            Machines come from Edith's own machine list. Transport is /usr/bin/ssh over a
            ControlMaster socket shared with the app, so a command lands on an already
            open channel whenever the app or an earlier `ed` call opened one.

            The machine name comes first, subject then verb: `ed machines tuf docker ps`,
            `ed machines tuf files ls /etc`, `ed machines tuf uptime`. The older form with
            the machine last, `ed machines docker ps tuf`, still works. A subcommand name
            always wins, so a machine literally called `docker` or `ls` has to be named
            explicitly: `ed machines show docker`.

            `ed <machine> <command...>` is shorthand for `ed machines <machine> <command...>`.
            """,
        subcommands: [
            MachinesListCommand.self, MachinesShowCommand.self, MachinesAddCommand.self,
            MachinesEditCommand.self, MachinesRemoveCommand.self,
            MachinesForwardsCommand.self, MachinesSnippetsCommand.self,
            MachinesMetricsCommand.self,
            MachinesExecCommand.self, MachinesFilesCommand.self, MachinesDockerCommand.self,
            MachinesPowerCommand.self,
            MachinesKillCommand.self, MachinesBroadcastCommand.self,
            MachinesWorkspaceCommand.self,
            MachinesConnectCommand.self,
            MachinesDisconnectCommand.self,
            MachinesMountCommand.self, MachinesUnmountCommand.self,
            MachinesMountsCommand.self,
        ],
        defaultSubcommand: MachinesListCommand.self)
}

enum MachineResolver {
    static func machine(_ query: String) throws -> Machine {
        do {
            return try MachineDirectory.resolve(query, in: MachineDirectory.load())
        } catch let failure as CLIFailure where failure.kind == .notFound {
            let verbs = ArgumentRewriting.machineSubcommands.sorted().joined(separator: ", ")
            throw CLIFailure.notFound(
                failure.message,
                hint: [failure.hint, "machines subcommands: " + verbs]
                    .compactMap { $0 }.joined(separator: "; "))
        }
    }

    static func runner(_ query: String) async throws -> RemoteRunner {
        let runner = RemoteRunner(machine: try machine(query))
        try await runner.connect()
        return runner
    }
}

struct MachinesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List configured machines.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        let machines = MachineDirectory.load()
        guard !json else {
            CLIOut.json(.array(machines.map(MachineDirectory.summary)))
            return
        }
        guard !machines.isEmpty else {
            CLIOut.note("no machines are configured; add one with `ed machines add <name> <host>`")
            return
        }
        let rows = machines.map { machine in
            [
                machine.name, machine.subtitle, machine.auth.displayName,
                MachineDirectory.hasLiveControlSocket(machine) ? "connected" : "-",
            ]
        }
        CLIOut.out(TextTable.render(headers: ["NAME", "TARGET", "AUTH", "STATE"], rows: rows))
    }
}

struct MachinesShowCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "show", abstract: "One machine, with live facts.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let hello = try? await runner.text("uname -srm 2>/dev/null", timeout: 20)
            let uptime = try? await runner.text("uptime 2>/dev/null", timeout: 15)
            let who = try? await runner.text(MachineFacts.whoCommand, timeout: 15)
            let summary = MachineDirectory.summary(runner.machine)
            let facts = JSONValue.object([
                "machine": summary,
                "uname": .string(
                    (hello ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                "uptime": .string(
                    (uptime ?? "").trimmingCharacters(in: .whitespacesAndNewlines)),
                "sessions": .strings(MachineFacts.parseWho(who ?? "")),
            ])
            guard !json else {
                CLIOut.json(facts)
                return
            }
            CLIOut.out(runner.machine.name)
            CLIOut.out("  target   \(runner.machine.subtitle)")
            CLIOut.out("  auth     \(runner.machine.auth.displayName)")
            CLIOut.out(
                "  system   "
                    + (hello ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            CLIOut.out(
                "  uptime   "
                    + (uptime ?? "").trimmingCharacters(in: .whitespacesAndNewlines))
            for session in MachineFacts.parseWho(who ?? "") {
                CLIOut.out("  session  \(session)")
            }
        }
    }
}

struct MachinesMetricsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "metrics", abstract: "Sample a machine, once or continuously.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: [.long, .short], help: "Keep streaming until interrupted.")
    var follow = false

    @Option(help: "Seconds between samples when following.")
    var interval: Int = 2

    @Option(help: "Include this many top processes in each sample.")
    var processes: Int = 0

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let interval = try ArgumentChecks.positive(self.interval, "--interval")
            let processes = try ArgumentChecks.nonNegative(self.processes, "--processes")
            let runner = try await MachineResolver.runner(machine)
            guard let script = MachineCollector.script() else {
                throw CLIFailure("the metrics collector is missing from this build")
            }
            let command =
                follow ? "sh -s -- --stream -i \(max(1, interval))" : MachineCollector.onceCommand
            let sink = MetricsSink(json: json, processes: processes, follow: follow)
            let stream = try runner.stream(command: command, stdin: script) { line, isStderr in
                guard !isStderr else { return }
                sink.receive(line)
            }
            defer { stream.cancel() }
            _ = await stream.waitForExit()
            if !sink.sawSample {
                throw CLIFailure.unavailable(
                    "\(runner.machine.name) did not report metrics",
                    hint: "the collector needs a POSIX shell and awk on the machine")
            }
        }
    }
}

final class MetricsSink: @unchecked Sendable {
    private let lock = NSLock()
    private let json: Bool
    private let processes: Int
    private let follow: Bool
    private var hello: MachineHello?
    private var samples = 0

    init(json: Bool, processes: Int, follow: Bool) {
        self.json = json
        self.processes = processes
        self.follow = follow
    }

    var sawSample: Bool {
        lock.lock()
        defer { lock.unlock() }
        return samples > 0
    }

    func receive(_ line: String) {
        guard let record = MachineMetricsDecoder.decode(line: line) else { return }
        lock.lock()
        defer { lock.unlock() }
        switch record {
        case let .hello(value):
            hello = value
            if !json { CLIOut.out("\(value.host)  \(value.os)  \(value.cores) cores") }
        case let .sample(value):
            samples += 1
            emit(value)
        case .slow:
            break
        }
    }

    private func emit(_ sample: MachineSample) {
        guard json else {
            let memory = String(
                format: "%.0f%% of %@", sample.mem.usedPercent,
                ByteFormatter.string(sample.mem.totalKB * 1024))
            CLIOut.out(
                String(
                    format: "cpu %5.1f%%   mem %@   load %@   net down %@ up %@",
                    sample.cpu.total, memory,
                    sample.load.map { String(format: "%.2f", $0) }.joined(separator: " "),
                    ByteFormatter.rate(sample.net.rxBps),
                    ByteFormatter.rate(sample.net.txBps)))
            return
        }
        var payload: [String: JSONValue] = [
            "sample": MachineReports.sample(sample, processes: processes)
        ]
        if let hello { payload["host"] = MachineReports.hello(hello) }
        CLIOut.out(JSONSerializer.string(.object(payload), pretty: !follow))
    }
}

struct MachinesExecCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "exec",
        abstract: "Run a command on a machine, passing through both streams.",
        aliases: ["run"])

    @Flag(
        name: [.customLong("tty"), .customShort("t")],
        help: "Run it on a terminal, so vim, top, sudo prompts and docker exec -it work.")
    var tty = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @Argument(
        parsing: .captureForPassthrough,
        help: "The command to run. Everything after the machine name is sent verbatim.")
    var command: [String] = []

    func run() async throws {
        try await execute {
            let words = Self.strippingSeparator(command)
            guard !words.isEmpty else {
                throw CLIFailure("name a command to run, for example `ed \(machine) uptime`")
            }
            let runner = try await MachineResolver.runner(machine)
            if tty {
                let stored = MachineWorkingDirectory.load(machineID: runner.machine.id)
                let line = words.joined(separator: " ")
                let prefixed = MachineWorkingDirectory.prefixed(line, directory: stored)
                throw ExitCode(runner.interactive(words.isEmpty ? nil : prefixed))
            }
            let stored = MachineWorkingDirectory.load(machineID: runner.machine.id)
            guard !MachineWorkingDirectory.isChangeDirectory(words) else {
                try await changeDirectory(
                    to: words.count == 2 ? words[1] : nil, from: stored, runner: runner)
                return
            }
            let line = words.count == 1 ? words[0] : ShellQuote.command(words)
            let status = await runner.passthrough(
                MachineWorkingDirectory.prefixed(line, directory: stored))
            guard status == 0 else { throw ExitCode(status) }
        }
    }

    private func changeDirectory(
        to target: String?, from stored: String?, runner: RemoteRunner
    ) async throws {
        var wanted = target
        if wanted == MachineWorkingDirectory.previousMarker {
            guard let back = MachineWorkingDirectory.loadPrevious(machineID: runner.machine.id)
            else {
                throw CLIFailure(
                    "no previous directory for \(runner.machine.name) in this terminal")
            }
            wanted = back
        }
        let result = try await runner.run(
            MachineWorkingDirectory.resolveCommand(target: wanted, from: stored))
        guard result.succeeded,
            let resolved = MachineWorkingDirectory.resolvedDirectory(fromOutput: result.stdoutText)
        else {
            let detail = result.stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
            throw CLIFailure(
                "cannot change to \(target ?? "the home directory") on \(runner.machine.name)",
                hint: detail.isEmpty ? nil : detail)
        }
        let origin =
            MachineWorkingDirectory.originDirectory(fromOutput: result.stdoutText) ?? stored
        MachineWorkingDirectory.save(
            resolved, previous: origin, machineID: runner.machine.id)
    }

    static func strippingSeparator(_ words: [String]) -> [String] {
        guard words.first == "--" else { return words }
        return Array(words.dropFirst())
    }
}

struct MachinesConnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "connect", abstract: "Open the shared SSH connection to a machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let runner = try await MachineResolver.runner(machine)
            let latency = await runner.ssh.latencyMillis()
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(runner.machine.name),
                        "connected": .bool(true),
                        "latencyMillis": .optional(latency),
                    ]))
                return
            }
            CLIOut.out(
                latency.map { String(format: "connected, %.0f ms", $0) } ?? "connected")
        }
    }
}

struct MachinesDisconnectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disconnect", abstract: "Close the shared SSH connection to a machine.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let found = try MachineResolver.machine(machine)
            await RemoteRunner(machine: found).disconnect()
            guard !json else {
                CLIOut.json(
                    .object(["machine": .string(found.name), "connected": .bool(false)]))
                return
            }
            CLIOut.out("disconnected")
        }
    }
}
