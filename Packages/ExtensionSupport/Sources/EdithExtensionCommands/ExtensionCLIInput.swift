import EdithExtensionSupport
import Foundation

public struct ExtensionCLIStreamWrite: Codable, Sendable {
    public let handle: ExtensionCLIStreamHandle
    public let sequence: UInt64
    public let data: Data
    public let end: Bool

    public init(handle: ExtensionCLIStreamHandle, sequence: UInt64, data: Data, end: Bool = false) {
        self.handle = handle
        self.sequence = sequence
        self.data = data
        self.end = end
    }

    public func validate() throws {
        guard data.count <= ExtensionCLIInput.maximumWriteBytes, !data.isEmpty || end else {
            throw ExtensionPeerError.invalidRequest
        }
    }
}

public struct ExtensionCLIStreamResize: Codable, Sendable {
    public let handle: ExtensionCLIStreamHandle
    public let sequence: UInt64
    public let columns: Int
    public let rows: Int

    public init(handle: ExtensionCLIStreamHandle, sequence: UInt64, columns: Int, rows: Int) {
        self.handle = handle
        self.sequence = sequence
        self.columns = columns
        self.rows = rows
    }

    public func validate() throws {
        guard (1...1_000).contains(columns), (1...1_000).contains(rows) else {
            throw ExtensionPeerError.invalidRequest
        }
    }
}

public struct ExtensionCLIStreamInputAck: Codable, Sendable {
    public let handle: ExtensionCLIStreamHandle
    public let sequence: UInt64
    public let nextSequence: UInt64
    public let accepted: Bool

    public init(
        handle: ExtensionCLIStreamHandle, sequence: UInt64, nextSequence: UInt64, accepted: Bool
    ) {
        self.handle = handle
        self.sequence = sequence
        self.nextSequence = nextSequence
        self.accepted = accepted
    }

    public func validate() throws {
        guard sequence < UInt64.max, nextSequence == sequence + (accepted ? 1 : 0) else {
            throw ExtensionPeerError.invalidRequest
        }
    }
}

public final class ExtensionCLIInput: @unchecked Sendable {
    public enum Event: Equatable, Sendable {
        case bytes(Data)
        case resize(columns: Int, rows: Int)
    }

    public static let maximumWriteBytes = 16 * 1_024
    public static let maximumQueuedBytes = 256 * 1_024
    public static let maximumQueuedEvents = 64
    private let lock = NSLock()
    private var initial: Data
    private var initialOffset = 0
    private var events: [Event] = []
    private var byteCount = 0
    private var sequence: UInt64 = 0
    private var eof = false
    private var closed = false
    private var waiting: (UUID, CheckedContinuation<Event?, Error>)?

    init(initial: Data) {
        self.initial = initial
    }

    public func read() async throws -> Event? {
        try Task.checkCancellation()
        let id = UUID()
        let event = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result: Result<Event?, Error>? = lock.withLock {
                    if Task.isCancelled || closed { return .failure(CancellationError()) }
                    if initialOffset < initial.count {
                        let end = min(initialOffset + Self.maximumWriteBytes, initial.count)
                        let bytes = initial.subdata(in: initialOffset..<end)
                        initialOffset = end
                        if initialOffset == initial.count { initial = Data(); initialOffset = 0 }
                        return .success(.bytes(bytes))
                    }
                    if !events.isEmpty { return .success(removeFirst()) }
                    if eof { return .success(nil) }
                    guard waiting == nil else {
                        return .failure(
                            ExtensionPeerError.rejected("The terminal input already has a reader."))
                    }
                    waiting = (id, continuation)
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.cancelRead(id)
        }
        try Task.checkCancellation()
        return event
    }

    func write(_ request: ExtensionCLIStreamWrite) throws -> ExtensionCLIStreamInputAck {
        try request.validate()
        return try enqueue(
            request.data.isEmpty ? nil : .bytes(request.data), end: request.end,
            handle: request.handle, sequence: request.sequence)
    }

    func resize(_ request: ExtensionCLIStreamResize) throws -> ExtensionCLIStreamInputAck {
        try request.validate()
        return try enqueue(
            .resize(columns: request.columns, rows: request.rows), end: false,
            handle: request.handle, sequence: request.sequence)
    }

    func close() {
        let continuation = lock.withLock {
            closed = true
            initial = Data()
            initialOffset = 0
            events.removeAll()
            byteCount = 0
            let continuation = waiting?.1
            waiting = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }

    private func enqueue(
        _ event: Event?, end: Bool, handle: ExtensionCLIStreamHandle, sequence: UInt64
    ) throws -> ExtensionCLIStreamInputAck {
        var continuation: CheckedContinuation<Event?, Error>?
        var delivered: Event?
        let ack = try lock.withLock {
            guard !closed, !eof else {
                throw ExtensionPeerError.rejected("The terminal input is closed.")
            }
            guard sequence == self.sequence, sequence < UInt64.max else {
                throw ExtensionPeerError.invalidRequest
            }
            let bytes =
                event.map {
                    if case .bytes(let data) = $0 { return data.count }; return 0
                } ?? 0
            if event != nil,
                (events.count >= Self.maximumQueuedEvents
                    || bytes > Self.maximumQueuedBytes - byteCount)
            {
                return ExtensionCLIStreamInputAck(
                    handle: handle, sequence: sequence, nextSequence: sequence, accepted: false)
            }
            if let event { events.append(event); byteCount += bytes }
            eof = end
            self.sequence += 1
            if let reader = waiting {
                continuation = reader.1
                waiting = nil
                delivered = events.isEmpty ? nil : removeFirst()
            }
            return ExtensionCLIStreamInputAck(
                handle: handle, sequence: sequence, nextSequence: self.sequence, accepted: true)
        }
        continuation?.resume(returning: delivered)
        return ack
    }

    private func removeFirst() -> Event {
        let event = events.removeFirst()
        if case .bytes(let bytes) = event { byteCount -= bytes.count }
        return event
    }

    private func cancelRead(_ id: UUID) {
        let continuation = lock.withLock {
            guard waiting?.0 == id else { return nil as CheckedContinuation<Event?, Error>? }
            let continuation = waiting?.1
            waiting = nil
            return continuation
        }
        continuation?.resume(throwing: CancellationError())
    }
}
