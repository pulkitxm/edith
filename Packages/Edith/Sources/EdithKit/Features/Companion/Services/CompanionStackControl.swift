import Foundation

public enum CompanionStackError: Error, LocalizedError {
    case noRuntime(String)
    case commandFailed(String, String)
    case machineGone(String)

    public var errorDescription: String? {
        switch self {
        case let .noRuntime(name):
            "\(name) has no container runtime that can run the stack."
        case let .commandFailed(_, detail):
            detail
        case let .machineGone(name):
            "\(name) is no longer in your fleet."
        }
    }
}

public enum CompanionHosts {
    @MainActor
    public static func all(deployment: CompanionDeployment?) async -> [CompanionHost] {
        let local = await localHost()
        var remote: [CompanionHost] = []
        for machine in MachineRegistry.machines() {
            remote.append(await probe(machine))
        }
        return CompanionHostList.ordered(
            local: local, machines: remote, deployment: deployment)
    }

    @MainActor
    public static func localHost() async -> CompanionHost {
        let output = await CompanionShell.run(CompanionHostProbe.script)
        return CompanionHost(
            id: CompanionHost.localID,
            name: Host.current().localizedName ?? "This Mac",
            target: "this Mac",
            isLocal: true,
            reachable: true,
            facts: output.map(CompanionHostProbe.parse))
    }

    @MainActor
    public static func probe(_ machine: Machine) async -> CompanionHost {
        let session = MachineSession(machine: machine, local: false)
        let result = await session.runCommand(CompanionHostProbe.script, timeout: 45)
        switch result {
        case let .success(output):
            return CompanionHost(
                id: machine.id, name: machine.name, target: machine.sshTarget,
                isLocal: false, reachable: true, facts: CompanionHostProbe.parse(output))
        case .failure:
            return CompanionHost(
                id: machine.id, name: machine.name, target: machine.sshTarget,
                isLocal: false, reachable: false, facts: nil)
        }
    }
}

public enum CompanionStackControl {
    @MainActor
    public static func deploy(host: CompanionHost, config: CompanionStackConfig) async throws
        -> CompanionDeployment
    {
        let tier = host.tier ?? .cpu
        let deployment = CompanionDeployment(
            machineID: host.isLocal ? nil : host.id,
            machineName: host.name,
            tier: tier.rawValue,
            localPort: config.apiPort)
        _ = try await run(
            CompanionStackCommands.up(
                directory: deployment.directory, tier: tier, build: false),
            on: deployment, timeout: 1800)
        return CompanionDeploymentStore.save(deployment)
    }

    @MainActor
    public static func up(_ deployment: CompanionDeployment) async throws -> String {
        try await run(
            CompanionStackCommands.up(
                directory: deployment.directory, tier: deployment.resolvedTier, build: false),
            on: deployment, timeout: 1800)
    }

    @MainActor
    public static func down(_ deployment: CompanionDeployment) async throws -> String {
        try await run(
            CompanionStackCommands.down(
                directory: deployment.directory, tier: deployment.resolvedTier, keepData: true),
            on: deployment, timeout: 300)
    }

    @MainActor
    public static func restart(_ deployment: CompanionDeployment) async throws -> String {
        try await run(
            CompanionStackCommands.restart(
                directory: deployment.directory, tier: deployment.resolvedTier),
            on: deployment, timeout: 600)
    }

    @MainActor
    public static func logs(_ deployment: CompanionDeployment, service: String?) async throws
        -> String
    {
        try await run(
            CompanionStackCommands.logs(
                directory: deployment.directory, tier: deployment.resolvedTier,
                service: service, tail: 200),
            on: deployment, timeout: 120)
    }

    @MainActor
    public static func services(_ deployment: CompanionDeployment) async
        -> [CompanionServiceStatus]
    {
        let command = CompanionStackCommands.ps(
            directory: deployment.directory, tier: deployment.resolvedTier)
        guard let output = try? await run(command, on: deployment, timeout: 60) else { return [] }
        return CompanionStackParsing.services(output)
    }

    @MainActor
    public static func run(
        _ command: String, on deployment: CompanionDeployment, timeout: TimeInterval
    ) async throws -> String {
        guard let machineID = deployment.machineID else {
            guard let output = await CompanionShell.run(command) else {
                throw CompanionStackError.commandFailed(command, "could not run it on this Mac")
            }
            return output
        }
        guard let machine = MachineRegistry.machines().first(where: { $0.id == machineID }) else {
            throw CompanionStackError.machineGone(deployment.machineName)
        }
        let session = MachineSession(machine: machine, local: false)
        switch await session.runCommand(command, timeout: timeout) {
        case let .success(output):
            return output
        case let .failure(error):
            throw CompanionStackError.commandFailed(command, error.localizedDescription)
        }
    }
}

public enum CompanionShell {
    public static func run(_ script: String) async -> String? {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = ["-c", script]
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

extension CompanionDeployment {
    public var resolvedTier: CompanionTier { CompanionTier(rawValue: tier) ?? .cpu }
}

extension CompanionHost {
    public static let localID = UUID(uuidString: "00000000-0000-0000-0000-00000000ed17")!
}
