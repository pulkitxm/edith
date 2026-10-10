import ArgumentParser
import EdithExtensionCommands
import EdithExtensionSupport
import Foundation

struct UsageMachinesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "machines",
        abstract: "Show machines whose agent usage is counted with this Mac's.",
        discussion: """
            `ed usage machines collect <machine>` runs the collector Edith runs here
            over SSH instead, brings the numbers back and folds them into the same
            usage.json the dashboard reads. The machine's agents arrive as their own
            stable `machine:<uuid>:<agent>` sources, so renaming a machine does not
            split its history. `ed usage summary` counts the fleet and `--source`
            still narrows to one agent on one machine.

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

@MainActor enum UsageMachineBridge {
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

    static func merge(progress: CLIProgress) async -> Bool {
        progress.begin("folding it in")
        defer { progress.end() }
        do {
            _ = try await UsageCLIEnvironment.refresh(follow: false, policy: .skip)
            return true
        } catch {
            progress.note("could not fold it in: " + error.localizedDescription)
            return false
        }
    }
}

struct UsageMachinesListCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "ls", abstract: "Show every machine, and what its usage adds up to.",
        discussion: """
            Show every machine, and what its usage adds up to.

            Reads the saved records in stored order. Does not change them.

            ed usage machines ls
            ed usage machines ls --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @MainActor func run() async throws {
        try await execute {
            let machines = UsageCLIEnvironment.machines()
            guard !machines.isEmpty else {
                throw CLIFailure.notFound(
                    "no machines are configured",
                    hint: "add one in Edith under Machines, then run `ed machines ls`")
            }
            let summaries = Dictionary(
                uniqueKeysWithValues: try machines.compactMap { machine in
                    try UsageCLIMachines.summary(machine).map { (machine.id, $0) }
                })
            let counted = UsageCLIMachines.selected
            guard !json else {
                CLIOut.json(
                    .array(
                        machines.map {
                            UsageMachineBridge.json(
                                machine: $0, counted: counted.contains($0.id),
                                summary: summaries[$0.id])
                        }))
                return
            }
            let rows = machines.map {
                UsageMachineBridge.row(
                    machine: $0, counted: counted.contains($0.id),
                    summary: summaries[$0.id])
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
            Changes the state this command names.

            ed usage machines collect
            ed usage machines collect --json
            """)

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Flag(help: "Print everything the collector said on the machine.")
    var verbose = false

    @Flag(help: "Collect once without signing the machine up for later runs.")
    var once = false

    @Option(help: "Give up on a machine after this many seconds.")
    var timeout: Int = 900

    @Argument(help: "Machine name, ssh alias or id. Omit for every machine that takes part.")
    var machine: String?

    @MainActor func run() async throws {
        try await execute {
            let seconds = TimeInterval(try ArgumentChecks.positive(timeout, "--timeout"))
            guard seconds <= 1_800 else {
                throw CLIFailure.usage("--timeout cannot exceed 1800 seconds")
            }
            let machines = UsageCLIEnvironment.machines()
            let targets = try targets(in: machines, store: SharedDefaults.store)
            let progress = CLIProgress.forCommand(json: json)
            progress.header(
                "EDITH · collect usage · " + ISO8601DateFormatter().string(from: Date()))
            progress.begin("reaching \(targets.count == 1 ? targets[0].name : "the machines")")

            let round = try await UsageCLIMachines.collect(
                targets, once: once, timeout: seconds, verbose: verbose)
            progress.end()
            if round.skippedBecauseBusy {
                throw CLIFailure.unavailable(
                    "another collection is already running",
                    hint: "wait for it to finish, then retry")
            }
            let merged = await Self.merge(round, progress: progress)

            guard !json else {
                CLIOut.json(Self.payload(round, merged: merged))
                guard round.collected.isEmpty, let first = round.failures.first else { return }
                throw CLIFailure.unavailable("\(first.machine): \(first.reason)")
            }
            for failure in round.failures {
                CLIOut.note("error: \(failure.machine): \(failure.reason)")
            }
            guard !round.collected.isEmpty else {
                guard let first = round.failures.first else { return }
                throw CLIFailure.unavailable("\(first.machine): \(first.reason)")
            }
            let rows = round.collected.map { summary in
                [
                    summary.name, String(summary.sources.count), String(summary.days),
                    String(format: "%.2f", summary.cost), String(Int(summary.tokens)),
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["MACHINE", "SOURCES", "DAYS", "COST", "TOKENS"], rows: rows))
            CLIOut.out(
                merged
                    ? "folded into the dashboard"
                    : "run `ed usage refresh` to fold this into the dashboard")
        }
    }

    static func merge(_ round: MachineUsageRoundResult, progress: CLIProgress) async -> Bool {
        guard round.changedAnything else { return false }
        return await UsageMachineBridge.merge(progress: progress)
    }

    static func payload(_ round: MachineUsageRoundResult, merged: Bool) -> JSONValue {
        .object([
            "collected": .array(
                round.collected.map { summary in
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
                round.failures.map {
                    .object(["machine": .string($0.machine), "error": .string($0.reason)])
                }),
            "merged": .bool(merged),
        ])
    }

    @MainActor private func targets(in machines: [Machine], store: UserDefaults) throws -> [Machine]
    {
        if let machine {
            return [try UsageCLIMachines.resolve(machine)]
        }
        let chosen = machines.filter { UsageCLIMachines.selected.contains($0.id) }
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
        commandName: "enable", abstract: "Count this machine on every usage refresh.",
        discussion: """
            Count this machine on every usage refresh.

            Reads the current state. Does not change it.

            ed usage machines enable box
            ed usage machines enable box --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @MainActor func run() async throws {
        try await execute {
            let found = try UsageCLIMachines.resolve(machine)
            UsageCLIMachines.setCounted(true, id: found.id)
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
        abstract: "Stop collecting from this machine, keeping what it already gave.",
        discussion: """
            Stop collecting from this machine, keeping what it already gave.

            Changes the state this command names.

            ed usage machines disable box
            ed usage machines disable box --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @MainActor func run() async throws {
        try await execute {
            let found = try UsageCLIMachines.resolve(machine)
            UsageCLIMachines.setCounted(false, id: found.id)
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
        abstract: "Drop what a machine gave and stop collecting from it.",
        discussion: """
            Drop what a machine gave and stop collecting from it.

            Changes companion memory by deleting one conversation and its messages.

            ed usage machines forget box
            ed usage machines forget box --json
            """, )

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Argument(help: "Machine name, ssh alias or id.")
    var machine: String

    @MainActor func run() async throws {
        try await execute {
            let id = try identify()
            let dropped = FileManager.default.fileExists(
                atPath: Repo.dataDir.appendingPathComponent(
                    "machines/" + id.uuidString.lowercased() + ".json"
                ).path)
            try await UsageWorkerOperations.forgetMachine(id)
            UsageCLIMachines.setCounted(false, id: id)
            let progress = CLIProgress.forCommand(json: json)
            let merging =
                dropped ? await UsageMachineBridge.merge(progress: progress) : false
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

    @MainActor private func identify() throws -> UUID {
        do {
            return try UsageCLIMachines.resolve(machine).id
        } catch let failure as CLIFailure {
            guard let id = UUID(uuidString: machine) else { throw failure }
            return id
        }
    }
}
