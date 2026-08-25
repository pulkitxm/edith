import EdithCore
import Foundation

public enum HerdrTerminalOperation: String, CaseIterable, Sendable {
    case new

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .new:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "herdr.terminal.new"),
                summary: "Create a Herdr terminal on this Mac or an SSH machine.",
                cli: ["herdr", "new"], effect: .write)
        }
    }
}

public struct HerdrTerminalRequest: Equatable, Sendable {
    public var session: String
    public var workspace: String?
    public var cwd: String?
    public var label: String?

    public init(
        session: String = "default", workspace: String? = nil, cwd: String? = nil,
        label: String? = nil
    ) {
        self.session = session
        self.workspace = workspace
        self.cwd = cwd
        self.label = label
    }
}

public struct HerdrTerminalError: LocalizedError, Equatable {
    public let message: String

    public init(message: String) {
        self.message = message
    }

    public var errorDescription: String? { message }
}

public enum HerdrTerminalOperationExecution {
    public static func arguments(for request: HerdrTerminalRequest) -> [String] {
        var arguments = ["--session", request.session, "tab", "create", "--no-focus"]
        if let workspace = trimmed(request.workspace) {
            arguments += ["--workspace", workspace]
        }
        if let cwd = trimmed(request.cwd) {
            arguments += ["--cwd", cwd]
        }
        if let label = trimmed(request.label) {
            arguments += ["--label", label]
        }
        return arguments
    }

    public static func shellLine(for request: HerdrTerminalRequest) -> String {
        "herdr " + arguments(for: request).map(ShellQuote.quote).joined(separator: " ")
    }

    public static func remoteShellLine(for request: HerdrTerminalRequest) -> String {
        "export PATH=\"\(HerdrCollector.pathPrefix)\"; \(shellLine(for: request))"
    }

    public static func createLocally(
        _ request: HerdrTerminalRequest,
        run: (String) async -> Result<String, Error> = { command in
            await LocalMachineCommandExecution.run(command, timeout: HerdrCollector.commandTimeout)
        }
    ) async throws -> String {
        try created(from: await run(remoteShellLine(for: request)))
    }

    public static func createRemotely(
        _ request: HerdrTerminalRequest, connection: SSHConnection
    ) async throws -> String {
        let result = try await connection.run(
            remoteShellLine(for: request), timeout: HerdrCollector.commandTimeout)
        guard result.status == 0 else {
            throw HerdrTerminalError(
                message: failure(in: result.combinedText) ?? "herdr could not create the terminal.")
        }
        return try created(from: .success(result.stdoutText))
    }

    public static func focusShellLine(session: String, pane: String) -> String {
        let arguments = ["--session", session, "pane", "focus", pane]
        return "export PATH=\"\(HerdrCollector.pathPrefix)\"; herdr "
            + arguments.map(ShellQuote.quote).joined(separator: " ")
    }

    public static func localClientRequest(
        for agent: HerdrAgent, environment: [String],
        executable: URL? = HerdrCollector.executable()
    ) -> TerminalLaunchRequest {
        guard let executable else {
            return TerminalLaunchRequest(
                executable: "/bin/zsh",
                arguments: [
                    "-c",
                    "export PATH=\"\(HerdrCollector.pathPrefix)\"; herdr --session "
                        + ShellQuote.quote(agent.session),
                ],
                environment: environment)
        }
        return TerminalLaunchRequest(
            executable: executable.path, arguments: ["--session", agent.session],
            environment: environment)
    }

    public static func remoteClientRequest(
        for agent: HerdrAgent, target: String, environment: [String],
        executable: URL? = HerdrCollector.executable()
    ) -> TerminalLaunchRequest {
        let arguments = ["--remote", target, "--session", agent.session]
        guard let executable else {
            return TerminalLaunchRequest(
                executable: "/bin/zsh",
                arguments: [
                    "-c",
                    "export PATH=\"\(HerdrCollector.pathPrefix)\"; herdr "
                        + arguments.map(ShellQuote.quote).joined(separator: " "),
                ],
                environment: environment)
        }
        return TerminalLaunchRequest(
            executable: executable.path, arguments: arguments, environment: environment)
    }

    public static func attachLine(for agent: HerdrAgent) -> String {
        guard !agent.machineIsLocal, let target = agent.sshTarget, !target.isEmpty else {
            return "herdr --session \(agent.session)"
        }
        return "herdr --remote \(target) --session \(agent.session)"
    }

    private static func created(from result: Result<String, Error>) throws -> String {
        switch result {
        case let .failure(error):
            throw HerdrTerminalError(message: error.localizedDescription)
        case let .success(text):
            if let message = failure(in: text) {
                throw HerdrTerminalError(message: message)
            }
            guard let pane = HerdrListParser.createdPane(in: text) else {
                throw HerdrTerminalError(
                    message: "herdr did not report the new terminal.")
            }
            return pane
        }
    }

    private static func failure(in text: String) -> String? {
        HerdrListParser.errorMessage(in: text)
    }

    private static func trimmed(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
