import Foundation

public enum HerdrAgentCloseCommand {
    public static func arguments(for agent: HerdrAgent) -> [String] {
        ["--session", agent.session, "agent", "send-keys", agent.pane, "ctrl+c", "ctrl+c"]
    }

    public static func shellLine(for agent: HerdrAgent) -> String {
        let arguments = arguments(for: agent).map(ShellQuote.quote).joined(separator: " ")
        return "export PATH=\"\(HerdrCollector.pathPrefix)\"; herdr \(arguments)"
    }
}

public enum HerdrAgentCloseError: LocalizedError, Equatable {
    case herdrUnavailable
    case machineUnavailable
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case .herdrUnavailable:
            "Herdr is not available on this Mac."
        case .machineUnavailable:
            "The agent's machine is no longer configured."
        case .commandFailed(let message):
            message.isEmpty ? "Herdr could not close the agent." : message
        }
    }
}

public enum HerdrAgentCloseExecution {
    public static func close(_ agent: HerdrAgent) async throws {
        if agent.machineIsLocal {
            try await closeLocal(agent)
        } else {
            try await closeRemote(agent)
        }
    }

    private static func closeLocal(_ agent: HerdrAgent) async throws {
        guard let executable = HerdrCollector.executable() else {
            throw HerdrAgentCloseError.herdrUnavailable
        }
        let request = CLICommandRequest(
            executableURL: executable, arguments: HerdrAgentCloseCommand.arguments(for: agent),
            environment: CLIToolEnvironment.sanitized(), timeout: 10,
            maximumOutputBytes: 64 * 1_024)
        let result: CLICommandResult
        do {
            result = try await CLICommandRunner.run(request) { _ in }
        } catch {
            throw HerdrAgentCloseError.commandFailed(error.localizedDescription)
        }
        guard result.terminationStatus == 0 else {
            throw HerdrAgentCloseError.commandFailed(clean(result.output))
        }
    }

    private static func closeRemote(_ agent: HerdrAgent) async throws {
        guard
            let machine = MachineRegistry.machines().first(where: {
                $0.id.uuidString == agent.machineID
            })
        else { throw HerdrAgentCloseError.machineUnavailable }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        do {
            try await connection.connect()
            let result = try await connection.run(HerdrAgentCloseCommand.shellLine(for: agent))
            guard result.status == 0 else {
                throw HerdrAgentCloseError.commandFailed(clean(result.stderrText))
            }
        } catch let error as HerdrAgentCloseError {
            throw error
        } catch {
            throw HerdrAgentCloseError.commandFailed(error.localizedDescription)
        }
    }

    private static func clean(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
