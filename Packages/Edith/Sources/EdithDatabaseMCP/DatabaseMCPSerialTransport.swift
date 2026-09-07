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

    public init(base: any Transport, logger: Logger) {
        self.base = base
        self.logger = logger
        var continuation: AsyncThrowingStream<Data, Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    public func connect() async throws {
        try await base.connect()
        let base = base
        let continuation = continuation
        receiveTask = Task {
            do {
                for try await message in await base.receive() {
                    continuation.yield(message)
                }
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }
    }

    public func disconnect() async {
        receiveTask?.cancel()
        receiveTask = nil
        await base.disconnect()
        continuation.finish()
    }

    public func send(_ data: Data) async throws {
        let previous = sendTail
        let base = base
        let next = Task {
            if let previous {
                try await previous.value
            }
            try await base.send(data)
        }
        sendTail = next
        try await next.value
    }

    public func receive() -> AsyncThrowingStream<Data, Error> {
        stream
    }
}
