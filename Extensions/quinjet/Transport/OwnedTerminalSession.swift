import EdithExtensionSupport
import Foundation

struct OwnedTerminalLaunch: Equatable {
    let executable: String
    let arguments: [String]
    let environment: [String]
    let currentDirectory: String
    let allowsLocalFileLinks: Bool
    let resetTerminalAfterInterrupt: Bool
    var startupCommand: String? { nil }
}

struct OwnedTerminalHandle: Codable, Equatable {
    let owner: String
    let id: UUID
    let generation: UUID
}

struct OwnedTerminalDescriptor: Codable, Equatable {
    let handle: OwnedTerminalHandle
    let directory: String
    let allowsLocalFileLinks: Bool
    let resetTerminalAfterInterrupt: Bool
}

struct OwnedTerminalRequest: Codable {
    let session: OwnedTerminalHandle
    var offset: UInt64? = nil
    var bytes: Data? = nil
    var columns: UInt16? = nil
    var rows: UInt16? = nil
    var pixelWidth: UInt16? = nil
    var pixelHeight: UInt16? = nil
}

enum OwnedTerminalContext {
    @TaskLocal static var registry: OwnedTerminalSessionRegistry?
}

@MainActor final class OwnedTerminalSessionRegistry {
    let files = OwnedTerminalFiles()
    private var sessions: [UUID: OwnedTerminalSession] = [:]
    private var stopped = false
    var acceptsSession: Bool { !stopped && sessions.count < 512 }

    func register(_ session: OwnedTerminalSession) {
        sessions[session.descriptor.handle.id] = session
    }

    func find(_ handle: OwnedTerminalHandle) -> OwnedTerminalSession? {
        guard !stopped, let session = sessions[handle.id], session.descriptor.handle == handle
        else { return nil }
        return session
    }

    func remove(_ handle: OwnedTerminalHandle) { sessions[handle.id] = nil }

    func stopAllAndWait() async {
        stopAll()
        await files.stopAndWait()
    }

    func stopAll() {
        stopped = true
        files.stop()
        let owned = Array(sessions.values)
        sessions.removeAll()
        for session in owned { session.stop() }
    }
}

@MainActor final class OwnedTerminalSession {
    static let owner = "quinjet"
    let descriptor: OwnedTerminalDescriptor
    private let files: OwnedTerminalFiles
    private let terminal: OwnedTerminalPTY
    private weak var registry: OwnedTerminalSessionRegistry?
    private var stopped = false
    private var writing = false

    init(launch: OwnedTerminalLaunch) throws {
        guard Bundle.main.bundleURL.pathExtension != "appex" else {
            throw ExtensionPeerError.rejected("Only the owning engine can launch a terminal.")
        }
        let registry = OwnedTerminalContext.registry
        guard registry?.acceptsSession != false else { throw ExtensionPeerError.unavailable }
        files = registry?.files ?? OwnedTerminalFiles()
        terminal = try OwnedTerminalPTY(launch: launch)
        descriptor = .init(
            handle: .init(owner: Self.owner, id: UUID(), generation: UUID()),
            directory: launch.currentDirectory, allowsLocalFileLinks: launch.allowsLocalFileLinks,
            resetTerminalAfterInterrupt: launch.resetTerminalAfterInterrupt)
        self.registry = registry
        registry?.register(self)
    }

    func execute(_ operation: String, payload: Data) async throws -> Data {
        guard !stopped, payload.count <= 32768,
            let object = try JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { throw ExtensionPeerError.invalidRequest }
        guard let session = object["session"] as? [String: Any],
            Set(session.keys) == ["owner", "id", "generation"]
        else { throw ExtensionPeerError.invalidRequest }
        let request = try JSONDecoder().decode(OwnedTerminalRequest.self, from: payload)
        guard request.session == descriptor.handle else { throw ExtensionPeerError.invalidRequest }
        try Task.checkCancellation()
        if OwnedTerminalFiles.admits(operation) {
            return try await files.execute(
                operation, payload: payload, session: descriptor.handle,
                local: descriptor.allowsLocalFileLinks)
        }
        switch operation {
        case "quinjet.terminal.read":
            guard Set(object.keys) == ["session", "offset"], let cursor = request.offset else {
                throw ExtensionPeerError.invalidRequest
            }
            for _ in 0..<25 {
                guard !stopped else { throw ExtensionPeerError.unavailable }
                let output = try terminal.read(after: cursor)
                if !output.bytes.isEmpty || output.exitCode != nil {
                    return try JSONEncoder().encode(output)
                }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard !stopped else { throw ExtensionPeerError.unavailable }
            return try JSONEncoder().encode(terminal.read(after: cursor))
        case "quinjet.terminal.input":
            guard Set(object.keys) == ["session", "bytes"], let bytes = request.bytes else {
                throw ExtensionPeerError.invalidRequest
            }
            guard !writing else { throw ExtensionPeerError.unavailable }
            writing = true
            defer { writing = false }
            do {
                try terminal.send(bytes)
                let deadline = ContinuousClock.now + .seconds(5)
                while terminal.hasPendingInput {
                    try Task.checkCancellation()
                    guard !stopped else { throw ExtensionPeerError.unavailable }
                    guard ContinuousClock.now < deadline else {
                        throw ExtensionPeerError.rejected("The terminal is not consuming input.")
                    }
                    try terminal.flushInput()
                    if terminal.hasPendingInput { try await Task.sleep(for: .milliseconds(10)) }
                }
            } catch {
                terminal.discardPendingInput()
                throw error
            }
        case "quinjet.terminal.resize":
            guard Set(object.keys) == ["session", "columns", "rows", "pixelWidth", "pixelHeight"],
                let columns = request.columns, let rows = request.rows,
                let width = request.pixelWidth, let height = request.pixelHeight
            else {
                throw ExtensionPeerError.invalidRequest
            }
            try terminal.resize(
                columns: columns, rows: rows, pixelWidth: width, pixelHeight: height)
        case "quinjet.terminal.close":
            guard Set(object.keys) == ["session"] else { throw ExtensionPeerError.invalidRequest }
            stop()
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        files.close(descriptor.handle)
        terminal.close()
        registry?.remove(descriptor.handle)
    }
}

@MainActor final class OwnedEngineRequests {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    private struct Waiting {
        let id: UUID
        let read: Bool
        let bytes: Int
        let continuation: CheckedContinuation<Void, Error>
    }
    private let invoke: Invoke
    private var activeReads = 0
    private var activeControls = 0
    private var waiting: [Waiting] = []
    private var waitingBytes = 0
    private var stopped = false

    init(invoke: @escaping Invoke) { self.invoke = invoke }

    func perform(_ operation: String, payload: Data) async throws -> Data {
        try Task.checkCancellation()
        let id = UUID()
        let read = operation == OwnedTerminalSession.owner + ".terminal.read"
        try await withTaskCancellationHandler {
            try await acquire(id, read: read, bytes: payload.count)
        } onCancel: {
            Task { @MainActor in self.cancel(id) }
        }
        defer { release(read: read) }
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        let data = try await invoke(operation, payload)
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return data
    }

    func stop() {
        stopped = true
        let pending = waiting
        waiting.removeAll()
        waitingBytes = 0
        for request in pending { request.continuation.resume(throwing: CancellationError()) }
    }

    private func acquire(_ id: UUID, read: Bool, bytes: Int) async throws {
        try Task.checkCancellation()
        guard !stopped else { throw ExtensionPeerError.unavailable }
        if (read ? activeReads : activeControls) < 4 {
            reserve(read: read)
            return
        }
        guard waiting.count < 512, bytes <= 2_097_152 - waitingBytes else {
            throw ExtensionPeerError.unavailable
        }
        try await withCheckedThrowingContinuation { continuation in
            waiting.append(.init(id: id, read: read, bytes: bytes, continuation: continuation))
            waitingBytes += bytes
        }
    }

    private func reserve(read: Bool) {
        if read { activeReads += 1 } else { activeControls += 1 }
    }

    private func release(read: Bool) {
        if read { activeReads -= 1 } else { activeControls -= 1 }
        guard !stopped, let index = waiting.firstIndex(where: { $0.read == read }) else { return }
        let request = waiting.remove(at: index)
        waitingBytes -= request.bytes
        reserve(read: read)
        request.continuation.resume()
    }

    private func cancel(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        let request = waiting.remove(at: index)
        waitingBytes -= request.bytes
        request.continuation.resume(throwing: CancellationError())
    }
}

@MainActor final class OwnedTerminalClient {
    typealias Invoke = @MainActor (String, Data) async throws -> Data
    let descriptor: OwnedTerminalDescriptor
    private let invoke: Invoke
    private var stopped = false
    private var pending: [UUID: Task<Data, Error>] = [:]

    init(descriptor: OwnedTerminalDescriptor, invoke: @escaping Invoke) throws {
        guard descriptor.handle.owner == OwnedTerminalSession.owner,
            descriptor.directory.utf8.count <= 4096, !descriptor.directory.utf8.contains(0)
        else { throw ExtensionPeerError.invalidRequest }
        self.descriptor = descriptor
        self.invoke = invoke
    }

    convenience init(descriptor: OwnedTerminalDescriptor, client: ExtensionEngineClient) throws {
        try self.init(descriptor: descriptor) { operation, payload in
            try await client.invoke(operation, payload: payload)
        }
    }

    func read(after offset: UInt64) async throws -> OwnedTerminalPTY.Output {
        let data = try await perform(
            "read", request: .init(session: descriptor.handle, offset: offset))
        let output = try JSONDecoder().decode(OwnedTerminalPTY.Output.self, from: data)
        guard output.bytes.count <= 32768, output.nextOffset >= offset,
            output.nextOffset - offset == UInt64(output.bytes.count)
        else {
            throw ExtensionPeerError.invalidRequest
        }
        return output
    }

    func input(_ bytes: Data) async throws {
        guard !bytes.isEmpty, bytes.count <= OwnedTerminalPTY.maximumInputBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        _ = try await perform("input", request: .init(session: descriptor.handle, bytes: bytes))
    }

    func resize(columns: UInt16, rows: UInt16, pixelWidth: UInt32 = 0, pixelHeight: UInt32 = 0)
        async throws
    {
        guard columns > 0, rows > 0 else { throw ExtensionPeerError.invalidRequest }
        _ = try await perform(
            "resize",
            request: .init(
                session: descriptor.handle, columns: columns, rows: rows,
                pixelWidth: UInt16(clamping: pixelWidth), pixelHeight: UInt16(clamping: pixelHeight)
            ))
    }

    func close() async throws {
        _ = try await perform("close", request: .init(session: descriptor.handle))
        stop()
    }

    func stop() {
        stopped = true
        for task in pending.values { task.cancel() }
        pending.removeAll()
    }

    private func perform(_ action: String, request: OwnedTerminalRequest) async throws -> Data {
        try await perform(action, payload: JSONEncoder().encode(request))
    }

    func perform(_ action: String, payload: Data) async throws -> Data {
        guard !stopped, pending.count < 8, payload.count <= 32768 else {
            throw ExtensionPeerError.unavailable
        }
        try Task.checkCancellation()
        let id = UUID()
        let task = Task {
            try await invoke(OwnedTerminalSession.owner + ".terminal." + action, payload)
        }
        pending[id] = task
        defer { pending[id] = nil }
        let result = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try Task.checkCancellation()
        guard !task.isCancelled else { throw CancellationError() }
        guard !stopped else { throw ExtensionPeerError.unavailable }
        return result
    }
}

extension OwnedTerminalClient {
    func fileRequest(_ action: String, _ request: OwnedTerminalDropRequest) async throws
        -> OwnedTerminalDropReceipt
    {
        let data = try await perform("drop." + action, payload: JSONEncoder().encode(request))
        return try JSONDecoder().decode(OwnedTerminalDropReceipt.self, from: data)
    }

    func uploadBytes(_ bytes: Data, name: String) async throws -> [String] {
        guard UInt64(bytes.count) <= OwnedTerminalFiles.maximumBytes else {
            throw ExtensionPeerError.invalidRequest
        }
        let begun = try await fileRequest("begin", .init(session: descriptor.handle, names: [name]))
        guard let token = begun.token else { throw ExtensionPeerError.invalidRequest }
        do {
            var offset = 0
            while offset < bytes.count {
                try Task.checkCancellation()
                let end = min(bytes.count, offset + 16384)
                let receipt = try await fileRequest(
                    "write",
                    .init(
                        session: descriptor.handle, token: token, index: 0, offset: UInt64(offset),
                        bytes: bytes.subdata(in: offset..<end)))
                guard receipt.offset == UInt64(end) else { throw ExtensionPeerError.invalidRequest }
                offset = end
            }
            var result = try await fileRequest(
                "finish", .init(session: descriptor.handle, token: token))
            while result.state == "running" {
                try await Task.sleep(for: .milliseconds(50));
                result = try await fileRequest(
                    "status", .init(session: descriptor.handle, token: token))
            }
            guard let paths = result.paths, paths.count == 1 else {
                throw ExtensionPeerError.invalidRequest
            }
            return paths
        } catch {
            let cleanup = Task {
                _ = try? await self.fileRequest(
                    "cancel", .init(session: descriptor.handle, token: token))
            }
            await cleanup.value
            throw error
        }
    }

    func uploadFiles(_ urls: [URL]) async throws -> [String] {
        guard !urls.isEmpty, urls.count <= 64, urls.allSatisfy(\.isFileURL) else {
            throw ExtensionPeerError.invalidRequest
        }
        let secured = urls.filter { $0.startAccessingSecurityScopedResource() }
        defer { secured.forEach { $0.stopAccessingSecurityScopedResource() } }
        let reply = try await fileRequest(
            "begin", .init(session: descriptor.handle, names: urls.map(\.lastPathComponent)))
        guard let token = reply.token else { throw ExtensionPeerError.invalidRequest }
        do {
            for (index, url) in urls.enumerated() {
                try Task.checkCancellation()
                let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard values.isRegularFile == true, let size = values.fileSize, size >= 0,
                    UInt64(size) <= OwnedTerminalFiles.maximumBytes
                else { throw ExtensionPeerError.invalidRequest }
                let reader = try FileHandle(forReadingFrom: url)
                defer { try? reader.close() }
                var offset: UInt64 = 0
                while true {
                    try Task.checkCancellation()
                    let bytes = try reader.read(upToCount: 16384) ?? Data()
                    if bytes.isEmpty { break }
                    let receipt = try await fileRequest(
                        "write",
                        .init(
                            session: descriptor.handle, token: token, index: index, offset: offset,
                            bytes: bytes))
                    offset += UInt64(bytes.count)
                    guard receipt.offset == offset else { throw ExtensionPeerError.invalidRequest }
                }
                guard offset == UInt64(size) else {
                    throw ExtensionPeerError.rejected("The dropped file changed during transfer.")
                }
            }
            var receipt = try await fileRequest(
                "finish", .init(session: descriptor.handle, token: token))
            while receipt.state == "running" {
                try await Task.sleep(for: .milliseconds(50))
                receipt = try await fileRequest(
                    "status", .init(session: descriptor.handle, token: token))
            }
            guard let paths = receipt.paths, paths.count == urls.count,
                paths.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 4096 && !$0.utf8.contains(0) })
            else { throw ExtensionPeerError.invalidRequest }
            return paths
        } catch {
            let cleanup = Task {
                _ = try? await self.fileRequest(
                    "cancel", .init(session: descriptor.handle, token: token))
            }
            await cleanup.value
            throw error
        }
    }
}
