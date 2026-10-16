import AppKit
import Darwin
import EdithExtensionSupport
import ExtensionMarketplace
import Foundation

@MainActor
public protocol HostScenePresentation: AnyObject {
    var request: HostExtensionContentRequest { get }
    var configuration: HostRemoteConfiguration { get }
    var processIdentity: HostRemoteProcessIdentity? { get }
    var engineIdentity: HostRemoteKernelIdentity? { get }
    var isPresented: Bool { get }
    func update(compact: Bool, visible: Bool, width: Double) async throws
    func terminalUI(_ event: HostTerminalUIEvent) async throws -> Bool
    func terminalUIStatus() async throws -> HostTerminalUIStatus
    func prepareToClose() async throws
    func close() async throws
}

extension HostRemoteSceneHandle: HostScenePresentation {}

@MainActor
final class HostLocalSession {
    private struct Loaded {
        let version: String
        let runtimes: [ExtensionBundleRuntime]
        let lease: PackageFileLock
    }

    private static var loaded: [String: Loaded] = [:]
    private static var superseded: [Loaded] = []
    let configuration: HostRemoteConfiguration
    let engine: HostRemoteEngineOwner?
    let peer: HostRemoteProcessIdentity?
    let hostIdentifier: String
    let runtimes: [ExtensionBundleRuntime]
    private var handles: [UUID: HostLocalSceneHandle] = [:]
    private var terminalRenderer = HostRemoteTerminalRenderer()
    private(set) var stopped = false
    var engineIdentity: HostRemoteKernelIdentity? { engine?.process }
    var isAvailable: Bool { !stopped && (engine?.process.isRunning ?? true) }
    var isIdle: Bool { handles.isEmpty }

    init(
        configuration: HostRemoteConfiguration, engine: HostRemoteEngineOwner?,
        marketplace: HostMarketplace
    ) throws {
        let package = configuration.package
        if let current = Self.loaded[package.id], current.version == package.version {
            runtimes = current.runtimes
        } else {
            let lease = try marketplace.packageStore.lease(package)
            let runtimes = try Self.load(
                package, store: marketplace.packageStore,
                development: marketplace.identity.development)
            if let previous = Self.loaded[package.id] { Self.superseded.append(previous) }
            Self.loaded[package.id] = Loaded(
                version: package.version, runtimes: runtimes, lease: lease)
            self.runtimes = runtimes
        }
        self.configuration = configuration
        self.engine = engine
        hostIdentifier = marketplace.identity.identifier
        peer = try? HostRemoteProcessIdentity.read(getpid())
    }

    private static func load(
        _ package: ExtensionPackage, store: ExtensionPackageStore, development: Bool
    ) throws -> [ExtensionBundleRuntime] {
        let payload = store.payloadDirectory(for: package)
        let directory = payload.deletingLastPathComponent()
        let team = ExtensionCodeSignature.teamIdentifier()
        var runtimes: [ExtensionBundleRuntime] = []
        for role in [ExtensionBundleRuntime.Role.app, .helper, .agent] {
            let bundle = payload.appendingPathComponent("\(role.rawValue).bundle")
            guard FileManager.default.fileExists(atPath: bundle.path) else { continue }
            runtimes.append(
                try ExtensionBundleRuntime(
                    readOnlyPackage: package, directory: directory, role: role,
                    hostABI: HostContract.compatibility,
                    verify: { url in
                        if development {
                            try ExtensionCodeSignature.verifyDevelopment(url)
                        } else {
                            guard let team else { throw MarketplaceError.invalidSignature }
                            try ExtensionCodeSignature.verify(url, teamIdentifier: team)
                        }
                    }))
        }
        guard !runtimes.isEmpty else { throw HostWorkerError.rejected }
        return runtimes
    }

    func reserve(_ request: HostExtensionContentRequest) throws -> HostLocalSceneHandle {
        guard isAvailable, handles[request.presentationID] == nil,
            !configuration.uiOnly || (request.location == "settings" && request.surface == nil)
        else { throw HostWorkerError.rejected }
        try request.validate(extensionID: configuration.package.id)
        let handle = HostLocalSceneHandle(session: self, request: request)
        handles[request.presentationID] = handle
        return handle
    }

    func release(_ presentationID: UUID) {
        guard let handle = handles.removeValue(forKey: presentationID) else { return }
        handle.detach()
        terminalRenderer.release(presentationID)
        for runtime in runtimes {
            _ = try? runtime.response(
                id: configuration.package.id, operation: "releaseUI",
                context: ["presentationID": presentationID.uuidString])
        }
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        for id in Array(handles.keys) { release(id) }
    }

    func terminal(
        _ handle: HostLocalSceneHandle, operation: HostTerminalUIRequest.Operation,
        event: HostTerminalUIEvent?
    ) throws -> Data {
        guard !stopped, handles[handle.request.presentationID] === handle, !configuration.uiOnly,
            HostTerminalUIRequest.accepts(handle.request), let runtime = handle.runtime
        else { throw HostWorkerError.rejected }
        let input = HostTerminalUIRequest(
            session: configuration.session, request: handle.request, operation: operation,
            event: event)
        let id = configuration.package.id
        return try terminalRenderer.response(
            input, session: configuration.session, owner: id, configuredRequest: handle.request
        ) { operation, context in
            try runtime.response(id: id, operation: operation, context: context)
        }
    }

    func context(for request: HostExtensionContentRequest, bridge: HostLocalEngineBridge?) throws
        -> NSMutableDictionary
    {
        let id = configuration.package.id
        let input = NSMutableDictionary(dictionary: [
            "remoteUI": true, "inProcess": true, "uiOnly": configuration.uiOnly,
            "location": request.location,
            "presentationID": request.presentationID.uuidString,
            "defaultsSuite": hostIdentifier + ".extension." + id + ".worker",
            "hostIdentifier": hostIdentifier, "extensionID": id,
        ])
        if let bridge { input["engineClient"] = bridge }
        input["section"] = request.section
        if let target = request.machinesWindow {
            input["target"] = try target.context(presentationID: request.presentationID)
        }
        if let target = request.herdrWindow {
            input["target"] = target.target
            input["herdrPresentationToken"] = target.token.uuidString
        }
        if let surface = request.surface {
            input["tile"] = try JSONEncoder().encode(surface.tile)
            input["target"] = surface.target.rawValue
        }
        return input
    }
}

@MainActor
public final class HostLocalSceneHandle: HostScenePresentation {
    public let request: HostExtensionContentRequest
    public var configuration: HostRemoteConfiguration { session.configuration }
    public var processIdentity: HostRemoteProcessIdentity? { session.peer }
    public var engineIdentity: HostRemoteKernelIdentity? { session.engineIdentity }
    public var isPresented: Bool { content != nil && !closed }
    private let session: HostLocalSession
    private var content: ExtensionBundlePresentation?
    private(set) var runtime: ExtensionBundleRuntime?
    private var bridge: HostLocalEngineBridge?
    private var closed = false
    private var intrinsic: Bool {
        !["main", "settings", "music.detail", "machines.window"].contains(request.location)
    }

    fileprivate init(session: HostLocalSession, request: HostExtensionContentRequest) {
        self.session = session
        self.request = request
    }

    func present(compact: Bool, visible: Bool, width: Double) throws -> NSViewController {
        guard !closed, content == nil, session.isAvailable else { throw HostWorkerError.rejected }
        let id = session.configuration.package.id
        let bridge = try session.engine.map {
            try HostLocalEngineBridge(engine: $0, presentationID: request.presentationID)
        }
        let input = try session.context(for: request, bridge: bridge)
        for runtime in session.runtimes {
            let response = try runtime.response(id: id, operation: "configureUI", context: input)
            guard response["ok"] as? Bool == true else { continue }
            if let result = try runtime.presentation(
                id: id, context: input, compact: compact, visible: visible,
                width: width.isFinite ? min(16_384, max(0, width)) : 0, intrinsic: intrinsic)
            {
                content = result
                self.runtime = runtime
                self.bridge = bridge
                return result.controller
            }
        }
        bridge?.cancelAll()
        throw HostWorkerError.rejected
    }

    public func update(compact: Bool, visible: Bool, width: Double) async throws {
        guard !closed else { throw HostWorkerError.rejected }
        try content?.update(
            compact: compact, visible: visible,
            width: width.isFinite ? min(16_384, max(0, width)) : 0, intrinsic: intrinsic)
    }

    public func terminalUI(_ event: HostTerminalUIEvent) async throws -> Bool {
        let data = try session.terminal(self, operation: .update, event: event)
        struct Reply: Decodable { let ok: Bool }
        return try JSONDecoder().decode(Reply.self, from: data).ok
    }

    public func terminalUIStatus() async throws -> HostTerminalUIStatus {
        let data = try session.terminal(self, operation: .status, event: nil)
        return try HostTerminalUIStatus.decode(data, presentationID: request.presentationID)
    }

    public func prepareToClose() async throws {
        guard !closed, let runtime else { return }
        try await runtime.preparePresentationToClose(
            id: session.configuration.package.id, presentationID: request.presentationID)
    }

    public func close() async throws {
        session.release(request.presentationID)
    }

    fileprivate func detach() {
        closed = true
        bridge?.cancelAll()
        bridge = nil
        content = nil
        runtime = nil
    }
}

@MainActor
public final class HostLocalEngineBridge: NSObject {
    private let engine: HostRemoteEngineOwner
    private let presentationID: UUID
    private var tasks: [UUID: Task<Void, Never>] = [:]

    init(engine: HostRemoteEngineOwner, presentationID: UUID) throws {
        try engine.validate()
        self.engine = engine
        self.presentationID = presentationID
    }

    @objc public func invoke(_ data: Data, completion: @escaping (Data) -> Void) {
        let reply = Completion(send: completion)
        guard
            let request = try? ExtensionEngineWire.decode(ExtensionEngineRequest.self, from: data),
            request.presentationID == presentationID, (try? request.validate()) != nil,
            tasks[request.token] == nil
        else { reply.finish(Data()); return }
        let token = request.token
        tasks[token] = Task { [weak self, engine] in
            let outcome: Result<Data, any Error>
            do { outcome = .success(try await engine.invoke(request)) } catch {
                outcome = .failure(error)
            }
            self?.tasks[token] = nil
            reply.finish(
                (try? ExtensionEngineWire.encode(
                    ExtensionEngineReply(
                        token: token, ok: (try? outcome.get()) != nil,
                        payload: (try? outcome.get()) ?? Data()))) ?? Data())
        }
    }

    @objc public func cancel(_ token: String) {
        guard token.utf8.count == 36, let token = UUID(uuidString: token) else { return }
        tasks.removeValue(forKey: token)?.cancel()
    }

    func cancelAll() {
        for task in tasks.values { task.cancel() }
        tasks.removeAll()
    }

    private final class Completion: @unchecked Sendable {
        private let send: (Data) -> Void
        init(send: @escaping (Data) -> Void) { self.send = send }
        @MainActor func finish(_ data: Data) { send(data) }
    }
}
