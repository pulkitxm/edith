import EdithCore
import Foundation

public enum RemoteDirectoryOperation: String, CaseIterable, Sendable {
    case list
    case create

    public var descriptor: UserOperationDescriptor {
        switch self {
        case .list:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "machines.files.list"),
                summary: "List a machine directory.",
                cli: ["machines", "files", "ls"], effect: .read)
        case .create:
            UserOperationDescriptor(
                id: UserOperationID(rawValue: "machines.files.create-directory"),
                summary: "Create a machine directory.",
                cli: ["machines", "files", "mkdir"], effect: .write)
        }
    }
}

public struct RemoteDirectoryListing: Equatable, Sendable {
    public let machineName: String
    public let path: String
    public let entries: [RemoteFileEntry]

    public init(machineName: String, path: String, entries: [RemoteFileEntry]) {
        self.machineName = machineName
        self.path = path
        self.entries = entries
    }
}

public struct RemoteDirectoryCreation: Equatable, Sendable {
    public let machineName: String
    public let path: String

    public init(machineName: String, path: String) {
        self.machineName = machineName
        self.path = path
    }
}

public enum RemoteDirectoryOperationError: LocalizedError, Equatable, Sendable {
    case invalidHomeDirectory

    public var errorDescription: String? {
        "The machine reported an invalid home directory."
    }
}

public struct RemoteDirectoryEndpoint: Sendable {
    public let machineName: String
    private let homeAction: @Sendable () async throws -> String
    private let listAction: @Sendable (String) async throws -> [RemoteFileEntry]
    private let createAction: @Sendable (String) async throws -> Void

    public init(
        machineName: String,
        home: @escaping @Sendable () async throws -> String,
        list: @escaping @Sendable (String) async throws -> [RemoteFileEntry],
        create: @escaping @Sendable (String) async throws -> Void
    ) {
        self.machineName = machineName
        homeAction = home
        listAction = list
        createAction = create
    }

    public func homeDirectory() async throws -> String {
        try await homeAction()
    }

    public func list(_ path: String) async throws -> [RemoteFileEntry] {
        try await listAction(path)
    }

    public func create(_ path: String) async throws {
        try await createAction(path)
    }

    public static func remote(machine: Machine, connection: SSHConnection) -> Self {
        RemoteDirectoryEndpoint(
            machineName: machine.name,
            home: {
                let platform = await connection.remotePlatform ?? .linux
                let command = platform == .windows
                    ? WindowsFileCommands.home() : "printf %s \"$HOME\""
                let result = try await connection.run(command, timeout: 15)
                guard result.succeeded else {
                    throw SSHConnectionError.commandFailed(
                        command: "home", status: result.status, stderr: result.stderrText)
                }
                return result.stdoutText.trimmingCharacters(in: .whitespacesAndNewlines)
            },
            list: { path in
                let platform = await connection.remotePlatform ?? .linux
                let result = try await connection.run(
                    FileListing.command(
                        path: path, showHidden: true, platform: platform), timeout: 45)
                return try decodedListing(result, path: path)
            },
            create: { path in
                let platform = await connection.remotePlatform ?? .linux
                _ = try await connection.runChecked(
                    FileOperations.makeDirectoryCommand(
                        path: path, platform: platform), timeout: 300)
            })
    }

    public static func local(machine: Machine) -> Self {
        RemoteDirectoryEndpoint(
            machineName: machine.name,
            home: { FileManager.default.homeDirectoryForCurrentUser.path },
            list: { MachineSession.listLocalFiles(path: $0) },
            create: {
                try FileManager.default.createDirectory(
                    at: URL(fileURLWithPath: $0), withIntermediateDirectories: true)
            })
    }

    static func decodedListing(_ result: SSHExecResult, path: String) throws -> [RemoteFileEntry] {
        guard result.succeeded else {
            throw SSHConnectionError.commandFailed(
                command: "list", status: result.status,
                stderr: result.stderrText.isEmpty
                    ? "Could not read that folder." : result.stderrText)
        }
        return FileListing.parse(output: result.stdoutText, parent: path)
    }
}

public enum RemoteDirectoryOperationExecution {
    public static func list(
        path: String, showHidden: Bool, using endpoint: RemoteDirectoryEndpoint
    ) async throws -> RemoteDirectoryListing {
        let resolved: String
        if path == "." {
            let home = try await endpoint.homeDirectory()
            guard home.hasPrefix("/") || FileListing.isWindowsPath(home) else {
                throw RemoteDirectoryOperationError.invalidHomeDirectory
            }
            resolved = home
        } else {
            resolved = path
        }
        var entries = try await endpoint.list(resolved)
        if !showHidden { entries.removeAll(where: \.isHidden) }
        return RemoteDirectoryListing(
            machineName: endpoint.machineName, path: resolved, entries: entries)
    }

    public static func create(
        path: String, using endpoint: RemoteDirectoryEndpoint
    ) async throws -> RemoteDirectoryCreation {
        try await endpoint.create(path)
        return RemoteDirectoryCreation(machineName: endpoint.machineName, path: path)
    }
}
