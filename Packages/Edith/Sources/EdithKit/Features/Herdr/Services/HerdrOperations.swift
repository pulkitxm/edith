import EdithCore
import Foundation

public enum HerdrOperation: String, CaseIterable, Sendable {
    case command
    case attach

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .command:
            descriptor("command", "Print the command that attaches to a pane.", effect: .read)
        case .attach:
            descriptor("attach", "Attach to a live Herdr pane.", effect: .interactive)
        }
    }

    private func descriptor(
        _ verb: String, _ summary: String, effect: UserOperationEffect
    ) -> UserOperationDescriptor {
        UserOperationDescriptor(
            id: UserOperationID(rawValue: "herdr.\(rawValue)"), summary: summary,
            cli: ["herdr", verb], effect: effect)
    }
}

public struct TerminalLaunchRequest: Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let environment: [String]

    public init(executable: String, arguments: [String], environment: [String]) {
        self.executable = executable
        self.arguments = arguments
        self.environment = environment
    }
}

public enum HerdrOperationExecution {
    public static func localAttachRequest(
        for agent: HerdrAgent, environment: [String], executable: URL? = HerdrCollector.executable()
    ) -> TerminalLaunchRequest {
        guard let executable else {
            return TerminalLaunchRequest(
                executable: "/bin/zsh",
                arguments: [
                    "-c",
                    HerdrAttachCommand.remoteShellLine(
                        session: agent.session, pane: agent.pane),
                ],
                environment: environment)
        }
        return TerminalLaunchRequest(
            executable: executable.path,
            arguments: HerdrAttachCommand.arguments(session: agent.session, pane: agent.pane),
            environment: environment)
    }

    public static func remoteAttachRequest(
        for agent: HerdrAgent, connection: SSHConnection, environment: [String]
    ) -> TerminalLaunchRequest {
        TerminalLaunchRequest(
            executable: SSHConnection.executable.path,
            arguments: connection.terminalArguments(
                remoteCommand: HerdrAttachCommand.remoteShellLine(
                    session: agent.session, pane: agent.pane)),
            environment: environment + connection.terminalEnvironment())
    }
}
