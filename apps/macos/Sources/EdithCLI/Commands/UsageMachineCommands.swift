import ArgumentParser
import EdithKit
import Foundation

struct UsageMachinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machines",
        abstract: "Machines whose agent usage is counted with this Mac's.",
        discussion: """
            `ed usage machines collect <machine>` runs the collector Edith runs here
            over SSH instead, brings the numbers back and folds them into the same
            usage.json the dashboard reads. The machine's agents arrive as their own
            sources, named after it, so `ed usage summary` counts the fleet and
            `--source` still narrows to one agent on one machine.

            Anything the collector needs and cannot find there (jq, bun, ccusage) is
            installed under ~/.cache/edith on that machine, which is why collecting
            waits to be asked rather than happening for every machine you have.
            """,
        subcommands: [
            UsageMachinesListCommand.self, UsageMachinesCollectCommand.self,
            UsageMachinesEnableCommand.self, UsageMachinesDisableCommand.self,
            UsageMachinesForgetCommand.self,
        ],
        defaultSubcommand: UsageMachinesListCommand.self)
}

enum UsageMachineBridge {
    static func stored(_ machineID: UUID) -> MachineUsageSummary? {
        MachineUsageStore.summary(machineID: machineID)
    }

    static func json(machine: Machine, counted: Bool, summary: MachineUsageSummary?)
        -> JSONValue
    {
        .object([
            "machine": .string(machine.name),
            "id": .string(machine.id.uuidString),
            "counted": .bool(counted),
            "collectedAt": .optional(
                summary.map { JSONSerializer.iso.string(from: $0.collectedAt) }),
            "host": .optional(summary?.host),
            "sources": .array((summary?.sources ?? []).map { .string($0) }),
            "days": .int(summary?.days ?? 0),
            "cost": .double(summary?.cost ?? 0),
            "tokens": .double(summary?.tokens ?? 0),
        ])
    }

    static func row(machine: Machine, counted: Bool, summary: MachineUsageSummary?) -> [String] {
        [
            machine.name,
            counted ? "yes" : "no",
            summary.map { JSONSerializer.iso.string(from: $0.collectedAt) } ?? "-",
            summary.map { String($0.sources.count) } ?? "-",
            summary.map { String(format: "%.2f", $0.cost) } ?? "-",
            summary.map { String(Int($0.tokens)) } ?? "-",
        ]
    }

    static let headers = ["MACHINE", "COUNTED", "COLLECTED", "SOURCES", "COST", "TOKENS"]

    static func askTheAppToMerge() -> Bool {
        guard AppBridge.helperIsRunning else { return false }
        AppBridge.post(IPC.Name.requestUsageRefresh)
        return true
    }
}

struct UsageMachinesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Every machine, and what its usage adds up to.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let machines = MachineDirectory.load()
            guard !machines.isEmpty else {
                throw CLIFailure.notFound(
                    "no machines are configured",
                    hint: "add one in Edith under Machines, then run `ed machines ls`")
            }
            let counted = MachineUsageSelection.machineIDs()
            guard !json else {
                CLIOut.json(
                    .array(
                        machines.map {
                            UsageMachineBridge.json(
                                machine: $0, counted: counted.contains($0.id),
                                summary: UsageMachineBridge.stored($0.id))
                        }))
                return
            }
            let rows = machines.map {
                UsageMachineBridge.row(
                    machine: $0, counted: counted.contains($0.id),
                    summary: UsageMachineBridge.stored($0.id))
            }
            CLIOut.out(TextTable.render(headers: UsageMachineBridge.headers, rows: rows))
        }
    }
}

struct UsageMachinesCollectCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "collect",
        abstract: "Run the collector on a machine and bring its usage back.",
        discussion: """
            With no machine named, every machine that takes part is collected. Naming
            one collects it and signs it up, unless `--once` is passed. The first run
            on a machine installs what it needs and can take a few minutes.
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Print everything the collector said on the machine.")
    var verbose = false

    @Flag(help: "Collect once without signing the machine up for later runs.")
    var once = false

    @Option(help: "Give up on a machine after this many seconds.")
    var timeout: Int = Int(MachineUsageCollector.defaultTimeout)

    @Argument(help: "Machine name, ssh alias or id. Omit for every machine that takes part.")
    var machine: String?

    func run() async throws {
        try await execute {
            let seconds = TimeInterval(try ArgumentChecks.positive(timeout, "--timeout"))
            let machines = MachineDirectory.load()
            let targets = try targets(in: machines)
            let slugs = MachineUsageSlug.slugs(for: machines)

            var collected: [MachineUsageSummary] = []
            var failures: [(String, String)] = []
            for target in targets {
                let slug = slugs[target.id] ?? MachineUsageSlug.slug(for: target.name)
                do {
                    let runner = try await MachineResolver.runner(target.name)
                    let run = try await MachineUsageCollector.collect(
                        machine: target, slug: slug, over: runner.ssh, timeout: seconds)
                    if verbose { CLIOut.note(run.log) }
                    collected.append(run.summary)
                    if !once { MachineUsageSelection.include(target.id) }
                } catch {
                    failures.append((target.name, error.localizedDescription))
                }
            }
            MachineUsageStore.prune(keeping: machines.map(\.id))
            let merging = collected.isEmpty ? false : UsageMachineBridge.askTheAppToMerge()

            guard !json else {
                CLIOut.json(
                    .object([
                        "collected": .array(
                            collected.map { summary in
                                .object([
                                    "machine": .string(summary.name),
                                    "id": .string(summary.machineID.uuidString),
                                    "sources": .array(summary.sources.map { .string($0) }),
                                    "days": .int(summary.days),
                                    "cost": .double(summary.cost),
                                    "tokens": .double(summary.tokens),
                                ])
                            }),
                        "failed": .array(
                            failures.map {
                                .object(["machine": .string($0.0), "error": .string($0.1)])
                            }),
                        "merging": .bool(merging),
                    ]))
                guard collected.isEmpty, let first = failures.first else { return }
                throw CLIFailure.unavailable("\(first.0): \(first.1)")
            }

            for failure in failures {
                CLIOut.note("error: \(failure.0): \(failure.1)")
            }
            guard !collected.isEmpty else {
                guard let first = failures.first else { return }
                throw CLIFailure.unavailable("\(first.0): \(first.1)")
            }
            let rows = collected.map { summary in
                [
                    summary.name, String(summary.sources.count), String(summary.days),
                    String(format: "%.2f", summary.cost), String(Int(summary.tokens)),
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["MACHINE", "SOURCES", "DAYS", "COST", "TOKENS"], rows: rows))
            CLIOut.out(
                merging
                    ? "Edith is folding this into the dashboard"
                    : "start Edith, or run `ed usage refresh`, to fold this into the dashboard")
        }
    }

    private func targets(in machines: [Machine]) throws -> [Machine] {
        if let machine {
            return [try MachineResolver.machine(machine)]
        }
        let chosen = MachineUsageSelection.included(in: machines)
        guard !chosen.isEmpty else {
            throw CLIFailure.notFound(
                "no machine is counted towards usage yet",
                hint: "run `ed usage machines collect <machine>` to add the first one")
        }
        return chosen
    }
}

struct UsageMachinesEnableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "enable", abstract: "Count this machine on every usage refresh.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let found = try MachineResolver.machine(machine)
            MachineUsageSelection.include(found.id)
            guard !json else {
                CLIOut.json(
                    .object(["machine": .string(found.name), "counted": .bool(true)]))
                return
            }
            CLIOut.out("\(found.name) is counted towards usage")
        }
    }
}

struct UsageMachinesDisableCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "disable",
        abstract: "Stop collecting from this machine, keeping what it already gave.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let found = try MachineResolver.machine(machine)
            MachineUsageSelection.exclude(found.id)
            guard !json else {
                CLIOut.json(
                    .object(["machine": .string(found.name), "counted": .bool(false)]))
                return
            }
            CLIOut.out("\(found.name) is no longer collected; run `forget` to drop its numbers")
        }
    }
}

struct UsageMachinesForgetCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "forget",
        abstract: "Drop what a machine gave and stop collecting from it.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    func run() async throws {
        try await execute {
            let id = try identify()
            let dropped = MachineUsageStore.forget(machineID: id)
            MachineUsageSelection.exclude(id)
            let merging = dropped ? UsageMachineBridge.askTheAppToMerge() : false
            guard !json else {
                CLIOut.json(
                    .object([
                        "machine": .string(machine), "dropped": .bool(dropped),
                        "merging": .bool(merging),
                    ]))
                return
            }
            CLIOut.out(
                dropped
                    ? "dropped the usage collected from \(machine); it is no longer counted"
                    : "nothing stored")
        }
    }

    private func identify() throws -> UUID {
        do {
            return try MachineResolver.machine(machine).id
        } catch let failure as CLIFailure {
            guard let id = UUID(uuidString: machine) else { throw failure }
            return id
        }
    }
}
