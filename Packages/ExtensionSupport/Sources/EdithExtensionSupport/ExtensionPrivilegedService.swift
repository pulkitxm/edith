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

@MainActor public final class ExtensionPrivilegedClient {
    public let owner: String
    private let source: URL
    private let version: String
    private var connection: NSXPCConnection?
    private var proxy: ExtensionPrivilegedProtocol?

    public init(owner: String, source: URL, version: String) {
        self.owner = owner; self.source = source; self.version = version
    }

    public var status: SMAppService.Status { ExtensionPrivilegedService.service.status }

    public func requestApproval() throws {
        let service = ExtensionPrivilegedService.service
        if service.status == .notRegistered { try service.register() }
        if service.status == .requiresApproval { SMAppService.openSystemSettingsLoginItems() }
    }

    public func invoke(_ command: String, payload: Data) async throws -> Data {
        guard !command.isEmpty, command.utf8.count <= 256, !command.utf8.contains(0),
            payload.count <= 65_536
        else { throw ExtensionPeerError.invalidRequest }
        try await activate()
        guard let proxy else { throw ExtensionPeerError.unavailable }
        return try await call { completion in
            proxy.invoke(command, payload: payload, reply: completion)
        }
    }

    public func release() async throws {
        guard let proxy else { return }
        _ = try await call { completion in proxy.release { completion(Data(), $0) } }
        connection?.invalidate(); connection = nil; self.proxy = nil
    }

    public func shutdown() { connection?.invalidate(); connection = nil; proxy = nil }

    private func activate() async throws {
        if proxy != nil { return }
        guard status == .enabled else {
            throw ExtensionPeerError.rejected(
                "Approve Edith in System Settings > General > Login Items & Extensions, then try again."
            )
        }
        let connection = NSXPCConnection(
            machServiceName: ExtensionPrivilegedService.identifier, options: .privileged)
        connection.remoteObjectInterface = NSXPCInterface(with: ExtensionPrivilegedProtocol.self)
        connection.resume()
        self.connection = connection
        guard
            let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in connection.invalidate()
            }) as? ExtensionPrivilegedProtocol
        else { shutdown(); throw ExtensionPeerError.unavailable }
        self.proxy = proxy
        do {
            _ = try await call { completion in
                proxy.activate(source.path, owner: owner, version: version) {
                    completion(Data(), $0)
                }
            }
        } catch { shutdown(); throw error }
    }

    private func call(_ send: (@escaping @Sendable (Data?, NSError?) -> Void) -> Void) async throws
        -> Data
    {
        let reply = ExtensionPrivilegedReply()
        let connection = self.connection
        let timeout = Task {
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            if reply.finish(.failure(ExtensionPeerError.timedOut)) { connection?.invalidate() }
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.begin(continuation) else { return }
                send { data, error in
                    if let error {
                        reply.finish(.failure(error))
                    } else if let data, data.count <= 65_536 {
                        reply.finish(.success(data))
                    } else {
                        reply.finish(.failure(ExtensionPeerError.invalidRequest))
                    }
                }
            }
        } onCancel: {
            if reply.finish(.failure(CancellationError())) { connection?.invalidate() }
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
