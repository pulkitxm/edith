import EdithExtensionSupport
import Foundation

@MainActor
public protocol FinderBridgeTransport: FinderRemoteClient {
    var bridgePresentationID: UUID { get }
    var filesOperation: String { get }
    var previewOperation: String { get }
    var exportOperation: String { get }
    var sessionOperation: String? { get }

    func bridgeOwned<Value>(_ work: @escaping @MainActor () async throws -> Value) async throws
        -> Value

    func bridgeJob<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request, progress: @escaping (FileOperationProgress?) -> Void
    ) async throws -> Reply

    func bridgeRequest<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request
    ) async throws -> Reply

    func bridgeCleanup<Request: Encodable>(_ operation: String, value: Request) async
}

extension FinderBridgeTransport {
    public var sessionOperation: String? { nil }

    private func session<Reply: Decodable>(_ request: FinderSessionRequest) async throws -> Reply {
        guard let operation = sessionOperation else { throw MachineUIError.unavailable }
        try request.validate()
        return try await bridgeJob(operation, value: request, progress: { _ in })
    }

    public func listFiles(machineID: UUID, path: String) async throws -> [RemoteFileEntry] {
        try await session(FinderSessionRequest(operation: .list, machineID: machineID, text: path))
    }

    public func homeDirectory(machineID: UUID) async throws -> String {
        try await session(FinderSessionRequest(operation: .home, machineID: machineID))
    }

    public func runCommand(machineID: UUID, command: String, timeout: TimeInterval) async throws
        -> String
    {
        try await session(
            FinderSessionRequest(
                operation: .command, machineID: machineID, text: command, timeout: timeout))
    }

    public func createDirectory(machineID: UUID, path: String) async throws
        -> RemoteDirectoryCreation
    {
        try await session(FinderSessionRequest(operation: .mkdir, machineID: machineID, text: path))
    }

    public func files(
        _ request: MachineFileRequest, progress: @escaping (FileOperationProgress?) -> Void
    ) async throws -> MachineFileState {
        var value = request
        value.presentationID = bridgePresentationID
        try value.validate()
        return try await bridgeJob(filesOperation, value: value, progress: progress)
    }

    public func materialize(entry: RemoteFileEntry, machineID: UUID, maximumBytes: Int64)
        async throws -> URL
    {
        try await bridgeOwned { [self] in
            try await materializeOwned(
                entry: entry, machineID: machineID, maximumBytes: maximumBytes)
        }
    }

    public func materializeDirectory(entry: RemoteFileEntry, machineID: UUID) async throws -> URL {
        try await bridgeOwned { [self] in
            try await materializeDirectoryOwned(entry: entry, machineID: machineID)
        }
    }

    private func materializeOwned(entry: RemoteFileEntry, machineID: UUID, maximumBytes: Int64)
        async throws -> URL
    {
        let handle: MachinePreviewHandle = try await bridgeJob(
            previewOperation,
            value: MachinePreviewRequest(
                operation: .prepare, machineID: machineID, entry: entry,
                maximumBytes: maximumBytes),
            progress: { _ in })
        guard handle.count <= UInt64(maximumBytes), !handle.name.contains("/"),
            !handle.name.contains("\\"), !handle.name.utf8.contains(0)
        else { throw MachineUIError.invalidRequest }
        let directory = ExtensionData.root.appendingPathComponent("ui-previews")
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let destination = directory.appendingPathComponent(handle.name)
        FileManager.default.createFile(atPath: destination.path, contents: Data())
        let output = try FileHandle(forWritingTo: destination)
        do {
            var offset: UInt64 = 0
            while true {
                try Task.checkCancellation()
                let chunk: MachinePreviewChunk = try await bridgeRequest(
                    previewOperation,
                    value: MachinePreviewRequest(
                        operation: .read, machineID: machineID, id: handle.id, offset: offset))
                guard chunk.offset == offset, chunk.bytes.count <= 65_536,
                    UInt64(chunk.bytes.count) <= handle.count - offset,
                    !chunk.bytes.isEmpty || chunk.complete
                else { throw MachineUIError.invalidRequest }
                try output.write(contentsOf: chunk.bytes)
                offset += UInt64(chunk.bytes.count)
                if chunk.complete {
                    guard offset == handle.count else { throw MachineUIError.invalidRequest }
                    break
                }
            }
            try output.close()
            return destination
        } catch {
            try? output.close()
            try? FileManager.default.removeItem(at: directory)
            await bridgeCleanup(
                previewOperation,
                value: MachinePreviewRequest(operation: .close, machineID: machineID, id: handle.id)
            )
            throw error
        }
    }

    private func materializeDirectoryOwned(entry: RemoteFileEntry, machineID: UUID) async throws
        -> URL
    {
        let handle: MachineDirectoryExportHandle = try await bridgeJob(
            exportOperation,
            value: MachineDirectoryExportRequest(
                operation: .prepare, machineID: machineID, entry: entry),
            progress: { _ in })
        guard MachineDirectoryExportRequest.validPath(handle.name), !handle.name.contains("/"),
            handle.items.count <= 8192, Set(handle.items.map(\.path)).count == handle.items.count,
            handle.items.allSatisfy({
                MachineDirectoryExportRequest.validPath($0.path)
                    && ($0.path == handle.name || $0.path.hasPrefix(handle.name + "/"))
            }),
            handle.count <= UInt64(RemoteFileOperationExecution.cacheLimitBytes),
            handle.items.reduce(
                UInt64(0),
                { $0 + min($1.count, UInt64(RemoteFileOperationExecution.cacheLimitBytes) + 1) })
                == handle.count
        else { throw MachineUIError.invalidRequest }
        let root = ExtensionData.root.appendingPathComponent("ui-previews").appendingPathComponent(
            UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let close = MachineDirectoryExportRequest(
            operation: .close, machineID: machineID, id: handle.id)
        do {
            for item in handle.items where item.kind != .symlink {
                try Task.checkCancellation()
                let url = root.appendingPathComponent(item.path)
                if item.kind == .directory {
                    try FileManager.default.createDirectory(
                        at: url, withIntermediateDirectories: false)
                    continue
                }
                guard item.kind == .file else { throw MachineUIError.invalidRequest }
                FileManager.default.createFile(atPath: url.path, contents: Data())
                let file = try FileHandle(forWritingTo: url)
                do {
                    var offset: UInt64 = 0
                    while true {
                        let chunk: MachinePreviewChunk = try await bridgeRequest(
                            exportOperation,
                            value: MachineDirectoryExportRequest(
                                operation: .read, machineID: machineID, id: handle.id,
                                path: item.path, offset: offset))
                        guard chunk.offset == offset, chunk.bytes.count <= 65536,
                            UInt64(chunk.bytes.count) <= item.count - offset,
                            !chunk.bytes.isEmpty || chunk.complete
                        else { throw MachineUIError.stale }
                        try file.write(contentsOf: chunk.bytes)
                        offset += UInt64(chunk.bytes.count)
                        if chunk.complete {
                            guard offset == item.count else { throw MachineUIError.stale }
                            break
                        }
                    }
                    try file.close()
                    if let modified = item.modified {
                        try FileManager.default.setAttributes(
                            [.modificationDate: modified], ofItemAtPath: url.path)
                    }
                } catch {
                    try? file.close()
                    throw error
                }
            }
            for item in handle.items where item.kind == .symlink {
                guard let target = item.linkTarget, target.utf8.count <= 4096,
                    !target.utf8.contains(0)
                else { throw MachineUIError.invalidRequest }
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent(item.path).path, withDestinationPath: target
                )
            }
            let _: Bool = try await bridgeRequest(exportOperation, value: close)
            return root.appendingPathComponent(handle.name)
        } catch {
            try? FileManager.default.removeItem(at: root)
            await bridgeCleanup(exportOperation, value: close)
            throw error
        }
    }
}
