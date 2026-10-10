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

public actor HostCLIStream {
    private let handle: HostCLIStreamHandle
    private let operation: String
    private let invoke: HostCLIProviderRegistry.Invoke
    private var sequence: UInt64 = 0
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
