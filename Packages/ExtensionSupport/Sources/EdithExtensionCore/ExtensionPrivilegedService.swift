import Foundation
import ServiceManagement
import Security

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

public enum ExtensionPrivilegedError: Error, LocalizedError, Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case start
        case command(String)
        case release

        var request: String {
            switch self {
            case .start: "start the privileged part of the extension"
            case .command(let name): "run the \(name) request"
            case .release: "restore the system settings the extension changed"
            }
        }
    }

    case noAnswer(Step, seconds: Int)
    case closed(Step)
    case outdatedCarrier

    public var errorDescription: String? {
        switch self {
        case .noAnswer(let step, let seconds):
            "Edith's privileged helper did not answer within \(seconds) seconds when asked to \(step.request)."
        case .closed(let step):
            "Edith's privileged helper closed the connection when asked to \(step.request)."
        case .outdatedCarrier:
            "Edith's privileged helper is still running from before Edith was updated and cannot answer this version. Restart the Mac once, then try again."
        }
    }

    var leftTheStartUnanswered: Bool {
        switch self {
        case .noAnswer(.start, _), .closed(.start): true
        default: false
        }
    }
}

@MainActor protocol ExtensionPrivilegedTransport: AnyObject {
    func activate(source: URL, owner: String, version: String) async throws
    func invoke(_ command: String, payload: Data) async throws -> Data
    func release() async throws
    func invalidate()
}

@MainActor public final class ExtensionPrivilegedClient {
    public enum Mode: Equatable, Sendable {
        case managed
        case connectOnly(hostIdentifier: String)
    }

    public let owner: String
    private let mode: Mode
    private let source: URL
    private let version: String
    private let serviceStatus: @MainActor () -> SMAppService.Status
    private let registerService: @MainActor () throws -> Void
    private let openApproval: @MainActor () -> Void
    private let carrierPredatesHost: @MainActor () -> Bool
    private let connect:
        @MainActor (@escaping @MainActor () -> Void) -> any ExtensionPrivilegedTransport
    private var channel: (any ExtensionPrivilegedTransport)?
    private var channelID: UUID?
    private var needsRestoration = false
    private var requesting = false

    public convenience init(
        owner: String, source: URL, version: String, mode: Mode = .managed
    ) {
        self.init(
            owner: owner, source: source, version: version, mode: mode,
            status: { ExtensionPrivilegedService.service.status },
            register: { try ExtensionPrivilegedService.service.register() },
            openApproval: { SMAppService.openSystemSettingsLoginItems() },
            carrierPredatesHost: { ExtensionPrivilegedCarrierProcess.predatesHost() },
            connect: {
                let hostIdentifier: String?
                if case .connectOnly(let identifier) = mode {
                    hostIdentifier = identifier
                } else {
                    hostIdentifier = nil
                }
                return ExtensionPrivilegedXPC(
                    connection: NSXPCConnection(
                        machServiceName: ExtensionPrivilegedService.identifier,
                        options: .privileged),
                    hostIdentifier: hostIdentifier, invalidated: $0)
            })
    }

    init(
        owner: String, source: URL, version: String, mode: Mode = .managed,
        status: @escaping @MainActor () -> SMAppService.Status,
        register: @escaping @MainActor () throws -> Void = {},
        openApproval: @escaping @MainActor () -> Void = {},
        carrierPredatesHost: @escaping @MainActor () -> Bool = { false },
        connect:
            @escaping @MainActor (@escaping @MainActor () -> Void) ->
            any ExtensionPrivilegedTransport
    ) {
        self.owner = owner; self.source = source; self.version = version; self.mode = mode
        serviceStatus = status; registerService = register; self.openApproval = openApproval
        self.carrierPredatesHost = carrierPredatesHost; self.connect = connect
    }

    public var status: SMAppService.Status {
        switch mode {
        case .managed: return serviceStatus()
        case .connectOnly: return channel == nil ? .notFound : .enabled
        }
    }

    public func requestApproval() throws {
        guard mode == .managed else {
            throw ExtensionPeerError.rejected(
                "Open Edith and approve its privileged service before using this extension.")
        }
        if [.notRegistered, .notFound].contains(serviceStatus()) { try registerService() }
        if serviceStatus() == .requiresApproval { openApproval() }
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
        if case .connectOnly(let hostIdentifier) = mode {
            guard Self.validIdentifier(hostIdentifier) else {
                throw ExtensionPeerError.invalidRequest
            }
        }
        guard mode != .managed || status == .enabled else {
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
            if mode == .managed,
                (error as? ExtensionPrivilegedError)?.leftTheStartUnanswered == true,
                carrierPredatesHost()
            {
                throw ExtensionPrivilegedError.outdatedCarrier
            }
            throw error
        }
    }
    private static func validIdentifier(_ value: String) -> Bool {
        value.utf8.count <= 200 && value.contains(".")
            && value.components(separatedBy: ".").allSatisfy { !$0.isEmpty }
            && value.utf8.allSatisfy {
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
                    || [45, 46].contains($0)
            }
    }
}

@MainActor final class ExtensionPrivilegedXPC: ExtensionPrivilegedTransport {
    static let answerLimit = 20
    private let connection: NSXPCConnection
    private let answerLimit: Duration
    private let invalidated: @MainActor () -> Void
    private var proxy: ExtensionPrivilegedProtocol?
    private var pending:
        [UUID: (reply: ExtensionPrivilegedReply, step: ExtensionPrivilegedError.Step)] =
            [:]
    private var closed = false

    init(
        connection: NSXPCConnection, hostIdentifier: String?,
        answerLimit: Duration = .seconds(ExtensionPrivilegedXPC.answerLimit),
        invalidated: @escaping @MainActor () -> Void
    ) {
        self.connection = connection; self.answerLimit = answerLimit
        self.invalidated = invalidated
        if let hostIdentifier {
            guard let requirement = Self.requirement(hostIdentifier: hostIdentifier) else {
                connection.invalidate(); closed = true; return
            }
            connection.setCodeSigningRequirement(requirement)
        }
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

    private static func requirement(hostIdentifier: String) -> String? {
        var code: SecCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code else { return nil }
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            return nil
        }
        var information: CFDictionary?
        guard
            SecCodeCopySigningInformation(
                staticCode, SecCSFlags(rawValue: kSecCSSigningInformation),
                &information) == errSecSuccess,
            let values = information as? [String: Any],
            let team = values[kSecCodeInfoTeamIdentifier as String] as? String,
            !team.isEmpty,
            team.utf8.allSatisfy({
                (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
            })
        else { return nil }
        return
            "identifier \"\(hostIdentifier)\" and anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
    }

    func activate(source: URL, owner: String, version: String) async throws {
        _ = try await call(.start) { proxy, completion in
            proxy.activate(source.path, owner: owner, version: version) { completion(Data(), $0) }
        }
    }
    func invoke(_ command: String, payload: Data) async throws -> Data {
        try await call(.command(command)) { proxy, completion in
            proxy.invoke(command, payload: payload, reply: completion)
        }
    }
    func release() async throws {
        _ = try await call(.release) { proxy, completion in
            proxy.release { completion(Data(), $0) }
        }
    }
    func invalidate() {
        guard !closed else { return }; closed = true
        connection.invalidate(); proxy = nil
        for request in pending.values {
            request.reply.finish(.failure(ExtensionPrivilegedError.closed(request.step)))
        }
        pending.removeAll(); invalidated()
    }

    private func call(
        _ step: ExtensionPrivilegedError.Step,
        _ send: (ExtensionPrivilegedProtocol, @escaping @Sendable (Data?, NSError?) -> Void) -> Void
    ) async throws -> Data {
        guard !closed, let proxy else { throw ExtensionPrivilegedError.closed(step) }
        let reply = ExtensionPrivilegedReply()
        let id = UUID(); pending[id] = (reply, step)
        let limit = answerLimit
        let timeout = Task {
            try? await Task.sleep(for: limit)
            guard !Task.isCancelled else { return }
            let seconds = Int(limit.components.seconds)
            if reply.finish(.failure(ExtensionPrivilegedError.noAnswer(step, seconds: seconds))) {
                invalidate()
            }
        }
        defer { timeout.cancel(); pending[id] = nil }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard reply.begin(continuation) else { return }
                send(proxy) { data, error in
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
