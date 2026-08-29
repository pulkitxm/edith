import Foundation

public enum AutomationCommandProcessError: LocalizedError {
    case failed(Int32, String)

    public var errorDescription: String? {
        switch self {
        case .failed(let status, let output):
            output.isEmpty ? "The operation exited with status \(status)." : output
        }
    }
}

public enum AutomationCommandProcess {
    public static func run(executable: URL, arguments: [String]) async throws -> String {
        let result = try await CLICommandRunner.run(
            CLICommandRequest(
                executableURL: executable, arguments: arguments,
                environment: ProcessInfo.processInfo.environment,
                maximumOutputBytes: 1_048_576, terminatesProcessGroup: true)
        ) { _ in }
        let text = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        let status = result.terminationStatus
        guard status == 0 else { throw AutomationCommandProcessError.failed(status, text) }
        return text
    }
}
