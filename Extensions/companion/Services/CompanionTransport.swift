import Foundation

final class CompanionTransport: @unchecked Sendable {
    static let shared = CompanionTransport()

    private let lock = NSLock()
    private var current: URLSession?
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
                let session = URLSession(configuration: configuration)
                current = session
                return session
            }
        }
    }

    var isClosed: Bool { lock.withLock { closed } }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let state = lock.withLock { (closed, remoteOnly, remote) }
        guard !state.0 else { throw CancellationError() }
        if let remote = state.2 { return try await remote.http(request) }
        guard !state.1 else { throw CancellationError() }
        return try await session.data(for: request)
    }

    func bytes(for request: URLRequest) async throws -> (URLSession.AsyncBytes, URLResponse) {
        try await session.bytes(for: request)
    }

    func open() { lock.withLock { closed = false } }

    func close() {
        let session = lock.withLock { () -> URLSession? in
            closed = true
            defer { current = nil }
            return current
        }
        session?.invalidateAndCancel()
    }
}
