import Foundation

public enum HerdrLaunchError: LocalizedError, Equatable {
    case herdrUnavailable
    case commandFailed(String)
    case malformedResponse

    public var errorDescription: String? {
        switch self {
        case .herdrUnavailable:
            "Herdr is not available on this Mac."
        case .commandFailed(let message):
            message.isEmpty ? "Herdr could not complete the request." : message
        case .malformedResponse:
            "Herdr returned an unexpected response."
        }
    }
}

public struct HerdrAgentLaunch: Sendable {
    public let local: [String]
    public let remote: @Sendable (RemoteMachinePlatform) -> String
    public let timeout: TimeInterval
}

public enum HerdrLaunchOperations {
    private static let defaultTimeout: TimeInterval = 15
    private static let agentStartTimeoutMS = 30_000

    public static func listWorkspaces(on machine: Machine?) async throws -> [HerdrWorkspaceSummary]
    {
        let output = try await run(
            local: HerdrWorkspaceListCommand.arguments,
            remote: { HerdrWorkspaceListCommand.shellLine(platform: $0) },
            timeout: defaultTimeout, on: machine)
        return HerdrListParser.workspaces(from: output)
    }

    public static func createWorkspace(
        label: String, cwd: String? = nil, on machine: Machine?
    ) async throws -> HerdrCreatedPane {
        let output = try await run(
            local: HerdrWorkspaceCreateCommand.arguments(label: label, cwd: cwd),
            remote: { HerdrWorkspaceCreateCommand.shellLine(label: label, cwd: cwd, platform: $0) },
            timeout: defaultTimeout, on: machine)
        guard let created = HerdrListParser.createdPane(from: output) else {
            throw HerdrLaunchError.malformedResponse
        }
        return created
    }

    public static func createTab(
        workspaceID: String, cwd: String? = nil, on machine: Machine?
    ) async throws -> HerdrCreatedPane {
        let output = try await run(
            local: HerdrTabCreateCommand.arguments(workspaceID: workspaceID, cwd: cwd),
            remote: {
                HerdrTabCreateCommand.shellLine(workspaceID: workspaceID, cwd: cwd, platform: $0)
            }, timeout: defaultTimeout, on: machine)
        guard let created = HerdrListParser.createdPane(from: output) else {
            throw HerdrLaunchError.malformedResponse
        }
        return created
    }

    public static func launchAgent(
        kind: String, name: String, pane: String, on machine: Machine?
    ) async throws {
        try await launchAgent(
            kind: kind, name: name, pane: pane, options: HerdrLaunchSettings.options(for: kind),
            on: machine)
    }

    public static func launchAgent(
        kind: String, name: String, pane: String, options: AgentLaunchOptions,
        on machine: Machine?
    ) async throws {
        var catalog: AgentLaunchCatalog?
        if let launchKind = AgentLaunchKind(kind: kind) {
            catalog = await AgentLaunchCatalogs.shared.cached(for: launchKind, on: machine)
        }
        let launch = agentLaunch(
            kind: kind, name: name, pane: pane, options: options, catalog: catalog)
        _ = try await run(
            local: launch.local, remote: launch.remote, timeout: launch.timeout, on: machine)
    }

    public static func agentLaunch(
        kind: String, name: String, pane: String, options: AgentLaunchOptions,
        catalog: AgentLaunchCatalog? = nil, defaults: UserDefaults = SharedDefaults.store
    ) -> HerdrAgentLaunch {
        let agentArguments = AgentLaunchArguments.launchArguments(
            kind: kind, options: options, catalog: catalog)
        if HerdrLaunchSettings.usesHerdrAgentStart(for: kind, in: defaults),
            let slug = HerdrLaunchSettings.defaultHerdrSlug(for: kind)
        {
            let timeoutMS = agentStartTimeoutMS
            let agentName = HerdrAgentStartCommand.name(name, pane: pane)
            return HerdrAgentLaunch(
                local: HerdrAgentStartCommand.arguments(
                    name: agentName, kindSlug: slug, pane: pane, timeoutMS: timeoutMS,
                    agentArguments: agentArguments),
                remote: {
                    HerdrAgentStartCommand.shellLine(
                        name: agentName, kindSlug: slug, pane: pane, timeoutMS: timeoutMS,
                        agentArguments: agentArguments, platform: $0)
                }, timeout: TimeInterval(timeoutMS / 1_000) + 5)
        }
        let command = HerdrLaunchSettings.command(for: kind, in: defaults)
        return HerdrAgentLaunch(
            local: HerdrPaneRunCommand.arguments(
                pane: pane,
                command: HerdrPaneRunCommand.commandText(command, appending: agentArguments)),
            remote: {
                HerdrPaneRunCommand.shellLine(
                    pane: pane,
                    command: HerdrPaneRunCommand.commandText(
                        command, appending: agentArguments, platform: $0),
                    platform: $0)
            }, timeout: defaultTimeout)
    }

    private static func run(
        local arguments: [String], remote shellLine: (RemoteMachinePlatform) -> String,
        timeout: TimeInterval, on machine: Machine?
    ) async throws -> String {
        guard let machine else { return try await runLocal(arguments, timeout: timeout) }
        return try await runRemote(shellLine, timeout: timeout, on: machine)
    }

    private static func runLocal(_ arguments: [String], timeout: TimeInterval) async throws
        -> String
    {
        guard let executable = HerdrCollector.executable() else {
            throw HerdrLaunchError.herdrUnavailable
        }
        let request = CLICommandRequest(
            executableURL: executable, arguments: arguments,
            environment: CLIToolEnvironment.sanitized(), timeout: timeout,
            maximumOutputBytes: 64 * 1_024)
        let result: CLICommandResult
        do {
            result = try await CLICommandRunner.run(request) { _ in }
        } catch {
            throw HerdrLaunchError.commandFailed(error.localizedDescription)
        }
        guard result.terminationStatus == 0 else {
            throw HerdrLaunchError.commandFailed(clean(result.output))
        }
        return result.standardOutput
    }

    private static func runRemote(
        _ shellLine: (RemoteMachinePlatform) -> String, timeout: TimeInterval, on machine: Machine
    ) async throws -> String {
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        do {
            try await connection.connect()
            let platform = await connection.remotePlatform ?? .linux
            let command = shellLine(platform)
            let result = try await connection.run(command, timeout: timeout)
            guard result.status == 0 else {
                throw HerdrLaunchError.commandFailed(clean(result.stderrText))
            }
            return result.stdoutText
        } catch let error as HerdrLaunchError {
            throw error
        } catch {
            throw HerdrLaunchError.commandFailed(error.localizedDescription)
        }
    }

    private static func clean(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
