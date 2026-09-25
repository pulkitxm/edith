import Foundation

public enum HerdrCommandError: LocalizedError, Equatable {
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

    public var paneMissing: Bool {
        guard case .commandFailed(let message) = self else { return false }
        return message.contains("pane_not_found")
    }
}

public enum HerdrSessionCommand {
    public static func scoped(_ arguments: [String], session: String) -> [String] {
        ["--session", session] + arguments
    }
}

enum HerdrCommand {
    static func run(
        _ arguments: [String], timeout: TimeInterval, on machine: Machine?
    ) async throws -> String {
        try await run(
            local: arguments,
            remote: { remoteHerdrCommand(arguments: arguments, platform: $0) },
            timeout: timeout, on: machine)
    }

    static func run(
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
            throw HerdrCommandError.herdrUnavailable
        }
        let request = CLICommandRequest(
            executableURL: executable, arguments: arguments,
            environment: CLIToolEnvironment.sanitized(), timeout: timeout,
            maximumOutputBytes: 64 * 1_024)
        let result: CLICommandResult
        do {
            result = try await CLICommandRunner.run(request) { _ in }
        } catch {
            throw HerdrCommandError.commandFailed(error.localizedDescription)
        }
        guard result.terminationStatus == 0 else {
            throw HerdrCommandError.commandFailed(clean(result.output))
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
                throw HerdrCommandError.commandFailed(clean(result.stderrText))
            }
            return result.stdoutText
        } catch let error as HerdrCommandError {
            throw error
        } catch {
            throw HerdrCommandError.commandFailed(error.localizedDescription)
        }
    }

    private static func clean(_ output: String) -> String {
        output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
