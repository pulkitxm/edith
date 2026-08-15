import ArgumentParser
import EdithKit
import Foundation

struct CompanionHostsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "hosts",
        abstract: "Machines that could run the companion, and what each one needs.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    @Option(name: .long, help: "Probe only this machine.")
    var machine: String?

    func run() async throws {
        try await execute {
            let hosts = await CompanionHostProbing.hosts(only: machine)
            let deployment = CompanionDeploymentStore.load()
            guard !json else {
                CLIOut.json(
                    .object([
                        "hosts": .array(hosts.map(CompanionHostsCommand.hostJSON)),
                        "deployment": deployment.map(CompanionHostsCommand.deploymentJSON)
                            ?? .null,
                    ]))
                return
            }
            let rows = hosts.map { host -> [String] in
                [
                    host.hostsTheStack ? "* \(host.name)" : host.name,
                    host.isLocal ? "this Mac" : host.target,
                    host.canHostTheStack ? "ready" : host.blockers.first?.headline ?? "blocked",
                    host.summary,
                ]
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["NAME", "TARGET", "STATE", "DETAIL"], rows: rows))
            if let deployment {
                CLIOut.note("the stack is \(deployment.plainEnglish)")
            } else {
                CLIOut.note(CompanionHostList.emptyStateMessage(hosts))
            }
        }
    }

    static func hostJSON(_ host: CompanionHost) -> JSONValue {
        .object([
            "id": .string(host.id.uuidString),
            "name": .string(host.name),
            "target": .string(host.target),
            "isLocal": .bool(host.isLocal),
            "reachable": .bool(host.reachable),
            "hostsTheStack": .bool(host.hostsTheStack),
            "canHostTheStack": .bool(host.canHostTheStack),
            "tier": host.tier.map { .string($0.rawValue) } ?? .null,
            "summary": .string(host.summary),
            "blockers": .array(
                host.blockers.map { blocker in
                    .object([
                        "headline": .string(blocker.headline),
                        "fix": .string(blocker.fix),
                    ])
                }),
            "facts": host.facts.map(factsJSON) ?? .null,
        ])
    }

    static func factsJSON(_ facts: CompanionHostFacts) -> JSONValue {
        .object([
            "os": .string(facts.os),
            "arch": .string(facts.arch),
            "cpuCores": .int(facts.cpuCores),
            "memoryMb": .int(facts.memoryMb),
            "diskFreeMb": .int(facts.diskFreeMb),
            "gpuModel": .optional(facts.gpuModel),
            "portsTaken": .array(facts.portsTaken.map { .int($0) }),
            "runtimes": .array(
                facts.runtimes.map { runtime in
                    .object([
                        "kind": .string(runtime.kind.rawValue),
                        "version": .optional(runtime.version),
                        "daemonRunning": .bool(runtime.daemonRunning),
                        "composeVersion": .optional(runtime.composeVersion),
                        "canRunTheStack": .bool(runtime.canRunTheStack),
                    ])
                }),
        ])
    }

    static func deploymentJSON(_ deployment: CompanionDeployment) -> JSONValue {
        .object([
            "machineName": .string(deployment.machineName),
            "isLocal": .bool(deployment.isLocal),
            "directory": .string(deployment.directory),
            "tier": .string(deployment.tier),
            "localPort": .int(deployment.localPort),
            "endpoint": .string(deployment.endpoint.absoluteString),
            "deployedAt": .date(deployment.deployedAt),
        ])
    }
}

struct CompanionStackCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stack",
        abstract: "Start, stop and inspect the companion stack on its host.",
        subcommands: [
            CompanionStackStatusCommand.self, CompanionStackUpCommand.self,
            CompanionStackDownCommand.self, CompanionStackRestartCommand.self,
            CompanionStackLogsCommand.self, CompanionStackEnvCommand.self,
        ],
        defaultSubcommand: CompanionStackStatusCommand.self)
}

struct CompanionStackStatusCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status", abstract: "Which host runs the stack, and which services are up.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            guard let deployment = CompanionDeploymentStore.load() else {
                guard !json else {
                    CLIOut.json(.object(["deployed": .bool(false), "services": .array([])]))
                    return
                }
                throw CLIFailure.notFound(
                    "the companion stack is not deployed anywhere",
                    hint: "run `ed companion hosts` to see where it could run")
            }
            let services = await CompanionStackRunner.services(deployment)
            guard !json else {
                CLIOut.json(
                    .object([
                        "deployed": .bool(true),
                        "deployment": CompanionHostsCommand.deploymentJSON(deployment),
                        "services": .array(
                            services.map { service in
                                .object([
                                    "service": .string(service.service),
                                    "status": .string(service.status),
                                    "ports": .string(service.ports),
                                    "running": .bool(service.running),
                                ])
                            }),
                    ]))
                return
            }
            CLIOut.out(deployment.plainEnglish)
            guard !services.isEmpty else {
                CLIOut.note("no services are running")
                return
            }
            CLIOut.out(
                TextTable.render(
                    headers: ["SERVICE", "STATUS", "PORTS"],
                    rows: services.map { [$0.service, $0.status, $0.ports] }))
        }
    }
}

struct CompanionStackUpCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "up", abstract: "Start the companion stack on its host.")

    @Flag(name: .long, help: "Rebuild the api image before starting.")
    var build = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let deployment = try CompanionStackRunner.requireDeployment()
            _ = try await CompanionStackRunner.run(
                CompanionStackCommands.up(
                    directory: deployment.directory,
                    tier: CompanionTier(rawValue: deployment.tier) ?? .cpu,
                    build: build),
                on: deployment, timeout: 1800)
            try await CompanionStackRunner.report(deployment, json: json, verb: "started")
        }
    }
}

struct CompanionStackDownCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "down", abstract: "Stop the companion stack on its host.")

    @Flag(name: .long, help: "Also delete its volumes. This destroys stored memory.")
    var wipe = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let deployment = try CompanionStackRunner.requireDeployment()
            _ = try await CompanionStackRunner.run(
                CompanionStackCommands.down(
                    directory: deployment.directory,
                    tier: CompanionTier(rawValue: deployment.tier) ?? .cpu,
                    keepData: !wipe),
                on: deployment, timeout: 300)
            try await CompanionStackRunner.report(deployment, json: json, verb: "stopped")
        }
    }
}

struct CompanionStackRestartCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restart", abstract: "Restart the companion stack on its host.")

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let deployment = try CompanionStackRunner.requireDeployment()
            _ = try await CompanionStackRunner.run(
                CompanionStackCommands.restart(
                    directory: deployment.directory,
                    tier: CompanionTier(rawValue: deployment.tier) ?? .cpu),
                on: deployment, timeout: 600)
            try await CompanionStackRunner.report(deployment, json: json, verb: "restarted")
        }
    }
}

struct CompanionStackLogsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "logs", abstract: "Read the stack's logs from its host.")

    @Argument(help: "One service, or leave empty for all of them.")
    var service: String?

    @Option(name: .long, help: "How many lines to read.")
    var tail: Int = 100

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let deployment = try CompanionStackRunner.requireDeployment()
            let output = try await CompanionStackRunner.run(
                CompanionStackCommands.logs(
                    directory: deployment.directory,
                    tier: CompanionTier(rawValue: deployment.tier) ?? .cpu,
                    service: service, tail: try ArgumentChecks.positive(tail, "--tail")),
                on: deployment, timeout: 120)
            guard !json else {
                CLIOut.json(
                    .object([
                        "service": .optional(service),
                        "lines": .strings(output.split(separator: "\n").map(String.init)),
                    ]))
                return
            }
            CLIOut.raw(output)
        }
    }
}

struct CompanionStackEnvCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "env", abstract: "Print the environment the stack would be given.")

    @Flag(name: .long, help: "Include secret values instead of hints.")
    var reveal = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let config = CompanionConfigStore.load()
            let secrets = reveal ? CompanionSecrets.all() : CompanionSecretValues()
            let text = config.envFile(secrets: secrets)
            guard !json else {
                var rows: [String: JSONValue] = [:]
                for line in text.split(separator: "\n") {
                    let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
                    guard let key = parts.first else { continue }
                    rows[key] = .string(parts.count > 1 ? parts[1] : "")
                }
                CLIOut.json(.object(rows))
                return
            }
            CLIOut.raw(text)
            if !reveal {
                CLIOut.note("secrets are blank here; pass --reveal to include them")
            }
        }
    }
}

struct CompanionDeployCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "deploy",
        abstract: "Choose the machine that runs the companion, and bring it up there.")

    @Argument(help: "The machine to run it on. Omit to use the one that already hosts it.")
    var machine: String?

    @Option(name: .long, help: "Directory on that machine to run it from.")
    var directory = CompanionDeployment.defaultRemoteDirectory

    @Option(name: .long, help: "Local port the API is reached on.")
    var port = CompanionDeployment.apiPort

    @Flag(name: .long, help: "Record where it runs without starting anything.")
    var adopt = false

    @Flag(name: .long, help: "Rebuild the api image.")
    var build = false

    @Flag(name: .long, help: "Emit JSON on stdout.")
    var json = false

    func run() async throws {
        try await execute {
            let hosts = await CompanionHostProbing.hosts(only: machine)
            guard let chosen = pick(from: hosts) else {
                throw CLIFailure.notFound(
                    machine.map { "no machine called \($0)" } ?? "no machine can run it yet",
                    hint: "run `ed companion hosts` to see what each one needs")
            }
            let deployment = CompanionDeployment(
                machineID: chosen.isLocal ? nil : chosen.id,
                machineName: chosen.name,
                directory: directory,
                tier: (chosen.tier ?? .cpu).rawValue,
                localPort: try ArgumentChecks.positive(port, "--port"))
            let alreadyThere = await CompanionStackRunner.services(deployment)
            guard chosen.canHostTheStack || !alreadyThere.isEmpty else {
                throw CLIFailure(
                    "\(chosen.name) cannot run the companion yet",
                    hint: chosen.blockers.map { "\($0.headline): \($0.fix)" }
                        .joined(separator: "; "))
            }
            if !adopt {
                _ = try await CompanionStackRunner.run(
                    CompanionStackCommands.up(
                        directory: directory, tier: chosen.tier ?? .cpu, build: build),
                    on: deployment, timeout: 1800)
            }
            CompanionDeploymentStore.save(deployment)
            guard !json else {
                CLIOut.json(CompanionHostsCommand.deploymentJSON(deployment))
                return
            }
            CLIOut.out("the companion \(deployment.plainEnglish)")
        }
    }

    private func pick(from hosts: [CompanionHost]) -> CompanionHost? {
        if machine != nil { return hosts.first { !$0.isLocal } ?? hosts.first }
        return CompanionHostList.recommended(hosts)
    }
}
