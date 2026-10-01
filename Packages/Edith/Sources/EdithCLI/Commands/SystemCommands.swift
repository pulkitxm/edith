import ArgumentParser
import EdithKit
import Foundation

struct SystemCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "system",
        abstract: "Read CPU, memory, disk, and network metrics for this Mac.",
        discussion: """
            Sample this Mac locally. Reads host, CPU, memory, load, network, and volumes.
            Does not change system settings.

            ed system stats
            ed system disks --json
            """,
        subcommands: [SystemStatsCommand.self, SystemDisksCommand.self],
        defaultSubcommand: SystemStatsCommand.self)
}

struct SystemStatsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stats",
        abstract: "Sample CPU, memory, load and network for this Mac.",
        discussion: """
            Take one sample of this Mac, or keep sampling with --follow. Reads the local
            sampler. Does not change power, network, or processes. --processes adds the
            busiest processes to each sample. With --json --follow, each sample is one
            compact JSON line.

            ed system stats
            ed system stats --follow --interval 2 --processes 5
            ed system stats --json
            """)

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
        commandName: "disks",
        abstract: "List mounted volumes and their free space.",
        discussion: """
            List mounted volumes with size, free space, and used percent. Reads the local
            disk sampler. Does not change mounts.

            ed system disks
            ed system disks --json
            """)

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
