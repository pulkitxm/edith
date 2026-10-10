import EdithExtensionSupport
import Foundation

@MainActor public final class MachineUIClient {
    private let client: ExtensionEngineClient
    private var generation = 0
    private var stopped = false
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var polling: Task<Void, Never>?
    var receive: (MachineUIState) -> Void = { _ in }
    var failure: (String) -> Void = { _ in }

    public init(client: ExtensionEngineClient) { self.client = client }

    func start() {
        guard polling == nil, !stopped else { return }
        polling = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await refresh() } catch {
                    guard !Task.isCancelled, !stopped else { return }
                    failure(error.localizedDescription)
                }
                do { try await Task.sleep(for: .seconds(1)) } catch { return }
            }
        }
    }

    public func shutdown() {
        guard !stopped else { return }
        stopped = true
        generation += 1
        polling?.cancel(); polling = nil
        for task in tasks.values { task.cancel() }
        tasks = [:]
        client.invalidate()
    }

    func refresh() async throws {
        let state: MachineUIState = try await request(
            "machines.ui.state", value: [String: String]())
        guard state.machines.count <= 1_024, state.sessions.count <= 1_025,
            Set(state.machines.map(\.id)).count == state.machines.count,
            Set(state.sessions.map { $0.machine.id }).count == state.sessions.count,
            state.sessions.allSatisfy({
                $0.histories.count == 8 && $0.histories.allSatisfy { $0.count <= 60 }
            })
        else { throw MachineUIError.invalidRequest }
        receive(state)
        let _: Bool = try await request(
            "machines.ui.heartbeat", value: MachineUIPresentation(id: client.presentationID))
        _ = try await terminal(
            MachineTerminalRequest(operation: .heartbeat, machineID: Machine.localID))
    }

    public func action<Value: Decodable>(_ value: MachineUIAction) async throws -> Value {
        var value = value
        value.presentationID = client.presentationID
        try value.validate()
        return try await job("machines.ui.action", value: value)
    }

    func mutate(_ value: MachineUIMutation) async throws {
        let state: MachineUIState = try await request("machines.ui.mutate", value: value)
        receive(state)
    }

    func materialize(entry: RemoteFileEntry, machineID: UUID, maximumBytes: Int64) async throws
        -> URL
    {
        let handle: MachinePreviewHandle = try await job(
            "machines.ui.preview",
            value: MachinePreviewRequest(
                operation: .prepare, machineID: machineID, entry: entry, maximumBytes: maximumBytes)
        )
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
                let chunk: MachinePreviewChunk = try await request(
                    "machines.ui.preview",
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
            let _: Bool? = try? await request(
                "machines.ui.preview",
                value: MachinePreviewRequest(operation: .close, machineID: machineID, id: handle.id)
            )
            throw error
        }
    }

    func materializeDirectory(entry: RemoteFileEntry, machineID: UUID) async throws -> URL {
        let handle: MachineDirectoryExportHandle = try await job(
            "machines.ui.export",
            value: MachineDirectoryExportRequest(
                operation: .prepare, machineID: machineID, entry: entry))
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
                        at: url, withIntermediateDirectories: false);
                    continue
                }
                guard item.kind == .file else { throw MachineUIError.invalidRequest }
                FileManager.default.createFile(atPath: url.path, contents: Data())
                let file = try FileHandle(forWritingTo: url)
                do {
                    var offset: UInt64 = 0
                    while true {
                        let chunk: MachinePreviewChunk = try await request(
                            "machines.ui.export",
                            value: MachineDirectoryExportRequest(
                                operation: .read, machineID: machineID, id: handle.id,
                                path: item.path, offset: offset))
                        guard chunk.offset == offset, chunk.bytes.count <= 65536,
                            UInt64(chunk.bytes.count) <= item.count - offset,
                            !chunk.bytes.isEmpty || chunk.complete
                        else { throw MachineUIError.stale }
                        try file.write(contentsOf: chunk.bytes); offset += UInt64(chunk.bytes.count)
                        if chunk.complete {
                            guard offset == item.count else { throw MachineUIError.stale }; break
                        }
                    }
                    try file.close()
                    if let modified = item.modified {
                        try FileManager.default.setAttributes(
                            [.modificationDate: modified], ofItemAtPath: url.path)
                    }
                } catch { try? file.close(); throw error }
            }
            for item in handle.items where item.kind == .symlink {
                guard let target = item.linkTarget, target.utf8.count <= 4096,
                    !target.utf8.contains(0)
                else { throw MachineUIError.invalidRequest }
                try FileManager.default.createSymbolicLink(
                    atPath: root.appendingPathComponent(item.path).path, withDestinationPath: target
                )
            }
            let _: Bool = try await request("machines.ui.export", value: close)
            return root.appendingPathComponent(handle.name)
        } catch {
            try? FileManager.default.removeItem(at: root)
            let cleanup = Task {
                let _: Bool? = try? await self.request("machines.ui.export", value: close)
            }
            await cleanup.value
            throw error
        }
    }

    func openWindow(_ value: MachineHostWindowRequest) async throws {
        var value = value; value.presentationID = client.presentationID
        try value.validate()
        let _: Bool = try await job("machines.ui.openWindow", value: value)
    }

    func files(
        _ value: MachineFileRequest, progress: @escaping (FileOperationProgress?) -> Void = { _ in }
    ) async throws -> MachineFileState {
        var value = value; value.presentationID = client.presentationID
        try value.validate()
        return try await job("machines.ui.files", value: value, progress: progress)
    }

    func logs(_ value: MachineLogRequest) async throws -> MachineLogFrame {
        var value = value; value.presentationID = client.presentationID
        try value.validate()
        return try await request("machines.ui.logs", value: value)
    }

    func terminal(_ value: MachineTerminalRequest) async throws -> MachineTerminalFrame {
        var value = value
        value.presentationID = client.presentationID
        try value.validate()
        let frame: MachineTerminalFrame = try await request("machines.ui.terminal", value: value)
        guard frame.bytes.count <= 32_768, frame.paths.count <= 128,
            frame.paths.allSatisfy({ $0.utf8.count <= 4096 && !$0.utf8.contains(0) }),
            frame.shells.count <= WindowsTerminalShell.allCases.count + 1
        else { throw MachineUIError.invalidRequest }
        if value.operation == .read {
            guard frame.handle == value.handle, frame.nextOffset >= value.offset,
                frame.nextOffset - value.offset == UInt64(frame.bytes.count)
            else { throw MachineUIError.stale }
        }
        return frame
    }

    func configuration() async throws -> MachineUIConfigurationState {
        try await request("machines.ui.configuration", value: [String: String]())
    }

    func probe(_ machine: Machine, secrets: MachineSecretChanges) async throws -> String {
        try await job(
            "machines.ui.probe",
            value: MachineUIMutation(operation: .add, machine: machine, secrets: secrets))
    }

    func workspace(_ value: WorkspaceStore) async throws -> WorkspaceStore {
        try await request("machines.ui.workspace", value: value)
    }

    public func enqueue(_ value: MachineUIAction) {
        enqueue {
            let _: Bool = try await self.action(value)
        }
    }

    func enqueue(_ work: @escaping @MainActor () async throws -> Void) {
        guard !stopped else { return }
        let id = UUID()
        tasks[id] = Task { [weak self] in
            do { try await work() } catch {
                if !Task.isCancelled, let self, !stopped { failure(error.localizedDescription) }
            }
            self?.tasks.removeValue(forKey: id)
        }
    }

    private func job<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request, progress: (FileOperationProgress?) -> Void = { _ in }
    ) async throws -> Reply {
        let id: UUID = try await request(
            "machines.ui.begin",
            value: MachineUIJobInput(operation: operation, payload: JSONEncoder().encode(value)))
        return try await withTaskCancellationHandler {
            while true {
                try Task.checkCancellation()
                let state: MachineUIJobState = try await request(
                    "machines.ui.poll", value: MachineUIJobPoll(id: id, consume: true))
                if let value = state.progress {
                    guard value.total >= 0, value.completed >= 0, value.title.utf8.count <= 4096,
                        value.bytesTransferred >= 0
                    else { throw MachineUIError.invalidRequest }
                }
                progress(state.progress)
                if state.complete {
                    guard let reply = state.reply else { throw MachineUIError.invalidRequest }
                    if let error = reply.error { throw MachineUIFailure(message: error) }
                    guard let data = reply.value else { throw MachineUIError.invalidRequest }
                    return try JSONDecoder().decode(Reply.self, from: data)
                }
                try await Task.sleep(for: .milliseconds(200))
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard let self else { return }
                let _: Bool? = try? await request("machines.ui.cancel", value: id)
            }
        }
    }

    private func request<Request: Encodable, Reply: Decodable>(
        _ operation: String, value: Request
    ) async throws -> Reply {
        guard !stopped else { throw MachineUIError.unavailable }
        let generation = generation
        let bytes = try await client.invoke(operation, payload: JSONEncoder().encode(value))
        try Task.checkCancellation()
        guard !stopped, generation == self.generation else { throw MachineUIError.stale }
        let reply = try JSONDecoder().decode(MachineUIReply.self, from: bytes)
        if let error = reply.error { throw MachineUIFailure(message: error) }
        guard let value = reply.value, value.count <= 6_291_456 else {
            throw MachineUIError.invalidRequest
        }
        return try JSONDecoder().decode(Reply.self, from: value)
    }
}
