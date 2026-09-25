import Foundation

public struct HerdrScrollInfo: Equatable, Sendable {
    public var offset: Int
    public var maximum: Int
    public var viewportRows: Int

    public init(offset: Int, maximum: Int, viewportRows: Int) {
        self.offset = offset
        self.maximum = maximum
        self.viewportRows = viewportRows
    }

    public var scrollable: Bool { maximum > 0 && viewportRows > 0 }

    public func clamped(_ offset: Int) -> Int {
        min(maximum, max(0, offset))
    }
}

public final class HerdrPaneScrollChannel: @unchecked Sendable {
    public let pane: String
    private let connect: @Sendable () throws -> HerdrSocketClient
    private let lock = NSLock()
    private var clients: [ObjectIdentifier: HerdrSocketClient] = [:]
    private var closed = false

    init(pane: String, connect: @escaping @Sendable () throws -> HerdrSocketClient) {
        self.pane = pane
        self.connect = connect
    }

    deinit { close() }

    public static func open(
        session: String, pane: String, machine: Machine?
    ) async throws -> HerdrPaneScrollChannel {
        guard let machine else {
            guard let socket = HerdrSocketDiscovery.local().first(where: { $0.name == session })
            else { throw HerdrSocketError(message: "no herdr server for \(session)") }
            return HerdrPaneScrollChannel(
                pane: pane, connect: { try HerdrSocketClient.unix(path: socket.path) })
        }
        let connection = SSHConnection(machine: machine, controlSocketMode: .shared)
        try await connection.connect()
        guard await connection.remotePlatform != .windows else {
            throw HerdrSocketError(message: "herdr sockets are not reachable on Windows")
        }
        let listing = try await connection.run(
            HerdrSocketDiscovery.remoteProbeCommand(), timeout: 12)
        guard
            let socket = HerdrSocketDiscovery.sockets(fromRemoteListing: listing.stdoutText)
                .first(where: { $0.name == session })
        else { throw HerdrSocketError(message: "no herdr server for \(session)") }
        return HerdrPaneScrollChannel(
            pane: pane,
            connect: { try HerdrSocketClient.ssh(connection, socketPath: socket.path) })
    }

    public func updates() -> AsyncThrowingStream<HerdrScrollInfo, Error> {
        let pane = pane
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    let current = try await self.request(
                        method: "pane.get", params: ["pane_id": pane])
                    if let info = HerdrListParser.scrollInfo(from: current, pane: pane) {
                        continuation.yield(info)
                    }
                    let client = try self.open()
                    defer { self.release(client) }
                    let events = client.events
                    try await client.subscribe([["type": "pane.scroll_changed", "pane_id": pane]])
                    for await line in events {
                        guard !Task.isCancelled else { break }
                        if let info = HerdrListParser.scrollInfo(from: line, pane: pane) {
                            continuation.yield(info)
                        }
                    }
                    continuation.finish(
                        throwing: Task.isCancelled
                            ? nil : HerdrSocketError(message: "herdr scroll events ended"))
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    @discardableResult
    public func scroll(to offset: Int) async throws -> HerdrScrollInfo? {
        let reply = try await request(
            method: "pane.scroll", params: ["pane_id": pane, "offset_from_bottom": max(0, offset)])
        return HerdrListParser.scrollInfo(from: reply, pane: pane)
    }

    public func close() {
        lock.lock()
        closed = true
        let open = Array(clients.values)
        clients = [:]
        lock.unlock()
        for client in open { client.close() }
    }

    private func request(method: String, params: [String: Any]) async throws -> String {
        let client = try open()
        defer { release(client) }
        return try await client.call(method: method, params: params)
    }

    private func open() throws -> HerdrSocketClient {
        let client = try connect()
        lock.lock()
        let isClosed = closed
        if !isClosed { clients[ObjectIdentifier(client)] = client }
        lock.unlock()
        guard !isClosed else {
            client.close()
            throw HerdrSocketError(message: "herdr scroll channel closed")
        }
        return client
    }

    private func release(_ client: HerdrSocketClient) {
        lock.lock()
        clients[ObjectIdentifier(client)] = nil
        lock.unlock()
        client.close()
    }
}
