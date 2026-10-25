import EdithExtensionFiles
import Foundation

extension MachineSession: FinderSession {
    public var machineName: String { machine.name }

    public var remoteClient: (any FinderRemoteClient)? { uiClient }

    public var shellConnection: (any RemoteShellConnection)? { connectionRef }

    public var connectionState: FinderConnectionState {
        switch state {
        case .disconnected: .disconnected
        case .connecting, .reconnecting: .connecting
        case .connected: .connected
        case .failed: .failed
        }
    }

    public func connect() { start() }

    public func runCommand(_ command: String, timeout: TimeInterval) async -> Result<String, Error>
    {
        await runCommand(command, stdin: nil, timeout: timeout)
    }
}

extension SSHConnection: RemoteShellConnection {
    public var shellPlatform: RemoteMachinePlatform? {
        get async { remotePlatform }
    }

    public func runShell(_ command: String, stdin: Data?, timeout: TimeInterval) async throws
        -> RemoteShellResult
    {
        let result = try await run(command, stdin: stdin, timeout: timeout)
        return RemoteShellResult(
            status: result.status, stdoutText: result.stdoutText, stderrText: result.stderrText)
    }

    public func downloadFile(
        remotePath: String, to localURL: URL, maximumBytes: Int64,
        progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        try await download(
            remotePath: remotePath, to: localURL, maximumBytes: maximumBytes, progress: progress)
    }

    public func uploadFile(
        localURL: URL, toRemotePath remotePath: String, progress: (@Sendable (Int64) -> Void)?
    ) async throws {
        try await upload(localURL: localURL, toRemotePath: remotePath, progress: progress)
    }
}
