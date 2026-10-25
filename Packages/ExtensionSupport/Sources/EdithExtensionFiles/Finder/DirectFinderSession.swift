import AppKit
import EdithExtensionSupport
import Foundation
import Observation

public enum LocalShell {
    public static func run(_ command: String, stdin: Data? = nil, timeout: TimeInterval = 60) async
        -> Result<String, Error>
    {
        do {
            let result = try await CLICommandRunner.runSeparated(
                CLICommandRequest(
                    executableURL: URL(fileURLWithPath: "/bin/zsh"), arguments: ["-lc", command],
                    environment: CLIToolEnvironment.sanitized(), timeout: timeout,
                    maximumOutputBytes: 64 * 1_024 * 1_024, standardInputData: stdin,
                    terminatesProcessGroup: true),
                onStandardOutputLine: { _ in }, onStandardErrorLine: { _ in })
            guard result.terminationStatus == 0 else {
                return .failure(
                    FileTransferError.commandFailed(
                        command: command, status: result.terminationStatus,
                        stderr: result.standardError.isEmpty
                            ? result.standardOutput : result.standardError))
            }
            return .success(result.standardOutput)
        } catch {
            return .failure(error)
        }
    }
}

@MainActor
@Observable
public final class DirectFinderSession: FinderSession {
    public nonisolated let id: UUID
    public let machineName: String
    public let isLocal: Bool
    public private(set) var remotePlatform: RemoteMachinePlatform?
    public private(set) var connectionState: FinderConnectionState
    public let remoteClient: (any FinderRemoteClient)?
    private let connection: (any RemoteShellConnection)?

    public var shellConnection: (any RemoteShellConnection)? {
        connectionState.isConnected ? connection : nil
    }

    @ObservationIgnored private let connector: (@Sendable () async throws -> Void)?
    @ObservationIgnored public var opener: (@MainActor (RemoteFileEntry) -> Void)?
    @ObservationIgnored private var connecting: Task<Void, Never>?

    public init(
        id: UUID, name: String, isLocal: Bool, connection: (any RemoteShellConnection)? = nil,
        connector: (@Sendable () async throws -> Void)? = nil,
        remoteClient: (any FinderRemoteClient)? = nil,
        opener: (@MainActor (RemoteFileEntry) -> Void)? = nil
    ) {
        self.id = id
        machineName = name
        self.isLocal = isLocal
        self.connection = connection
        self.connector = connector
        self.remoteClient = remoteClient
        self.opener = opener
        connectionState = isLocal || remoteClient != nil ? .connected : .disconnected
    }

    public func connect() {
        guard !isLocal, remoteClient == nil, connecting == nil else { return }
        connectionState = .connecting
        connecting = Task { [weak self, connector, connection] in
            do {
                try await connector?()
                let platform = await connection?.shellPlatform
                guard let self else { return }
                remotePlatform = platform
                connectionState = connection == nil ? .failed : .connected
            } catch {
                self?.connectionState = .failed
            }
            self?.connecting = nil
        }
    }

    private static func capture<Value>(_ work: () async throws -> Value) async
        -> Result<Value, Error>
    {
        do { return .success(try await work()) } catch { return .failure(error) }
    }

    private func ensureConnected() async throws {
        guard !isLocal, remoteClient == nil, !connectionState.isConnected else { return }
        guard let connection else { throw MachineUIError.unavailable }
        connectionState = .connecting
        do {
            try await connector?()
            remotePlatform = await connection.shellPlatform
            connectionState = .connected
        } catch {
            connectionState = .failed
            throw error
        }
    }

    public func runCommand(_ command: String, timeout: TimeInterval) async -> Result<String, Error>
    {
        if let remoteClient {
            return await Self.capture {
                try await remoteClient.runCommand(
                    machineID: id, command: command, timeout: timeout)
            }
        }
        if isLocal { return await LocalShell.run(command, timeout: timeout) }
        do { try await ensureConnected() } catch { return .failure(error) }
        guard let shellConnection else { return .failure(MachineUIError.unavailable) }
        do {
            let result = try await shellConnection.runShell(
                command, stdin: nil, timeout: timeout)
            guard result.succeeded else {
                return .failure(
                    FileTransferError.commandFailed(
                        command: command, status: result.status,
                        stderr: result.stderrText.isEmpty
                            ? result.stdoutText : result.stderrText))
            }
            return .success(result.stdoutText)
        } catch {
            return .failure(error)
        }
    }

    public func listFiles(path: String) async -> Result<[RemoteFileEntry], Error> {
        if let remoteClient {
            return await Self.capture {
                try await remoteClient.listFiles(machineID: id, path: path)
            }
        }
        if isLocal { return .success(LocalFileListing.entries(path: path)) }
        do {
            try await ensureConnected()
            let listing = try await RemoteDirectoryOperationExecution.list(
                path: path, showHidden: true, using: directoryEndpoint)
            return .success(listing.entries)
        } catch {
            return .failure(error)
        }
    }

    public func homeDirectory() async -> Result<String, Error> {
        if let remoteClient {
            return await Self.capture { try await remoteClient.homeDirectory(machineID: id) }
        }
        if isLocal { return .success(FileManager.default.homeDirectoryForCurrentUser.path) }
        do {
            try await ensureConnected()
            return .success(try await directoryEndpoint.homeDirectory())
        } catch {
            return .failure(error)
        }
    }

    public func createDirectory(path: String) async -> Result<RemoteDirectoryCreation, Error> {
        if let remoteClient {
            return await Self.capture {
                try await remoteClient.createDirectory(machineID: id, path: path)
            }
        }
        do {
            try await ensureConnected()
            return .success(
                try await RemoteDirectoryOperationExecution.create(
                    path: path, using: directoryEndpoint))
        } catch {
            return .failure(error)
        }
    }

    public func openFile(_ entry: RemoteFileEntry) {
        opener?(entry)
    }

    private var directoryEndpoint: RemoteDirectoryEndpoint {
        if isLocal { return .local(machineName: machineName) }
        guard let shellConnection = connection else {
            return RemoteDirectoryEndpoint(
                machineName: machineName, home: { "/" }, list: { _ in [] },
                create: { _ in throw FileTransferError.transferFailed("Not connected.") })
        }
        return .remote(machineName: machineName, connection: shellConnection)
    }
}
