import AppKit
import Foundation

@MainActor
public protocol ExtensionService: AnyObject {
    var requiresOwnedDataDirectory: Bool { get }
    func start() -> Bool
    func synchronize()
    func invoke(_ command: String, payload: Data) async throws -> Data
    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool
    func view(for presentation: UUID) -> NSViewController?
    func stopUI() -> [Task<Void, Never>]
    var isRunning: Bool { get }
    func cancelPendingWork()
    func drain() async
    func teardown() async
    func perform(_ operation: String, context: NSDictionary) -> NSObject?
}

extension ExtensionService {
    public var requiresOwnedDataDirectory: Bool { false }
    public func start() -> Bool { true }
    public func synchronize() {}
    public func invoke(_ command: String, payload: Data) async throws -> Data {
        throw ExtensionPeerError.unavailable
    }
    public func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool { false }
    public func view(for presentation: UUID) -> NSViewController? { nil }
    public func stopUI() -> [Task<Void, Never>] { [] }
    public var isRunning: Bool { true }
    public func cancelPendingWork() {}
    public func drain() async {}
    public func teardown() async {}
    public func perform(_ operation: String, context: NSDictionary) -> NSObject? { nil }
}

@MainActor
public final class ExtensionServiceRuntime: NSObject {
    public let id: String
    public let role: String
    private let bundle: Bundle
    private let scope: ExtensionScope
    private let commands = ExtensionCommandRegistry()
    private var service: (any ExtensionService)?
    private var started = false
    private var suspension: Task<Void, Never>?
    private var teardownTask: Task<Void, Never>?
    private var uiRetirements: [UUID: Task<Void, Never>] = [:]

    public init(
        id: String, role: String, bundle: Bundle, image: UnsafeRawPointer = #dsohandle,
        service make: (ExtensionServiceRuntime) -> any ExtensionService
    ) {
        self.id = id
        self.role = role
        self.bundle = bundle
        scope = ExtensionScope.resolve(image)
        super.init()
        service = make(self)
    }

    public var isStopping: Bool { teardownTask != nil }
    public var isSuspended: Bool { suspension != nil }

    @objc public func invoke(
        _ request: NSDictionary, completion: @escaping (NSData?, NSString?) -> Void
    ) {
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.teardownTask == nil, let service = self.service else {
                throw ExtensionPeerError.unavailable
            }
            return try await service.invoke(command, payload: payload)
        }
    }

    @objc(suspendCommandsWithCompletion:)
    public func suspendCommands(completion: @escaping () -> Void) {
        let pending = beginSuspension()
        Task { [self] in
            await pending.value
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc(prepareToStopWithCompletion:)
    public func prepareToStop(completion: @escaping () -> Void) {
        let pending = beginTeardown()
        Task { [self] in
            await pending.value
            withExtendedLifetime(self) { completion() }
        }
    }

    @objc public func execute(_ input: NSDictionary) -> NSObject {
        let operation = input["operation"] as? String ?? ""
        switch operation {
        case "describe":
            return [
                "id": id, "role": role,
                "version": bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                    as? String ?? "",
                "hostABI": bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
            ] as NSDictionary
        case "start":
            guard suspension == nil, teardownTask == nil, let service,
                let suite = input["defaultsSuite"] as? String,
                suite == scope["EDITH_SHARED_DEFAULTS_SUITE"],
                !service.requiresOwnedDataDirectory || ownsDataDirectory(input)
            else { return Self.result(false) }
            guard started || service.start() else { return Self.result(false) }
            started = true
        case "synchronize": service?.synchronize()
        case "configureUI":
            guard suspension == nil, teardownTask == nil, uiRetirements.isEmpty,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == id,
                service?.configureUI(configuration) == true
            else { return Self.result(false) }
        case "view":
            guard let value = input["presentationID"] as? String,
                let presentation = UUID(uuidString: value),
                let controller = service?.view(for: presentation)
            else { return Self.result(false) }
            return controller
        case "stopUI":
            for task in service?.stopUI() ?? [] {
                let identifier = UUID()
                uiRetirements[identifier] = Task { [self] in
                    await task.value
                    uiRetirements[identifier] = nil
                }
            }
        case "cancelCommand": commands.cancel(input["token"] as? String ?? "")
        case "stop": _ = beginTeardown()
        case "status":
            return [
                "ok": true,
                "running": started && teardownTask == nil && service?.isRunning == true,
            ] as NSDictionary
        default:
            return service?.perform(operation, context: input) ?? Self.result(false)
        }
        return Self.result(true)
    }

    private func ownsDataDirectory(_ input: NSDictionary) -> Bool {
        guard let path = input["dataDirectory"] as? String,
            let root = scope["EDITH_EXTENSION_DATA_ROOT"]
        else { return false }
        return URL(fileURLWithPath: path).standardizedFileURL.path
            == URL(fileURLWithPath: root).standardizedFileURL.path
    }

    private func beginSuspension() -> Task<Void, Never> {
        if let suspension { return suspension }
        commands.suspend()
        service?.cancelPendingWork()
        let retired = Array(uiRetirements.values)
        let task = Task { [self] in
            await commands.suspendAndWait()
            await service?.drain()
            for retirement in retired { await retirement.value }
        }
        suspension = task
        return task
    }

    private func beginTeardown() -> Task<Void, Never> {
        if let teardownTask { return teardownTask }
        let suspended = beginSuspension()
        commands.shutdown()
        let task = Task { [self] in
            await suspended.value
            await commands.shutdownAndWait()
            for retirement in Array(uiRetirements.values) { await retirement.value }
            await service?.teardown()
        }
        teardownTask = task
        return task
    }

    private static func result(_ ok: Bool) -> NSDictionary { ["ok": ok] as NSDictionary }
}
