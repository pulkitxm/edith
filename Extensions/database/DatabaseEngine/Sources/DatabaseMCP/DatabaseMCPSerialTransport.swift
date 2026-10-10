import Foundation
import Logging
import MCP

public actor DatabaseMCPSerialTransport: Transport {
    private let base: any Transport
    public nonisolated let logger: Logger
    private let stream: AsyncThrowingStream<Data, Error>
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    private var receiveTask: Task<Void, Never>?
    private var sendTail: Task<Void, Error>?
    private var writes: [UUID: Task<Void, Error>] = [:]
    private var connected = false
    private var stopping = false
    private var terminalError: Error?

    public init(base: any Transport, logger: Logger) {
        self.base = base
        self.logger = logger
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream(bufferingPolicy: .bufferingOldest(32)) { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        guard !stopping, !connected else {
            throw MCPError.internalError("The transport is closed.")
        }
        try await base.connect()
        connected = true
        let base = base
        let continuation = continuation
        receiveTask = Task {
            do {
                for try await message in await base.receive() {
                    switch continuation.yield(message) {
                    case .enqueued: break
                    case .dropped:
                        let error = MCPError.internalError("The input queue is full.")
                        terminalError = error
                        continuation.finish(throwing: error)
                        await base.disconnect()
                        return
                    case .terminated: return
                    @unknown default: return
                    }
                }
                continuation.finish()
            } catch {
                if !Task.isCancelled { terminalError = error }
                continuation.finish(throwing: error)
            }
        }
    }

    public func disconnect() async {
        stopping = true
        connected = false
        let receive = receiveTask
        receive?.cancel()
        receiveTask = nil
        let pending = Array(writes.values)
        for task in pending { task.cancel() }
        await base.disconnect()
        continuation.finish()
        await receive?.value
        for task in pending { _ = await task.result }
        sendTail = nil
    }

    public func send(_ data: Data) async throws {
        guard connected, !stopping, writes.count < 32, data.count <= 1_048_576 else {
            throw MCPError.internalError("The output queue is unavailable.")
        }
        try Task.checkCancellation()
        let previous = sendTail
        let base = base
        let id = UUID()
        let next = Task {
            if let previous {
                try await previous.value
            }
            try Task.checkCancellation()
            try await base.send(data)
        }
        writes[id] = next
        defer { writes.removeValue(forKey: id) }
        sendTail = next
        try await withTaskCancellationHandler {
            try await next.value
        } onCancel: {
            next.cancel()
        }
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }

    public func checkCompletion() throws {
        if let terminalError { throw terminalError }
    }
}
