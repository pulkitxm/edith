import Darwin
import ArgumentParser
import EdithKit
import Foundation

struct SystemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "Metrics for this Mac.",
        subcommands: [SystemStatsCommand.self, SystemDisksCommand.self, SystemAgentsCommand.self],
        defaultSubcommand: SystemStatsCommand.self)
}

struct SystemStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats", abstract: "Sample CPU, memory, load and network for this Mac.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(name: [.long, .short], help: "Keep sampling until interrupted.")
    var follow = false

    @Option(help: "Seconds between samples when following.")
    var interval: Double = 2

    @Option(help: "Include this many top processes in each sample.")
    var processes: Int = 0

    func run() async throws {
        try await execute {
            let interval = try ArgumentChecks.positive(self.interval, "--interval")
            let processes = try ArgumentChecks.nonNegative(self.processes, "--processes")
            let sampler = LocalMachineSampler()
            let hello = sampler.hello()
            _ = await sampler.sample()
            try await Task.sleep(for: .milliseconds(500))
            var first = true
            repeat {
                if !first { try await Task.sleep(for: .seconds(max(0.5, interval))) }
                let sample = await sampler.sample()
                let payload = JSONValue.object([
                    "host": MachineReports.hello(hello),
                    "sample": MachineReports.sample(sample, processes: processes),
                ])
                if json {
                    CLIOut.out(JSONSerializer.string(payload, pretty: !follow))
                } else {
                    printHuman(hello: hello, sample: sample, header: first)
                }
                first = false
            } while follow
        }
    }

    private func printHuman(hello: MachineHello, sample: MachineSample, header: Bool) {
        if header {
            CLIOut.out("\(hello.host)  \(hello.os)  \(hello.cores) cores")
        }
        let memory = String(
            format: "%.0f%% of %@", sample.mem.usedPercent,
            ByteFormatter.string(sample.mem.totalKB * 1024))
        let load = sample.load.map { String(format: "%.2f", $0) }.joined(separator: " ")
        CLIOut.out(
            String(
                format: "cpu %5.1f%%   mem %@   load %@   net down %@ up %@",
                sample.cpu.total, memory, load, ByteFormatter.rate(sample.net.rxBps),
                ByteFormatter.rate(sample.net.txBps)))
        guard processes > 0 else { return }
        let rows = sample.procs.prefix(processes).map { process in
            [
                String(process.pid), process.user, String(format: "%.1f", process.cpu),
                String(format: "%.1f", process.mem), process.name,
            ]
        }
        CLIOut.out(
            TextTable.render(headers: ["PID", "USER", "CPU", "MEM", "NAME"], rows: rows))
    }
}

struct SystemDisksCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disks", abstract: "Mounted volumes and their free space.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        let slow = LocalMachineSampler().slow()
        guard !json else {
            CLIOut.json(MachineReports.slow(slow))
            return
        }
        let rows = slow.disks.map { disk in
            [
                disk.fs, disk.mount, ByteFormatter.string(disk.totalKB * 1024),
                ByteFormatter.string(disk.availKB * 1024),
                String(format: "%.0f%%", disk.usedPercent),
            ]
        }
        CLIOut.out(
            TextTable.render(headers: ["VOLUME", "MOUNT", "SIZE", "FREE", "USED"], rows: rows))
    }
}

struct SystemAgentsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agents",
        abstract: "List or stop agent processes.",
        subcommands: [SystemAgentsListCommand.self, SystemAgentsKillCommand.self],
        defaultSubcommand: SystemAgentsListCommand.self)
}

struct AgentProcessSnapshot: Sendable {
    let pid: pid_t
    let name: String
    let cpuPercent: Double
    let memoryMB: Double
}

enum AgentProcessCatalog {
    static func names() -> [(pid_t, String)] {
        let needed = proc_listallpids(nil, 0)
        guard needed > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(needed) * 2)
        let count = proc_listallpids(
            &pids, Int32(pids.count) * Int32(MemoryLayout<pid_t>.size))
        guard count > 0 else { return [] }
        return pids.prefix(Int(count)).compactMap { pid in
            guard pid > 0, let name = name(for: pid), AgentProcessFilter.isAgentProcess(name: name)
            else { return nil }
            return (pid, name)
        }
    }

    static func name(for pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_name(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return String(cString: buffer)
    }

    static func sample() async -> [AgentProcessSnapshot] {
        let mine = ProcessInfo.processInfo.processIdentifier
        let first = names().filter { $0.0 != mine }
        let previous = Dictionary(
            uniqueKeysWithValues: first.map { ($0.0, ProcessUsage.sample(pid: $0.0)) })
        let started = Date()
        try? await Task.sleep(for: .milliseconds(250))
        let now = Date()
        return names().compactMap { pid, name in
            guard pid != mine, let prior = previous[pid] else { return nil }
            let current = ProcessUsage.sample(pid: pid)
            return AgentProcessSnapshot(
                pid: pid,
                name: name,
                cpuPercent: ProcessUsage.cpuPercent(
                    nowNS: current.cpuNS, previousNS: prior.cpuNS,
                    elapsed: now.timeIntervalSince(started)),
                memoryMB: current.memMB)
        }
        .sorted { left, right in
            if left.cpuPercent == right.cpuPercent { return left.name < right.name }
            return left.cpuPercent > right.cpuPercent
        }
    }

    static func json(_ process: AgentProcessSnapshot) -> JSONValue {
        .object([
            "pid": .int(Int(process.pid)),
            "name": .string(process.name),
            "cpuPercent": .double(process.cpuPercent),
            "memoryMB": .double(process.memoryMB),
        ])
    }
}

struct SystemAgentsListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "List Claude and other agent processes.", aliases: ["list"])

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(help: "Show at most this many processes. Pass 0 for all of them.")
    var limit: Int = 0

    func run() async throws {
        try await execute {
            let limit = try ArgumentChecks.nonNegative(self.limit, "--limit")
            let all = await AgentProcessCatalog.sample()
            let shown = limit == 0 ? all : Array(all.prefix(limit))
            guard !json else {
                CLIOut.json(.array(shown.map(AgentProcessCatalog.json)))
                return
            }
            let rows = shown.map { process in
                [
                    String(process.pid), process.name, String(format: "%.1f", process.cpuPercent),
                    String(format: "%.1f", process.memoryMB),
                ]
            }
            CLIOut.out(TextTable.render(headers: ["PID", "NAME", "CPU", "MEMORY MB"], rows: rows))
        }
    }
}

struct SystemAgentsKillCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill", abstract: "Stop one agent process.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Send SIGKILL instead of SIGTERM.")
    var force = false

    @Argument(help: "The agent process id.")
    var pid: Int

    func run() async throws {
        try await execute {
            guard pid > 0 else { throw CLIFailure.usage("pid must be greater than zero") }
            let target = pid_t(pid)
            guard target != ProcessInfo.processInfo.processIdentifier,
                let name = AgentProcessCatalog.name(for: target),
                AgentProcessFilter.isAgentProcess(name: name)
            else {
                throw CLIFailure.notFound(
                    "pid (pid) is not a known agent process",
                    hint: "run `ed system agents ls` to see eligible processes")
            }
            let signal = force ? SIGKILL : SIGTERM
            guard Darwin.kill(target, signal) == 0 else {
                throw CLIFailure(
                    "could not stop (name) (pid (pid)): (String(cString: strerror(errno)))")
            }
            guard !json else {
                CLIOut.json(
                    .object([
                        "pid": .int(pid), "name": .string(name),
                        "signal": .string(force ? "KILL" : "TERM"),
                    ]))
                return
            }
            let signalName = force ? "SIGKILL" : "SIGTERM"
            CLIOut.out("sent \(signalName) to \(name) (pid \(pid))")
        }
    }
}
