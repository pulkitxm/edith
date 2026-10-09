import Foundation
import ServiceManagement

@objc public protocol ExtensionPrivilegedProtocol {
    func activate(
        _ source: String, owner: String, version: String,
        reply: @escaping @Sendable (NSError?) -> Void)
    func invoke(
        _ command: String, payload: Data, reply: @escaping @Sendable (Data?, NSError?) -> Void)
    func release(reply: @escaping @Sendable (NSError?) -> Void)
}

public enum ExtensionPrivilegedService {
    public static let identifier = "com.pulkit.edith.extensions.carrier.v1"
    public static let plistName = identifier + ".plist"
    public static var service: SMAppService { .daemon(plistName: plistName) }
}

@MainActor protocol ExtensionPrivilegedTransport: AnyObject {
    func activate(source: URL, owner: String, version: String) async throws
    func invoke(_ command: String, payload: Data) async throws -> Data
    func release() async throws
    func invalidate()
}

@MainActor public final class ExtensionPrivilegedClient {
    public let owner: String
    private let source: URL
    private let version: String
    private let serviceStatus: @MainActor () -> SMAppService.Status
    private let connect:
        @MainActor (@escaping @MainActor () -> Void) -> any ExtensionPrivilegedTransport
    private var channel: (any ExtensionPrivilegedTransport)?
    private var channelID: UUID?
    private var needsRestoration = false
    private var requesting = false

    public convenience init(owner: String, source: URL, version: String) {
        self.init(
            owner: owner, source: source, version: version,
            status: { ExtensionPrivilegedService.service.status },
            connect: { ExtensionPrivilegedXPC(invalidated: $0) })
    }

    init(
        owner: String, source: URL, version: String,
        status: @escaping @MainActor () -> SMAppService.Status,
        connect:
            @escaping @MainActor (@escaping @MainActor () -> Void) ->
            any ExtensionPrivilegedTransport
    ) {
        self.owner = owner; self.source = source; self.version = version
        serviceStatus = status; self.connect = connect
    }

    public var status: SMAppService.Status { serviceStatus() }

    public func requestApproval() throws {
        let service = ExtensionPrivilegedService.service
        if service.status == .notRegistered { try service.register() }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    public func invoke(_ command: String, payload: Data) async throws -> Data {
        guard !requesting, !command.isEmpty, command.utf8.count <= 256,
            !command.utf8.contains(0), payload.count <= 32_768
        else { throw ExtensionPeerError.invalidRequest }
        requesting = true; defer { requesting = false }
        let channel = try await activate()
        return try await channel.invoke(command, payload: payload)
    }

    public func release() async throws {
        guard needsRestoration || channel != nil else { return }
        guard !requesting else { throw ExtensionPeerError.invalidRequest }
        requesting = true; defer { requesting = false }
        let channel = try await activate()
        try await channel.release()
        needsRestoration = false
        shutdown()
    }

    public func shutdown() {
        let previous = channel; channel = nil; channelID = nil; previous?.invalidate()
    }

    private func activate() async throws -> any ExtensionPrivilegedTransport {
        if let channel { return channel }
        guard status == .enabled else {
            throw ExtensionPeerError.rejected(
                "Approve Edith in System Settings > General > Login Items & Extensions, then try again."
            )
        }
        let id = UUID()
        let created = connect { [weak self] in
            guard self?.channelID == id else { return }
            self?.channel = nil; self?.channelID = nil
        }
        channelID = id; channel = created
        do {
            try await created.activate(source: source, owner: owner, version: version)
            guard channelID == id else { throw ExtensionPeerError.unavailable }
            needsRestoration = true
            return created
        } catch {
            if channelID == id { shutdown() } else { created.invalidate() }
            throw error
        }
    }
}

@MainActor private final class ExtensionPrivilegedXPC: ExtensionPrivilegedTransport {
    private let connection = NSXPCConnection(
        machServiceName: ExtensionPrivilegedService.identifier, options: .privileged)
    private let invalidated: @MainActor () -> Void
    private var proxy: ExtensionPrivilegedProtocol?
    private var pending: [UUID: ExtensionPrivilegedReply] = [:]
    private var closed = false

    init(invalidated: @escaping @MainActor () -> Void) {
        self.invalidated = invalidated
        connection.remoteObjectInterface = NSXPCInterface(with: ExtensionPrivilegedProtocol.self)
        connection.invalidationHandler = { [weak self] in
            Task { @MainActor in self?.invalidate() }
        }
        connection.interruptionHandler = connection.invalidationHandler
        connection.resume()
        proxy =
            connection.remoteObjectProxyWithErrorHandler { [weak self] _ in
                Task { @MainActor in self?.invalidate() }
            } as? ExtensionPrivilegedProtocol
    }

    func activate(source: URL, owner: String, version: String) async throws {
        guard let proxy else { throw ExtensionPeerError.unavailable }
        _ = try await call { completion in
            proxy.activate(source.path, owner: owner, version: version) { completion(Data(), $0) }
        }
    }
    func invoke(_ command: String, payload: Data) async throws -> Data {
        guard let proxy else { throw ExtensionPeerError.unavailable }
        return try await call { completion in
            proxy.invoke(command, payload: payload, reply: completion)
        }
    }
    func release() async throws {
        guard let proxy else { throw ExtensionPeerError.unavailable }
        _ = try await call { completion in proxy.release { completion(Data(), $0) } }
    }
    func invalidate() {
        guard !closed else { return }; closed = true
        connection.invalidate(); proxy = nil
        for reply in pending.values { reply.finish(.failure(ExtensionPeerError.unavailable)) }
        pending.removeAll(); invalidated()
    }

    private func call(_ send: (@escaping @Sendable (Data?, NSError?) -> Void) -> Void) async throws
        -> Data
    {
        guard !closed else { throw ExtensionPeerError.unavailable }
        let reply = ExtensionPrivilegedReply()
        let id = UUID(); pending[id] = reply
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            if reply.finish(.failure(ExtensionPeerError.timedOut)) { invalidate() }
        }
        defer { timeout.cancel(); pending[id] = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.begin(continuation) else { return }
                send { data, error in
                    if let error {
                        reply.finish(.failure(error))
                    } else if let data, data.count <= 32_768 {
                        reply.finish(.success(data))
                    } else {
                        reply.finish(.failure(ExtensionPeerError.invalidRequest))
                    }
                }
            }
        } onCancel: {
            if reply.finish(.failure(CancellationError())) {
                Task { @MainActor [weak self] in self?.invalidate() }
            }
        }
    }
}

private final class ExtensionPrivilegedReply: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, Error>?
    private var result: Result<Data, Error>?
    func begin(_ next: CheckedContinuation<Data, Error>) -> Bool {
        lock.lock()
        if let result { lock.unlock(); next.resume(with: result); return false }
        continuation = next; lock.unlock(); return true
    }
    @discardableResult func finish(_ value: Result<Data, Error>) -> Bool {
        lock.lock()
        guard result == nil else { lock.unlock(); return false }
        result = value; let next = continuation; continuation = nil; lock.unlock()
        next?.resume(with: value); return true
    }
}
