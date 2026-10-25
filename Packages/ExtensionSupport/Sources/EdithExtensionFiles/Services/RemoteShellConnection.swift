import Foundation

public enum MachineUIError: Error, Equatable {
    case invalidRequest, unavailable, stale
}

public struct MachineUIFailure: LocalizedError, Sendable {
    public let message: String
    public init(message: String) { self.message = message }
    public var errorDescription: String? { message }
}

public enum FileTransferError: LocalizedError, Sendable {
    case commandFailed(command: String, status: Int32, stderr: String)
    case transferFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .commandFailed(command, status, stderr):
            let detail = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "\(command) exited with status \(status)" : detail
        case let .transferFailed(message):
            return message
        }
    }
}

public struct RemoteShellResult: Sendable {
    public let status: Int32
    public let stdoutText: String
    public let stderrText: String

    public init(status: Int32, stdoutText: String, stderrText: String) {
        self.status = status
        self.stdoutText = stdoutText
        self.stderrText = stderrText
    }

    public var succeeded: Bool { status == 0 }
}

public protocol RemoteShellConnection: Sendable {
    var shellPlatform: RemoteMachinePlatform? { get async }

    func runShell(_ command: String, stdin: Data?, timeout: TimeInterval) async throws
        -> RemoteShellResult

    func downloadFile(
        remotePath: String, to localURL: URL, maximumBytes: Int64,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws

    func uploadFile(
        localURL: URL, toRemotePath remotePath: String, progress: (@Sendable (Int64) -> Void)?
    ) async throws
}

extension RemoteShellConnection {
    public func downloadFile(
        remotePath: String, to localURL: URL, progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        try await downloadFile(
            remotePath: remotePath, to: localURL, maximumBytes: .max, progress: progress)
    }

    public func runChecked(_ command: String, timeout: TimeInterval) async throws
        -> RemoteShellResult
    {
        let result = try await runShell(command, stdin: nil, timeout: timeout)
        guard result.succeeded else {
            throw FileTransferError.commandFailed(
                command: command, status: result.status, stderr: result.stderrText)
        }
        return result
    }
}
