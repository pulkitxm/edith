import CoreFoundation
import Foundation
import Logging
import MCP

public actor DatabaseMCPByteTransport: Transport {
    public nonisolated let logger = Logger(
        label: "edith.database.mcp",
        factory: { _ in SwiftLogNoOpLogHandler() })
    private let readBytes: @Sendable () async throws -> Data?
    private let writeBytes: @Sendable (Data) async throws -> Void
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var task: Task<Void, Never>?
    private var connected = false
    private var pending: Set<String> = []
    private var waiter: CheckedContinuation<Void, Error>?

    public init(
        read: @escaping @Sendable () async throws -> Data?,
        write: @escaping @Sendable (Data) async throws -> Void
    ) {
        readBytes = read
        writeBytes = write
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        guard task == nil, !connected else {
            throw MCPError.internalError("The transport is active.")
        }
        connected = true
        task = Task { await receiveBytes() }
    }

    public func disconnect() async {
        connected = false
        let current = task
        task = nil
        current?.cancel()
        cancelWaiter()
        continuation.finish()
        await current?.value
        pending.removeAll()
    }

    public func send(_ data: Data) async throws {
        guard connected, data.count <= 4 * 1_024 * 1_024 else {
            throw MCPError.internalError("The message cannot be sent.")
        }
        try Task.checkCancellation()
        var line = data
        line.append(10)
        try await writeBytes(line)
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            object["method"] == nil, let key = try requestKey(object["id"])
        {
            pending.remove(key)
            let current = waiter
            waiter = nil
            current?.resume()
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> { stream }

    private func receiveBytes() async {
        var buffer = Data()
        do {
            while connected {
                try Task.checkCancellation()
                guard let bytes = try await readBytes() else {
                    guard buffer.isEmpty else {
                        throw MCPError.invalidRequest("The final MCP message has no newline.")
                    }
                    while !pending.isEmpty { try await waitForChange() }
                    continuation.finish()
                    return
                }
                guard bytes.count <= 16_384 else {
                    throw MCPError.invalidRequest("The MCP input chunk exceeds 16 KiB.")
                }
                buffer.append(bytes)
                while let newline = buffer.firstIndex(of: 10) {
                    let message = Data(buffer[..<newline])
                    buffer = Data(buffer[buffer.index(after: newline)...])
                    guard message.count <= 4 * 1_024 * 1_024 else {
                        throw MCPError.invalidRequest("The MCP message exceeds 4 MiB.")
                    }
                    if message.isEmpty { continue }
                    guard
                        let object = try JSONSerialization.jsonObject(with: message)
                            as? [String: Any]
                    else { throw MCPError.invalidRequest("An MCP message must be a JSON object.") }
                    if object["method"] != nil, let key = try requestKey(object["id"]) {
                        while pending.count >= 32 { try await waitForChange() }
                        guard pending.insert(key).inserted else {
                            throw MCPError.invalidRequest(
                                "An MCP request identifier is already active.")
                        }
                    }
                    switch continuation.yield(message) {
                    case .enqueued: break
                    case .dropped: throw MCPError.internalError("The MCP message queue is full.")
                    case .terminated: return
                    @unknown default: return
                    }
                }
                guard buffer.count <= 4 * 1_024 * 1_024 else {
                    throw MCPError.invalidRequest("The MCP message exceeds 4 MiB.")
                }
            }
        } catch { continuation.finish(throwing: error) }
    }

    private func waitForChange() async throws {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<Void, Error>) in
                guard connected, !Task.isCancelled, waiter == nil else {
                    continuation.resume(throwing: CancellationError()); return
                }
                waiter = continuation
            }
        } onCancel: {
            Task { await self.cancelWaiter() }
        }
    }

    private func cancelWaiter() {
        let current = waiter
        waiter = nil
        current?.resume(throwing: CancellationError())
    }

    private func requestKey(_ value: Any?) throws -> String? {
        guard let value else { return nil }
        if let value = value as? String, value.utf8.count <= 256 {
            return "string:" + value
        }
        if let value = value as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.isFinite,
            value == NSNumber(value: value.int64Value)
        {
            return "number:" + value.stringValue
        }
        throw MCPError.invalidRequest("The MCP request identifier is invalid.")
    }
}
