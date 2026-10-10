import EdithExtensionSupport
import Foundation

public struct HostCLIInvocationContext: Codable, Sendable {
    public static let maximumInputBytes = 4 * 1024 * 1024
    public let arguments: [String]
    public let standardInput: Data
    public let workingDirectory: String
    public let interactive: Bool

    public init(
        arguments: [String], standardInput: Data = Data(),
        workingDirectory: String = FileManager.default.currentDirectoryPath,
        interactive: Bool = false
    ) throws {
        _ = try ExtensionCLIRequest(arguments: arguments)
        guard standardInput.count <= Self.maximumInputBytes, workingDirectory.hasPrefix("/"),
            workingDirectory.utf8.count <= 4096, !workingDirectory.utf8.contains(0)
        else { throw HostCLIError.usage("Invalid command input or working directory.") }
        self.arguments = arguments; self.standardInput = standardInput;
        self.workingDirectory = workingDirectory; self.interactive = interactive
    }
}

public struct HostCLIStreamHandle: Codable, Sendable, Equatable {
    public let owner: String
    public let session: UUID
    public let token: UUID
}

public struct HostCLIStreamFrame: Codable, Sendable {
    public struct Chunk: Codable, Sendable {
        public enum Channel: String, Codable, Sendable { case stdout, stderr }
        public let sequence: UInt64
        public let channel: Channel
        public let data: Data
    }
    public enum State: String, Codable, Sendable {
        case running, completed, cancelled, timedOut, overflow, failed
    }
    public let handle: HostCLIStreamHandle
    public let sequence: UInt64
    public let nextSequence: UInt64
    public let chunks: [Chunk]
    public let state: State
    public let exitCode: Int32?

    public func validate(handle expected: HostCLIStreamHandle, sequence expectedSequence: UInt64)
        throws
    {
        guard handle == expected, sequence == expectedSequence, chunks.count <= 64,
            chunks.reduce(0, { $0 + $1.data.count }) <= 256 * 1024,
            nextSequence >= sequence, nextSequence - sequence == UInt64(chunks.count),
            chunks.enumerated().allSatisfy({ index, chunk in
                chunk.sequence == sequence + UInt64(index) && !chunk.data.isEmpty
                    && chunk.data.count <= 65536
            }),
            exitCode.map({ (0...255).contains($0) }) ?? true,
            (state == .completed) == (exitCode != nil)
        else { throw HostCLIError.rejected("Invalid or stale stream frame.") }
    }
}

public enum HostCLIInputEvent: Sendable, Equatable {
    case bytes(Data)
    case resize(columns: Int, rows: Int)
}

public struct HostCLILiveInput: Sendable {
    public let interactive: Bool
    public let receive: @Sendable () async throws -> HostCLIInputEvent?
    public let cancel: @Sendable () -> Void

    public init(
        interactive: Bool, receive: @escaping @Sendable () async throws -> HostCLIInputEvent?,
        cancel: @escaping @Sendable () -> Void
    ) {
        self.interactive = interactive; self.receive = receive; self.cancel = cancel
    }
}

public struct HostCLIStreamInputAck: Codable, Sendable {
    public let handle: HostCLIStreamHandle
    public let sequence: UInt64
    public let nextSequence: UInt64
    public let accepted: Bool
}

public actor HostCLIStream {
    private let handle: HostCLIStreamHandle
    private let operation: String
    private let invoke: HostCLIProviderRegistry.Invoke
    private var sequence: UInt64 = 0
    private var inputSequence: UInt64 = 0
    private var sendingInput = false
    private var inputEnded = false
    private var ended = false
    private var reading = false
    private let deadline: ContinuousClock.Instant

    public static func start(
        owner: String, operation: String, request: HostCLIInvocationContext,
        maximumDuration: Double = 1800, invoke: @escaping HostCLIProviderRegistry.Invoke
    ) async throws -> HostCLIStream {
        guard maximumDuration.isFinite, (1...21600).contains(maximumDuration) else {
            throw HostCLIError.usage("Invalid stream duration.")
        }
        let session = UUID()
        let payload = try HostCLIJSON.object([
            "owner": .string(owner), "session": .string(session.uuidString),
            "request": JSONDecoder().decode(HostCLIJSON.self, from: JSONEncoder().encode(request)),
            "deadline": .number(maximumDuration),
        ]).encoded()
        let response = try await invoke(
            HostCLIRequest(
                action: .invoke, id: owner, operation: operation + ".start", payload: payload))
        guard response.count <= 65536 else {
            throw HostCLIError.rejected("Invalid stream session.")
        }
        let handle = try JSONDecoder().decode(HostCLIStreamHandle.self, from: response)
        guard handle.owner == owner, handle.session == session else {
            throw HostCLIError.rejected("The stream belongs to another session.")
        }
        let stream = HostCLIStream(
            handle: handle, operation: operation, maximumDuration: maximumDuration, invoke: invoke)
        if Task.isCancelled { await stream.end(cancel: true); throw CancellationError() }
        return stream
    }

    private init(
        handle: HostCLIStreamHandle, operation: String, maximumDuration: Double,
        invoke: @escaping HostCLIProviderRegistry.Invoke
    ) {
        self.handle = handle; self.operation = operation; self.invoke = invoke
        deadline = ContinuousClock.now.advanced(by: .seconds(maximumDuration))
    }

    public func read() async throws -> HostCLIStreamFrame {
        guard !ended, !reading, ContinuousClock.now < deadline else {
            await end(cancel: true); throw HostCLIError.timedOut
        }
        reading = true
        defer { reading = false }
        do {
            let payload = try HostCLIJSON.object([
                "handle": JSONDecoder().decode(
                    HostCLIJSON.self, from: JSONEncoder().encode(handle)),
                "sequence": .integer(Int64(sequence)),
            ]).encoded()
            let response = try await withTaskCancellationHandler {
                try await invoke(
                    HostCLIRequest(
                        action: .invoke, id: handle.owner, operation: operation + ".read",
                        payload: payload, timeout: 15))
            } onCancel: {
                Task { await self.end(cancel: true) }
            }
            guard response.count <= HostCLIRequest.maximumPayload else {
                throw HostCLIError.rejected("Stream frame exceeds its limit.")
            }
            let frame = try JSONDecoder().decode(HostCLIStreamFrame.self, from: response)
            try frame.validate(handle: handle, sequence: sequence)
            try Task.checkCancellation()
            guard !ended, ContinuousClock.now < deadline else { throw HostCLIError.timedOut }
            sequence = frame.nextSequence
            if frame.state != .running { await end(cancel: frame.state != .completed) }
            return frame
        } catch { await end(cancel: true); throw error }
    }

    public func send(_ event: HostCLIInputEvent?) async throws {
        guard !ended, !inputEnded, !sendingInput, ContinuousClock.now < deadline else {
            throw HostCLIError.rejected("The stream input is closed or busy.")
        }
        sendingInput = true
        defer { sendingInput = false }
        var body: [String: HostCLIJSON] = [
            "handle": try JSONDecoder().decode(
                HostCLIJSON.self, from: JSONEncoder().encode(handle)),
            "sequence": .integer(Int64(inputSequence)),
        ]
        let action: String
        switch event {
        case .bytes(let data):
            guard !data.isEmpty, data.count <= 16384 else {
                throw HostCLIError.usage("Stream input must contain 1...16384 bytes.")
            }
            action = "write"; body["data"] = .string(data.base64EncodedString());
            body["end"] = .bool(false)
        case .resize(let columns, let rows):
            guard (1...1000).contains(columns), (1...1000).contains(rows) else {
                throw HostCLIError.usage("Invalid terminal dimensions.")
            }
            action = "resize"; body["columns"] = .integer(Int64(columns));
            body["rows"] = .integer(Int64(rows))
        case nil:
            action = "write"; body["data"] = .string(""); body["end"] = .bool(true)
        }
        let payload = try HostCLIJSON.object(body).encoded()
        let retryDeadline = min(deadline, ContinuousClock.now.advanced(by: .seconds(60)))
        while true {
            try Task.checkCancellation()
            guard !ended, ContinuousClock.now < retryDeadline else { throw HostCLIError.timedOut }
            let response = try await invoke(
                HostCLIRequest(
                    action: .invoke, id: handle.owner, operation: operation + "." + action,
                    payload: payload, timeout: 15))
            guard response.count <= 65536 else {
                throw HostCLIError.rejected("Invalid stream input acknowledgement.")
            }
            let ack = try JSONDecoder().decode(HostCLIStreamInputAck.self, from: response)
            guard ack.handle == handle, ack.sequence == inputSequence,
                ack.nextSequence == inputSequence + (ack.accepted ? 1 : 0)
            else { throw HostCLIError.rejected("Invalid or stale stream input acknowledgement.") }
            try Task.checkCancellation()
            guard !ended else { throw CancellationError() }
            if ack.accepted {
                inputSequence = ack.nextSequence
                if event == nil { inputEnded = true }
                return
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    public func consume(
        input: HostCLILiveInput?, write: @escaping @Sendable (Data, Bool) async throws -> Void
    ) async throws -> Int32 {
        guard let input else { return try await consume(write: write) }
        do {
            return try await withThrowingTaskGroup(of: Int32?.self) { group in
                group.addTask { try await self.consume(write: write) }
                group.addTask {
                    try await withTaskCancellationHandler {
                        do {
                            while let event = try await input.receive() {
                                try await self.send(event)
                            }
                            try await self.send(nil)
                        } catch {
                            if await self.ended { return }
                            throw error
                        }
                    } onCancel: {
                        input.cancel()
                    }
                    return nil
                }
                while let result = try await group.next() {
                    if let code = result {
                        group.cancelAll(); input.cancel()
                        return code
                    }
                }
                throw HostCLIError.rejected("The stream ended without an exit status.")
            }
        } catch {
            input.cancel(); await end(cancel: true); throw error
        }
    }

    public func consume(write: @Sendable (Data, Bool) async throws -> Void) async throws -> Int32 {
        do {
            while true {
                let frame = try await read()
                for chunk in frame.chunks {
                    try Task.checkCancellation();
                    try await write(chunk.data, chunk.channel == .stderr)
                }
                switch frame.state {
                case .running:
                    if frame.chunks.isEmpty { try await Task.sleep(for: .milliseconds(25)) }
                case .completed: return frame.exitCode!
                case .cancelled: throw CancellationError()
                case .timedOut: throw HostCLIError.timedOut
                case .overflow:
                    throw HostCLIError.rejected("The command exceeded its unread output limit.")
                case .failed: throw HostCLIError.rejected("The streamed command failed.")
                }
            }
        } catch { await end(cancel: true); throw error }
    }

    public func end(cancel: Bool = false) async {
        guard !ended else { return }
        ended = true
        let invoke = invoke, handle = handle, operation = operation
        let cleanup = Task.detached {
            guard let payload = try? JSONEncoder().encode(handle) else { return }
            for action in cancel ? ["cancel", "end"] : ["end"] {
                guard
                    let request = try? HostCLIRequest(
                        action: .invoke, id: handle.owner, operation: operation + "." + action,
                        payload: payload, timeout: 2)
                else { continue }
                _ = try? await invoke(request)
            }
        }
        await cleanup.value
    }
}
