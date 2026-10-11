import Foundation

final class CompanionTransport: @unchecked Sendable {
    static let shared = CompanionTransport()

    let producers = CompanionTransportTaskOwner()
    private let lock = NSLock()
    private var current: URLSession?
    private var currentRetirement: CompanionSessionRetirement?
    private var retiring: CompanionSessionRetirement?
    private var closed = false
    private var remote: CompanionUIBridge?
    private var remoteOnly = false
    func configureRemote(_ value: CompanionUIBridge?) {
        lock.withLock {
            remote = value; remoteOnly = true; closed = value == nil
        }
    }
    var remoteBridge: CompanionUIBridge? { lock.withLock { remote } }

    var session: URLSession {
        get throws {
            try lock.withLock {
                guard !closed, !remoteOnly else { throw CancellationError() }
                if let current { return current }
                let configuration = URLSessionConfiguration.ephemeral
                configuration.httpCookieStorage = nil
                configuration.urlCredentialStorage = nil
                configuration.urlCache = nil
                configuration.httpMaximumConnectionsPerHost = 6
                let retirement = CompanionSessionRetirement()
                let session = URLSession(
                    configuration: configuration, delegate: retirement, delegateQueue: nil)
                currentRetirement = retirement
                current = session
                return session
            }
        }
    }

    var isClosed: Bool { lock.withLock { closed } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await producers.perform { [self] in try await dataWork(for: request) }
    }

    private func dataWork(for request: URLRequest) async throws -> (Data, URLResponse) {
        let state = lock.withLock { (closed, remoteOnly, remote) }
        guard !state.0 else { throw CancellationError() }
        if let remote = state.2 { return try await remote.http(request) }
        guard !state.1 else { throw CancellationError() }
        return try await session.data(for: request)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await producers.perform { [self] in try await session.bytes(for: request) }
    }

    func open() { lock.withLock { if retiring == nil { closed = false } } }

    func close() {
        producers.cancel()
        let session = lock.withLock { () -> URLSession? in
            closed = true
            if let currentRetirement { retiring = currentRetirement }
            currentRetirement = nil
            defer { current = nil }
            return current
        }
        session?.invalidateAndCancel()
    }

    func closeAndWait() async {
        close()
        let active = lock.withLock { retiring }
        await active?.wait()
        await producers.drain()
        lock.withLock { if retiring === active { retiring = nil } }
    }
}

private final class CompanionSessionRetirement: NSObject, URLSessionDelegate, @unchecked Sendable {
    private let finished: AsyncStream<Void>.Continuation
    private let returned: Task<Void, Never>

    override init() {
        let response = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        finished = response.continuation
        returned = Task { for await _ in response.stream {} }
        super.init()
    }

    func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
        finished.finish()
    }

    func wait() async { await returned.value }
}

final class CompanionTransportTaskOwner: @unchecked Sendable {
    private struct Entry {
        let join: Task<Void, Never>
        let cancel: @Sendable () -> Void
    }
    private let lock = NSLock()
    private var tasks: [UUID: Entry] = [:]
    private var closed = false

    func launch(_ work: @escaping @Sendable () async -> Void) -> Task<Void, Never>? {
        lock.withLock {
            guard !closed, tasks.count < 256 else { return nil }
            let id = UUID()
            let task = Task { await work() }
            let joined = Task {
                await task.value
                self.lock.withLock { self.tasks[id] = nil }
            }
            tasks[id] = Entry(join: joined, cancel: { task.cancel() })
            return task
        }
    }

    func perform<Value: Sendable>(
        _ work: @escaping @Sendable () async throws -> Value
    ) async throws -> Value {
        let task: Task<Value, Error> = try lock.withLock {
            guard !closed, tasks.count < 256 else { throw CancellationError() }
            let id = UUID()
            let task = Task { try await work() }
            let joined = Task {
                _ = await task.result
                self.lock.withLock { self.tasks[id] = nil }
            }
            tasks[id] = Entry(join: joined, cancel: { task.cancel() })
            return task
        }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func cancel() {
        let active = lock.withLock { () -> [Entry] in
            closed = true
            return Array(tasks.values)
        }
        for entry in active { entry.cancel() }
    }

    func drain() async {
        cancel()
        while let entry = lock.withLock({ tasks.values.first }) { await entry.join.value }
    }
}
