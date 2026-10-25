import Foundation
import SwiftUI

public enum FinderConnectionState: Equatable, Sendable {
    case disconnected
    case connecting
    case connected
    case failed

    public var isConnected: Bool { self == .connected }
}

@MainActor
public protocol FinderRemoteClient: AnyObject {
    func files(
        _ request: MachineFileRequest, progress: @escaping (FileOperationProgress?) -> Void
    ) async throws -> MachineFileState

    func materialize(entry: RemoteFileEntry, machineID: UUID, maximumBytes: Int64) async throws
        -> URL

    func materializeDirectory(entry: RemoteFileEntry, machineID: UUID) async throws -> URL

    func listFiles(machineID: UUID, path: String) async throws -> [RemoteFileEntry]
    func homeDirectory(machineID: UUID) async throws -> String
    func runCommand(machineID: UUID, command: String, timeout: TimeInterval) async throws -> String
    func createDirectory(machineID: UUID, path: String) async throws -> RemoteDirectoryCreation
}

extension FinderRemoteClient {
    public func listFiles(machineID: UUID, path: String) async throws -> [RemoteFileEntry] {
        throw MachineUIError.unavailable
    }

    public func homeDirectory(machineID: UUID) async throws -> String {
        throw MachineUIError.unavailable
    }

    public func runCommand(machineID: UUID, command: String, timeout: TimeInterval) async throws
        -> String
    {
        throw MachineUIError.unavailable
    }

    public func createDirectory(machineID: UUID, path: String) async throws
        -> RemoteDirectoryCreation
    {
        throw MachineUIError.unavailable
    }
}

public struct FinderSessionRequest: Codable, Sendable {
    public enum Operation: String, Codable, Sendable { case list, home, command, mkdir }
    public var operation: Operation
    public var machineID: UUID
    public var text = ""
    public var timeout: TimeInterval = 60

    public func validate() throws {
        guard text.utf8.count <= 65_536, !text.utf8.contains(0), timeout.isFinite, timeout > 0,
            timeout <= 1800
        else { throw MachineUIError.invalidRequest }
    }
}

@MainActor
public protocol FinderSession: AnyObject {
    nonisolated var id: UUID { get }
    var machineName: String { get }
    var isLocal: Bool { get }
    var remotePlatform: RemoteMachinePlatform? { get }
    var connectionState: FinderConnectionState { get }
    var remoteClient: (any FinderRemoteClient)? { get }
    var shellConnection: (any RemoteShellConnection)? { get }

    func connect()
    func runCommand(_ command: String, timeout: TimeInterval) async -> Result<String, Error>
    func listFiles(path: String) async -> Result<[RemoteFileEntry], Error>
    func homeDirectory() async -> Result<String, Error>
    func createDirectory(path: String) async -> Result<RemoteDirectoryCreation, Error>
    func openFile(_ entry: RemoteFileEntry)
}

private struct FinderPresentedKey: EnvironmentKey {
    static let defaultValue = true
}

private struct FinderConnectionsEnabledKey: EnvironmentKey {
    static let defaultValue = true
}

extension EnvironmentValues {
    public var finderPresented: Bool {
        get { self[FinderPresentedKey.self] }
        set { self[FinderPresentedKey.self] = newValue }
    }

    public var finderConnectionsEnabled: Bool {
        get { self[FinderConnectionsEnabledKey.self] }
        set { self[FinderConnectionsEnabledKey.self] = newValue }
    }
}
