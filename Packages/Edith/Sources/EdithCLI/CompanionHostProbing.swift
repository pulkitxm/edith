import EdithKit
import Foundation

enum CompanionHostProbing {
    static func hosts(only name: String?) async -> [CompanionHost] {
        let deployment = CompanionDeploymentStore.load()
        let machines = MachineRegistry.machines()
        let local = await localHost()
        var remote: [CompanionHost] = []
        for machine in machines {
            if let name, !matches(machine, name) { continue }
            remote.append(await probe(machine))
        }
        let wantsLocal = name.map { "this mac".hasPrefix($0.lowercased()) || $0 == "local" } ?? true
        let candidates = wantsLocal ? [local] : []
        return CompanionHostList.ordered(
            local: candidates.first ?? local,
            machines: remote,
            deployment: deployment)
    }

    static func matches(_ machine: Machine, _ name: String) -> Bool {
        let needle = name.lowercased()
        return machine.name.lowercased() == needle
            || machine.name.lowercased().hasPrefix(needle)
            || machine.host.lowercased() == needle
    }

    static func localHost() async -> CompanionHost {
        let facts = await localFacts()
        return CompanionHost(
            id: LocalCompanionHost.id,
            name: LocalCompanionHost.name,
            target: "this Mac",
            isLocal: true,
            reachable: true,
            facts: facts)
    }

    static func localFacts() async -> CompanionHostFacts? {
        guard let output = await Shell.run("/bin/sh", ["-c", CompanionHostProbe.script]) else {
            return nil
        }
        return CompanionHostProbe.parse(output)
    }

    static func probe(_ machine: Machine) async -> CompanionHost {
        let runner = RemoteRunner(machine: machine)
        do {
            try await runner.connect()
            defer { Task { await runner.disconnect() } }
            let output = try await runner.text(CompanionHostProbe.script, timeout: 45)
            return CompanionHost(
                id: machine.id, name: machine.name, target: machine.sshTarget,
                isLocal: false, reachable: true,
                facts: CompanionHostProbe.parse(output))
        } catch {
            return CompanionHost(
                id: machine.id, name: machine.name, target: machine.sshTarget,
                isLocal: false, reachable: false, facts: nil)
        }
    }
}

enum LocalCompanionHost {
    static let id = UUID(uuidString: "00000000-0000-0000-0000-00000000ed17")!
    static var name: String { Host.current().localizedName ?? "This Mac" }
}

enum Shell {
    static func run(_ launchPath: String, _ arguments: [String]) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: launchPath)
            process.arguments = arguments
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = Pipe()
            do {
                try process.run()
            } catch {
                continuation.resume(returning: nil)
                return
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            continuation.resume(returning: String(decoding: data, as: UTF8.self))
        }
    }
}

enum CompanionStackRunner {
    static func requireDeployment() throws -> CompanionDeployment {
        guard let deployment = CompanionDeploymentStore.load() else {
            throw CLIFailure.notFound(
                "the companion stack is not deployed anywhere",
                hint: "run `ed companion hosts` to see where it could run")
        }
        return deployment
    }

    static func run(
        _ command: String, on deployment: CompanionDeployment, stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> String {
        guard let machineID = deployment.machineID else {
            let outcome = await CompanionShell.runChecked(command, stdin: stdin)
            switch outcome {
            case let .success(output):
                return output
            case let .failure(failure):
                throw CLIFailure(
                    "the command failed on this Mac", hint: failure.detail)
            }
        }
        guard let machine = MachineRegistry.machines().first(where: { $0.id == machineID }) else {
            throw CLIFailure.notFound(
                "the machine that hosts the companion is no longer in your fleet",
                hint: "add \(deployment.machineName) back, or deploy somewhere else")
        }
        let runner = RemoteRunner(machine: machine)
        try await runner.connect()
        defer { Task { await runner.disconnect() } }
        let result = try await runner.run(command, stdin: stdin, timeout: timeout)
        let output = result.stdoutText + result.stderrText
        guard result.succeeded else {
            throw CLIFailure.unavailable(
                "the stack command exited \(result.status) on \(machine.name)",
                hint: output.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return output
    }

    static func services(_ deployment: CompanionDeployment) async -> [CompanionServiceStatus] {
        let tier = CompanionTier(rawValue: deployment.tier) ?? .cpu
        let command = CompanionStackCommands.ps(directory: deployment.directory, tier: tier)
        guard let output = try? await run(command, on: deployment, timeout: 60) else { return [] }
        return CompanionStackParsing.services(output)
    }
}

extension CompanionStackRunner {
    static func report(
        _ deployment: CompanionDeployment, json: Bool, verb: String
    ) async throws {
        let services = await services(deployment)
        guard !json else {
            CLIOut.json(
                .object([
                    "deployment": CompanionHostsCommand.deploymentJSON(deployment),
                    "services": .array(
                        services.map { service in
                            .object([
                                "service": .string(service.service),
                                "status": .string(service.status),
                                "running": .bool(service.running),
                            ])
                        }),
                ]))
            return
        }
        let running = services.filter(\.running).count
        CLIOut.out("\(verb) on \(deployment.machineName), \(running) of \(services.count) up")
    }
}
