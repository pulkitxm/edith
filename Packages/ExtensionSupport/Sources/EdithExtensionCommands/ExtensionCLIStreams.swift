import ArgumentParser
import EdithExtensionSupport
import Foundation

@MainActor public final class ExtensionCLIStreams {
    nonisolated public static let maximumSessions = 8
    nonisolated public static let maximumBufferedBytes = 1_024 * 1_024
    private struct Session {
        let handle: ExtensionCLIStreamHandle
        let buffer: CLIStreamBuffer
        let task: Task<Void, Never>
        let timer: Task<Void, Never>
        var lastRead: ContinuousClock.Instant
        var ended = false
    }
    public let owner: String
    private let idleTimeout: Duration
    private var sessions: [UUID: Session] = [:]
    private var stopping = false

    public init(owner: String, idleTimeout: Duration = .seconds(60)) throws {
        guard !owner.isEmpty, owner.utf8.count <= 128, !owner.utf8.contains(0),
            idleTimeout > .zero, idleTimeout <= .seconds(60)
        else { throw ExtensionPeerError.invalidRequest }
        self.owner = owner
        self.idleTimeout = idleTimeout
    }

    deinit {
        for session in sessions.values {
            session.buffer.discard()
            session.timer.cancel()
            session.task.cancel()
        }
    }

    public func start<Command: AsyncParsableCommand>(
        _ root: Command.Type, request: ExtensionCLIStreamStart
    ) throws -> ExtensionCLIStreamHandle {
        try request.validate()
        guard !stopping, request.owner == owner, sessions.count < Self.maximumSessions,
            !sessions.values.contains(where: { $0.handle.session == request.session })
        else { throw ExtensionPeerError.rejected("The terminal stream cannot start.") }
        let handle = ExtensionCLIStreamHandle(owner: owner, session: request.session, token: UUID())
        let buffer = CLIStreamBuffer()
        let task = Task { [weak self] in
            do {
                let code = try await ExtensionCLIExecution.run(
                    root, request: request.request,
                    rawSink: { data, error in buffer.append(data, error: error) })
                if (0...255).contains(code) {
                    buffer.finish(state: .completed, exitCode: code)
                } else {
                    buffer.finish(state: .failed, exitCode: nil)
                }
            } catch is CancellationError {
                buffer.finish(state: .cancelled, exitCode: nil)
            } catch {
                buffer.finish(state: .failed, exitCode: nil)
            }
            self?.finished(handle.token)
        }
        buffer.setCancellation { task.cancel() }
        let started = ContinuousClock.now
        let timer = Task { [weak self] in
            var deadlineReached = false
            while !Task.isCancelled {
                guard let current = self?.sessions[handle.token],
                    let idleTimeout = self?.idleTimeout
                else { return }
                let idleRemaining = max(.zero, idleTimeout - current.lastRead.duration(to: .now))
                let deadlineRemaining =
                    deadlineReached
                    ? idleRemaining
                    : max(.zero, .seconds(request.deadline) - started.duration(to: .now))
                do { try await Task.sleep(for: min(idleRemaining, deadlineRemaining)) } catch {
                    return
                }
                guard let self, let session = self.sessions[handle.token] else { return }
                if !deadlineReached, started.duration(to: .now) >= .seconds(request.deadline) {
                    deadlineReached = true
                    session.buffer.cancel(state: .timedOut)
                    session.task.cancel()
                }
                if session.lastRead.duration(to: .now) >= self.idleTimeout {
                    session.buffer.cancel(state: .timedOut)
                    session.task.cancel()
                    self.endRetainingTask(handle.token)
                    return
                }
            }
        }
        sessions[handle.token] = Session(
            handle: handle, buffer: buffer, task: task, timer: timer, lastRead: .now)
        return handle
    }

    public func read(_ request: ExtensionCLIStreamRead) throws -> ExtensionCLIStreamFrame {
        var session = try lookup(request.handle)
        let frame = try session.buffer.read(handle: session.handle, sequence: request.sequence)
        session.lastRead = .now
        sessions[request.handle.token] = session
        return frame
    }

    public func cancel(_ handle: ExtensionCLIStreamHandle) throws {
        let session = try lookup(handle)
        session.buffer.cancel(state: .cancelled)
        session.task.cancel()
    }

    public func end(_ handle: ExtensionCLIStreamHandle) throws {
        _ = try lookup(handle)
        endRetainingTask(handle.token)
    }

    public func stop() {
        stopping = true
        for token in Array(sessions.keys) { endRetainingTask(token) }
    }

    public func stopAndWait() async {
        let tasks = sessions.values.map(\.task)
        stop()
        for task in tasks { await task.value }
    }

    public func invoke<Command: AsyncParsableCommand>(
        _ root: Command.Type, operation: String, prefix: String, payload: Data
    ) throws -> Data {
        guard payload.count <= ExtensionCLIRequest.maximumInputBytes * 2 else {
            throw ExtensionPeerError.invalidRequest
        }
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        switch operation {
        case prefix + ".start":
            return try encoder.encode(
                start(root, request: decoder.decode(ExtensionCLIStreamStart.self, from: payload)))
        case prefix + ".read":
            return try encoder.encode(
                read(decoder.decode(ExtensionCLIStreamRead.self, from: payload)))
        case prefix + ".cancel":
            try cancel(decoder.decode(ExtensionCLIStreamHandle.self, from: payload))
        case prefix + ".end":
            try end(decoder.decode(ExtensionCLIStreamHandle.self, from: payload))
        default: throw ExtensionPeerError.invalidRequest
        }
        return Data("{}".utf8)
    }

    private func lookup(_ handle: ExtensionCLIStreamHandle) throws -> Session {
        guard handle.owner == owner, let session = sessions[handle.token],
            session.handle == handle, !session.ended, !stopping
        else { throw ExtensionPeerError.rejected("The terminal stream is unavailable.") }
        return session
    }

    private func endRetainingTask(_ token: UUID) {
        guard var session = sessions[token] else { return }
        session.ended = true
        session.buffer.discard()
        session.timer.cancel()
        session.task.cancel()
        if session.buffer.finished {
            sessions.removeValue(forKey: token)
        } else {
            sessions[token] = session
        }
    }

    private func finished(_ token: UUID) {
        guard let session = sessions[token] else { return }
        if session.ended { sessions.removeValue(forKey: token) }
    }
}

private final class CLIStreamBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var chunks: [ExtensionCLIStreamChunk] = []
    private var byteCount = 0
    private var nextSequence: UInt64 = 0
    private var readSequence: UInt64 = 0
    private var state: ExtensionCLIStreamFrame.State = .running
    private var exitCode: Int32?
    private var done = false
    private var discarded = false
    private var cancellation: (@Sendable () -> Void)?

    var finished: Bool { lock.withLock { done } }

    func setCancellation(_ cancellation: @escaping @Sendable () -> Void) {
        lock.withLock { self.cancellation = cancellation }
    }

    func append(_ data: Data, error: Bool) {
        let cancel = lock.withLock { () -> (@Sendable () -> Void)? in
            guard !discarded, state == .running, !data.isEmpty else { return nil }
            let count = data.count
            let requiredChunks = count / 65_536 + (count % 65_536 == 0 ? 0 : 1)
            guard count <= ExtensionCLIStreams.maximumBufferedBytes - byteCount,
                requiredChunks <= 4_096 - chunks.count,
                UInt64(requiredChunks) < UInt64.max - nextSequence
            else {
                state = .overflow
                return cancellation
            }
            for offset in stride(from: 0, to: data.count, by: 65_536) {
                let bytes = data.subdata(in: offset..<min(offset + 65_536, data.count))
                chunks.append(
                    ExtensionCLIStreamChunk(
                        sequence: nextSequence, channel: error ? .stderr : .stdout, data: bytes))
                nextSequence += 1
            }
            byteCount += count
            return nil
        }
        cancel?()
    }

    func finish(state: ExtensionCLIStreamFrame.State, exitCode: Int32?) {
        lock.withLock {
            done = true
            if self.state == .running { self.state = state; self.exitCode = exitCode }
        }
    }

    func cancel(state: ExtensionCLIStreamFrame.State) {
        lock.withLock { if self.state == .running { self.state = state } }
    }

    func discard() {
        lock.withLock {
            discarded = true; chunks.removeAll(); byteCount = 0
        }
    }

    func read(handle: ExtensionCLIStreamHandle, sequence: UInt64) throws -> ExtensionCLIStreamFrame
    {
        try lock.withLock {
            guard sequence == readSequence else { throw ExtensionPeerError.invalidRequest }
            var count = 0
            var bytes = 0
            for chunk in chunks.prefix(64) {
                guard bytes + chunk.data.count <= ExtensionCLIStreamFrame.maximumFrameBytes else {
                    break
                }
                count += 1
                bytes += chunk.data.count
            }
            let result = Array(chunks.prefix(count))
            chunks.removeFirst(count)
            byteCount -= bytes
            readSequence += UInt64(count)
            let drained = chunks.isEmpty && done
            let frame = ExtensionCLIStreamFrame(
                handle: handle, sequence: sequence, nextSequence: readSequence,
                chunks: result, state: drained ? state : .running,
                exitCode: drained ? exitCode : nil)
            try frame.validate()
            return frame
        }
    }
}
