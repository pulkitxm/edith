import EdithCore
import Foundation

public struct HerdrAgentLaunch: Sendable {
    public let local: [String]
    public let remote: @Sendable (RemoteMachinePlatform) -> String
    public let timeout: TimeInterval
}

public enum HerdrLaunchOperations {
    public static func launchLocalAccount(command: String, pane: String) async throws {
        try Task.checkCancellation()
        _ = try await HerdrCommand.run(
            HerdrSessionCommand.scoped(
                HerdrPaneRunCommand.arguments(pane: pane, command: command),
                session: HerdrTerminalSpace.defaultSession), timeout: 15, on: nil)
    }

    public static func launchRemoteAccount(
        account: ClaudeAccount, command: String, arguments: [String], environment: String,
        pane: String,
        on machine: Machine
    ) async throws {
        try validateAccountTarget(account, on: machine)
        _ = try account.launchCommand(
            command: command, arguments: arguments, environment: environment,
            configurationPath: account.authentication == .browserLogin ? "/validated/profile" : nil)
        if account.authentication != .browserLogin {
            let launch = try accountLaunch(
                account: account, command: command, arguments: arguments, environment: environment,
                pane: pane)
            try Task.checkCancellation()
            _ = try await HerdrCommand.run(
                local: launch.local, remote: launch.remote, timeout: launch.timeout, on: machine)
            return
        }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        guard let platform = await connection.remotePlatform, platform != .windows else {
            throw ClaudeAccountError.rejected(
                "Account launches require a POSIX shell on this machine.")
        }
        if account.isLoggedOut {
            try await ClaudeAccountImport.removeRemoteProfile(
                accountID: account.id, machineID: machine.id.uuidString)
        }
        let expression = try ClaudeAccountImport.remoteProfileExpression(accountID: account.id)
        let prepared = try await connection.run(
            try ClaudeAccountImport.remoteScopeValidation(accountID: account.id)
                + "; umask 077; folder=" + expression
                + "; mkdir -p \"$folder\" && chmod 700 \"$folder\" && printf '%s' \"$folder\"",
            timeout: 15)
        try Task.checkCancellation()
        let namespace = AppBuildIdentity.application
        guard prepared.succeeded, prepared.stdout.count <= 8192,
            prepared.stdoutText.hasSuffix(
                "/.local/share/edith/" + namespace + "/accounts/" + account.id.uuidString),
            ClaudeAccountKeychain.absoluteComponents(prepared.stdoutText) != nil,
            !prepared.stdoutText.contains(where: { $0.isNewline }), !prepared.stdout.contains(0)
        else {
            throw ClaudeAccountError.rejected(
                "The selected machine could not prepare an account login.")
        }
        let credentialGuard = try ClaudeAccountImport.remoteCredentialValidation(
            path: prepared.stdoutText + "/.credentials.json", platform: platform)
        let admitted = try await connection.run(credentialGuard, timeout: 15)
        guard admitted.succeeded else {
            throw ClaudeAccountError.rejected(
                "The selected machine has an unsafe account login file.")
        }
        if account.authentication == .browserLogin, let loginData = account.loginData {
            let credentials = ShellQuote.quote(prepared.stdoutText + "/.credentials.json")
            let seeded = try await connection.run(
                credentialGuard + "; umask 077; test ! -L " + credentials
                    + "; status=$?; if [ $status -ne 0 ]; then exit $status; fi; if [ ! -e "
                    + credentials + " ]; then (set -C; cat > " + credentials
                    + "); else test -f " + credentials + " && cat >/dev/null; fi",
                stdin: Data(loginData.utf8), timeout: 15)
            guard seeded.succeeded else {
                throw ClaudeAccountError.rejected(
                    "The selected machine could not save the account login.")
            }
        }
        try Task.checkCancellation()
        let qualified = try await connection.run(credentialGuard, timeout: 15)
        guard qualified.succeeded else {
            throw ClaudeAccountError.rejected(
                "The selected machine has an unsafe account login file.")
        }
        let launch = try accountLaunch(
            account: account, command: command, arguments: arguments, environment: environment,
            configurationPath: prepared.stdoutText, pane: pane)
        try Task.checkCancellation()
        _ = try await HerdrCommand.run(
            local: launch.local, remote: launch.remote, timeout: launch.timeout, on: machine)
    }

    public static func validateAccountTarget(_ account: ClaudeAccount, on machine: Machine) throws {
        try account.validateLaunch()
        guard account.remoteMachineID == machine.id.uuidString else {
            throw ClaudeAccountError.rejected("Choose the machine associated with this account.")
        }
        _ = try ClaudeAccountImport.remoteProfileExpression(accountID: account.id)
    }

    public static func accountLaunch(
        account: ClaudeAccount, command: String, arguments: [String], environment: String,
        configurationPath: String? = nil, pane: String,
        session: String = HerdrTerminalSpace.defaultSession
    ) throws -> HerdrAgentLaunch {
        let local = try account.launchCommand(
            command: command, arguments: arguments, environment: environment,
            configurationPath: configurationPath)
        let windows = try account.launchCommand(
            command: command, arguments: arguments, environment: environment, platform: .windows,
            configurationPath: configurationPath)
        @Sendable func remoteCommand(_ platform: RemoteMachinePlatform) -> String {
            remoteHerdrCommand(
                arguments: HerdrSessionCommand.scoped(
                    HerdrPaneRunCommand.arguments(
                        pane: pane, command: platform == .windows ? windows : local),
                    session: session), platform: platform)
        }
        guard remoteCommand(.windows).utf8.count <= 65_536,
            remoteCommand(.linux).utf8.count <= 65_536
        else { throw ClaudeAccountError.invalidRequest }
        return HerdrAgentLaunch(
            local: HerdrSessionCommand.scoped(
                HerdrPaneRunCommand.arguments(pane: pane, command: local), session: session),
            remote: { remoteCommand($0) }, timeout: 15)
    }

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
        let agentArguments = HerdrLaunchSettings.launchArguments(
            kind: kind, options: options, catalog: catalog, in: defaults)
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
        let command = HerdrLaunchSettings.launchCommand(for: kind, in: defaults)
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
