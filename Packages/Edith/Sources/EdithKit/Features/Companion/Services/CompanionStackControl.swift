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
        let local = await localHost(ports: ports)
        var remote: [CompanionHost] = []
        for machine in MachineRegistry.machines() {
            remote.append(await probe(machine, ports: ports))
        }
        return CompanionHostList.ordered(
            local: local, machines: remote, deployment: deployment)
    }

    @MainActor
    public static func localHost(
        ports: [Int] = CompanionHostFacts.requiredPorts
    ) async -> CompanionHost {
        let output = await CompanionShell.run(CompanionHostProbe.script(ports: ports))
        return CompanionHost(
            id: CompanionHost.localID,
            name: Host.current().localizedName ?? "This Mac",
            target: "this Mac",
            isLocal: true,
            reachable: true,
            facts: output.map(CompanionHostProbe.parse))
    }

    @MainActor
    public static func probe(
        _ machine: Machine, ports: [Int] = CompanionHostFacts.requiredPorts
    ) async -> CompanionHost {
        let session = MachineSession(machine: machine, local: false)
        let result = await session.runCommand(
            CompanionHostProbe.script(ports: ports), timeout: 45)
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
    public static func deploy(
        host: CompanionHost, config: CompanionStackConfig,
        progress: CompanionDeployProgress? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) async throws -> CompanionDeployment {
        let tier = host.tier ?? .cpu
        let deployment = CompanionDeployment(
            machineID: host.isLocal ? nil : host.id,
            machineName: host.name,
            tier: tier.rawValue,
            localPort: config.apiPort)
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
        guard let machine = MachineRegistry.machines().first(where: { $0.id == machineID }) else {
            throw CompanionStackError.machineGone(deployment.machineName)
        }
        let session = MachineSession(machine: machine, local: false)
        switch await session.runCommand(command, stdin: stdin, timeout: timeout) {
        case let .success(output):
            return output
        case let .failure(error):
            throw CompanionStackError.commandFailed(command, error.localizedDescription)
        }
    }
}

public enum CompanionShell {
    public static func run(_ script: String) async -> String? {
        try? await runChecked(script, stdin: nil).get()
    }

    public static func runChecked(
        _ script: String, stdin: Data? = nil, timeout: TimeInterval = 600
    ) async -> Result<String, CompanionShellFailure> {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                signal(SIGPIPE, SIG_IGN)
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", script]
                let output = Pipe()
                let errors = Pipe()
                process.standardOutput = output
                process.standardError = errors
                let input = Pipe()
                process.standardInput = input
                let stdoutBuffer = CompanionPipeBuffer()
                let stderrBuffer = CompanionPipeBuffer()
                output.fileHandleForReading.readabilityHandler = { handle in
                    stdoutBuffer.append(handle.availableData)
                }
                errors.fileHandleForReading.readabilityHandler = { handle in
                    stderrBuffer.append(handle.availableData)
                }
                do {
                    try process.run()
                } catch {
                    output.fileHandleForReading.readabilityHandler = nil
                    errors.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(
                        returning: .failure(
                            CompanionShellFailure(detail: error.localizedDescription)))
                    return
                }
                if let stdin {
                    try? input.fileHandleForWriting.write(contentsOf: stdin)
                }
                try? input.fileHandleForWriting.close()
                let deadline = DispatchWorkItem {
                    guard process.isRunning else { return }
                    process.terminate()
                    DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
                        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                    }
                }
                DispatchQueue.global().asyncAfter(
                    deadline: .now() + max(1, timeout), execute: deadline)
                process.waitUntilExit()
                deadline.cancel()
                output.fileHandleForReading.readabilityHandler = nil
                errors.fileHandleForReading.readabilityHandler = nil
                stdoutBuffer.append(output.fileHandleForReading.readDataToEndOfFile())
                stderrBuffer.append(errors.fileHandleForReading.readDataToEndOfFile())
                let text = String(decoding: stdoutBuffer.snapshot(), as: UTF8.self)
                guard process.terminationStatus == 0 else {
                    let stderrText = String(decoding: stderrBuffer.snapshot(), as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let detail =
                        stderrText.isEmpty
                        ? "exited \(process.terminationStatus) after possibly hitting the "
                            + "\(Int(timeout))s limit"
                        : stderrText
                    continuation.resume(
                        returning: .failure(CompanionShellFailure(detail: detail)))
                    return
                }
                continuation.resume(returning: .success(text))
            }
        }
    }
}

final class CompanionPipeBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        lock.unlock()
    }

    func snapshot() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return data
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
