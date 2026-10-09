import EdithExtensionSupport
import Foundation

public struct HerdrAgentLaunch: Sendable {
    public let local: [String]
    public let remote: @Sendable (RemoteMachinePlatform) -> String
    public let timeout: TimeInterval
}

public enum HerdrLaunchOperations {
    private static let defaultTimeout: TimeInterval = 15
    private static let agentStartTimeoutMS = 30_000

    public static func startupMessage(for error: Error) -> String {
        if case HerdrCommandError.commandFailed(let response) = error,
            let object = HerdrListParser.firstJSON(in: response) as? [String: Any],
            let detail = object["error"] as? [String: Any]
        {
            switch detail["code"] as? String {
            case "agent_not_ready":
                return "The agent needs input. Continue in this terminal."
            case "timeout":
                return
                    "Startup could not be confirmed. Check this terminal before creating another agent."
            default:
                return HerdrListParser.errorMessage(in: response) ?? error.localizedDescription
            }
        }
        return error.localizedDescription
    }

    public static func listWorkspaces(
        session: String = HerdrTerminalSpace.defaultSession, on machine: Machine?
    ) async throws -> [HerdrWorkspaceSummary] {
        let output = try await HerdrCommand.run(
            HerdrSessionCommand.scoped(HerdrWorkspaceListCommand.arguments, session: session),
            timeout: defaultTimeout, on: machine)
        return HerdrListParser.workspaces(from: output)
    }

    public static func createWorkspace(
        label: String, cwd: String? = nil, session: String = HerdrTerminalSpace.defaultSession,
        on machine: Machine?
    ) async throws -> HerdrCreatedPane {
        let output = try await HerdrCommand.run(
            HerdrSessionCommand.scoped(
                HerdrWorkspaceCreateCommand.arguments(label: label, cwd: cwd), session: session),
            timeout: defaultTimeout, on: machine)
        guard let created = HerdrListParser.createdPane(from: output) else {
            throw HerdrCommandError.malformedResponse
        }
        return created
    }

    public static func createTab(
        workspaceID: String, cwd: String? = nil,
        session: String = HerdrTerminalSpace.defaultSession,
        on machine: Machine?
    ) async throws -> HerdrCreatedPane {
        let output = try await HerdrCommand.run(
            HerdrSessionCommand.scoped(
                HerdrTabCreateCommand.arguments(workspaceID: workspaceID, cwd: cwd),
                session: session),
            timeout: defaultTimeout, on: machine)
        guard let created = HerdrListParser.createdPane(from: output) else {
            throw HerdrCommandError.malformedResponse
        }
        return created
    }

    public static func launchAgent(
        kind: String, name: String, pane: String,
        session: String = HerdrTerminalSpace.defaultSession,
        on machine: Machine?
    ) async throws {
        try await launchAgent(
            kind: kind, name: name, pane: pane, options: HerdrLaunchSettings.options(for: kind),
            session: session, on: machine)
    }

    public static func launchAgent(
        kind: String, name: String, pane: String, options: AgentLaunchOptions,
        session: String = HerdrTerminalSpace.defaultSession, on machine: Machine?
    ) async throws {
        var catalog: AgentLaunchCatalog?
        if let launchKind = AgentLaunchKind(kind: kind) {
            catalog = await AgentLaunchCatalogs.shared.cached(for: launchKind, on: machine)
        }
        let launch = agentLaunch(
            kind: kind, name: name, pane: pane, options: options, catalog: catalog, session: session
        )
        _ = try await HerdrCommand.run(
            local: launch.local, remote: launch.remote, timeout: launch.timeout, on: machine)
    }

    public static func agentLaunch(
        kind: String, name: String, pane: String, options: AgentLaunchOptions,
        catalog: AgentLaunchCatalog? = nil, session: String = HerdrTerminalSpace.defaultSession,
        defaults: UserDefaults = SharedDefaults.store
    ) -> HerdrAgentLaunch {
        let agentArguments = AgentLaunchArguments.launchArguments(
            kind: kind, options: options, catalog: catalog)
        if HerdrLaunchSettings.usesHerdrAgentStart(for: kind, in: defaults),
            let slug = HerdrLaunchSettings.defaultHerdrSlug(for: kind)
        {
            let timeoutMS = agentStartTimeoutMS
            let agentName = HerdrAgentStartCommand.name(name, pane: pane)
            return HerdrAgentLaunch(
                local: HerdrSessionCommand.scoped(
                    HerdrAgentStartCommand.arguments(
                        name: agentName, kindSlug: slug, pane: pane, timeoutMS: timeoutMS,
                        agentArguments: agentArguments), session: session),
                remote: {
                    remoteHerdrCommand(
                        arguments: HerdrSessionCommand.scoped(
                            HerdrAgentStartCommand.arguments(
                                name: agentName, kindSlug: slug, pane: pane, timeoutMS: timeoutMS,
                                agentArguments: agentArguments), session: session), platform: $0)
                }, timeout: TimeInterval(timeoutMS / 1_000) + 5)
        }
        let command = HerdrLaunchSettings.command(for: kind, in: defaults)
        return HerdrAgentLaunch(
            local: HerdrSessionCommand.scoped(
                HerdrPaneRunCommand.arguments(
                    pane: pane,
                    command: HerdrPaneRunCommand.commandText(command, appending: agentArguments)),
                session: session),
            remote: {
                remoteHerdrCommand(
                    arguments: HerdrSessionCommand.scoped(
                        HerdrPaneRunCommand.arguments(
                            pane: pane,
                            command: HerdrPaneRunCommand.commandText(
                                command, appending: agentArguments, platform: $0)), session: session
                    ),
                    platform: $0)
            }, timeout: defaultTimeout)
    }
}
