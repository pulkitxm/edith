import EdithExtensionUI
import EdithExtensionSupport
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
    public static func all(
        deployment: CompanionDeployment?, config: CompanionStackConfig = CompanionConfigStore.load()
    ) async -> [CompanionHost] {
        let ports = CompanionHostFacts.requiredPorts(for: config)
        async let local = localHost(ports: ports)
        let machines = await CompanionMachines.live.list()
        var probed: [UUID: CompanionHost] = [:]
        await withTaskGroup(of: CompanionHost.self) { group in
            let probeLimit = 4
            var pending = machines.makeIterator()
            var started = 0
            while started < probeLimit, let machine = pending.next() {
                group.addTask { await probe(machine, ports: ports) }
                started += 1
            }
            while let host = await group.next() {
                probed[host.id] = host
                if let machine = pending.next() {
                    group.addTask { await probe(machine, ports: ports) }
                }
            }
        }
        let remote = machines.compactMap { probed[$0.id] }
        return CompanionHostList.ordered(
            local: await local, machines: remote, deployment: deployment)
    }

    @MainActor
    public static func localHost(
        ports: [Int] = CompanionHostFacts.requiredPorts
    ) async -> CompanionHost {
        let output = await CompanionShell.run(
            CompanionHostProbe.script(ports: ports), timeout: probeTimeout)
        return CompanionHost(
            id: CompanionHost.localID,
            name: Host.current().localizedName ?? "This Mac",
            target: "this Mac",
            isLocal: true,
            reachable: true,
            facts: output.map(CompanionHostProbe.parse))
    }

    static let probeTimeout: TimeInterval = 10

    @MainActor
    public static func probe(
        _ machine: CompanionFleetMachine, ports: [Int] = CompanionHostFacts.requiredPorts,
        machines: CompanionMachines = .live
    ) async -> CompanionHost {
        do {
            let output = try await machines.run(
                machineID: machine.id, command: CompanionHostProbe.script(ports: ports),
                stdin: nil, timeout: probeTimeout)
            return CompanionHost(
                id: machine.id, name: machine.name, target: machine.sshTarget,
                isLocal: false, reachable: true, facts: CompanionHostProbe.parse(output))
        } catch {
            return CompanionHost(
                id: machine.id, name: machine.name, target: machine.sshTarget,
                isLocal: false, reachable: false, facts: nil)
        }
    }
}

public enum CompanionStackControl {
    @MainActor
    public static func deploy(
        host: CompanionHost, config: CompanionStackConfig,
        progress: CompanionDeployProgress? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CompanionDeployment {
        let tier = host.tier ?? .cpu
        let deployment = CompanionMindRuntimeOperationExecution.deployment(
            host: host, localPort: config.apiPort)
        try await CompanionInstaller.install(
            deployment: deployment, config: config, secrets: CompanionSecrets.all(),
            progress: progress, log: log)
        progress?(.start, "compose up, first builds take minutes")
        log("Starting the stack, building the image when it changed")
        _ = try await run(
            CompanionStackCommands.up(
                directory: deployment.directory, tier: tier, build: true),
            on: deployment, timeout: 1800)
        let saved = CompanionDeploymentStore.save(deployment)
        if deployment.machineID != nil {
            progress?(.tunnel, "localhost:\(deployment.localPort)")
            log("Opening the port forward so this Mac can reach it")
            _ = await CompanionTunnel.ensure(saved)
        } else {
            progress?(.tunnel, "local, nothing to forward")
        }
        progress?(.health, "waiting for the doctor")
        guard await waitForHealth(saved) else {
            throw CompanionStackError.commandFailed(
                "health",
                "the services started but the companion never answered on "
                    + "localhost:\(saved.localPort); check `ed companion stack logs api`")
        }
        return saved
    }

    @MainActor
    public static func waitForHealth(
        _ deployment: CompanionDeployment, attempts: Int = 30
    ) async -> Bool {
        for _ in 0..<attempts {
            if await CompanionTunnel.endpointAnswers(deployment) { return true }
            try? await Task.sleep(for: .seconds(2))
        }
        return false
    }

    @MainActor
    public static func up(_ deployment: CompanionDeployment) async throws -> String {
        try await CompanionMindRuntimeOperationExecution.start(
            deployment, build: false
        ) { command, deployment, timeout in
            try await run(command, on: deployment, timeout: timeout)
        }
    }

    @MainActor
    public static func down(_ deployment: CompanionDeployment) async throws -> String {
        try await CompanionMindRuntimeOperationExecution.stop(
            deployment, wipe: false
        ) { command, deployment, timeout in
            try await run(command, on: deployment, timeout: timeout)
        }
    }

    @MainActor
    public static func restart(_ deployment: CompanionDeployment) async throws -> String {
        try await CompanionMindRuntimeOperationExecution.restart(deployment) {
            command, deployment, timeout in
            try await run(command, on: deployment, timeout: timeout)
        }
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
        _ command: String, on deployment: CompanionDeployment, stdin: Data? = nil,
        timeout: TimeInterval
    ) async throws -> String {
        guard let machineID = deployment.machineID else {
            let outcome = await CompanionShell.runChecked(
                command, stdin: stdin, timeout: timeout)
            switch outcome {
            case let .success(output):
                return output
            case let .failure(failure):
                throw CompanionStackError.commandFailed(command, failure.detail)
            }
        }
        do {
            return try await CompanionMachines.live.run(
                machineID: machineID, command: command, stdin: stdin, timeout: timeout)
        } catch is CancellationError {
            throw CancellationError()
        } catch ExtensionPeerError.unavailable {
            throw CompanionStackError.machineGone(deployment.machineName)
        } catch {
            throw CompanionStackError.commandFailed(command, error.localizedDescription)
        }
    }
}

public enum CompanionShell {
    static let maximumOutputBytes = 16 * 1_024 * 1_024

    public static func run(_ script: String, timeout: TimeInterval = 600) async -> String? {
        try? await runChecked(script, stdin: nil, timeout: timeout).get()
    }

    static var environment: [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let path = environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + path
        return environment.filter { !$0.key.hasPrefix("EDITH_EXTENSION_") }
    }

    public static func runChecked(
        _ script: String, stdin: Data? = nil, timeout: TimeInterval = 600
    ) async -> Result<String, CompanionShellFailure> {
        let request = CLICommandRequest(
            executableURL: URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", script],
            environment: environment, timeout: max(1, timeout),
            maximumOutputBytes: maximumOutputBytes, standardInputData: stdin ?? Data(),
            terminatesProcessGroup: true)
        do {
            let result = try await CLICommandRunner.runSeparated(
                request, onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
            guard result.terminationStatus == 0 else {
                let stderrText = result.standardError.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                return .failure(
                    CompanionShellFailure(
                        detail: stderrText.isEmpty
                            ? "exited \(result.terminationStatus)" : stderrText))
            }
            return .success(result.standardOutput)
        } catch is CancellationError {
            return .failure(CompanionShellFailure(detail: "The command was cancelled."))
        } catch CLICommandRunnerError.timedOut {
            return .failure(
                CompanionShellFailure(detail: "The command hit the \(Int(timeout))s limit."))
        } catch CLICommandRunnerError.outputLimitExceeded {
            return .failure(CompanionShellFailure(detail: "The command produced too much output."))
        } catch {
            return .failure(CompanionShellFailure(detail: error.localizedDescription))
        }
    }
}

public struct CompanionShellFailure: Error, CustomStringConvertible {
    public let detail: String
    public var description: String { detail }
}

extension CompanionDeployment {
    public var resolvedTier: CompanionTier { CompanionTier(rawValue: tier) ?? .cpu }
}

extension CompanionHost {
    public static let localID = UUID(uuidString: "00000000-0000-0000-0000-00000000ed17")!
}
