import AppKit
import Foundation

public struct ExtensionHostContext {
    public let input: NSDictionary

    public var dataDirectory: String? { input["dataDirectory"] as? String }
    public var isHostedFunctionalFixture: Bool { input["hostedFunctionalFixture"] != nil }
}

@MainActor
public protocol ExtensionService: AnyObject {
    var requiresOwnedDataDirectory: Bool { get }
    var preparesForDisable: Bool { get }
    var preparesUIToClose: Bool { get }
    func prepareUIToClose(_ presentation: UUID) async -> String?
    func finishBeforeStop() async
    func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController?
    func prepareDisable() async throws
    func start() -> Bool
    func start(_ context: ExtensionHostContext) -> Bool
    func synchronize()
    func synchronize(_ context: ExtensionHostContext) -> Bool
    func invoke(_ command: String, payload: Data) async throws -> Data
    func invoke(_ command: String, token: UUID, payload: Data) async throws -> Data
    func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool
    func view(for presentation: UUID) -> NSViewController?
    func stopUI() -> [Task<Void, Never>]
    func stopUI(for presentation: UUID?) -> [Task<Void, Never>]
    var isRunning: Bool { get }
    func cancelPendingWork()
    func drain() async
    func teardown() async
    func perform(_ operation: String, context: NSDictionary) -> NSObject?
}

extension ExtensionService {
    public var requiresOwnedDataDirectory: Bool { false }
    public var preparesForDisable: Bool { false }
    public var preparesUIToClose: Bool { false }
    public func prepareUIToClose(_ presentation: UUID) async -> String? { nil }
    public func finishBeforeStop() async {}
    public func view(for presentation: UUID, context: ExtensionHostContext) -> NSViewController? {
        view(for: presentation)
    }
    public func prepareDisable() async throws {}
    public func start() -> Bool { true }
    public func start(_ context: ExtensionHostContext) -> Bool { start() }
    public func synchronize() {}
    public func synchronize(_ context: ExtensionHostContext) -> Bool {
        synchronize()
        return true
    }
    public func invoke(_ command: String, payload: Data) async throws -> Data {
        throw ExtensionPeerError.unavailable
    }
    public func invoke(_ command: String, token: UUID, payload: Data) async throws -> Data {
        try await invoke(command, payload: payload)
    }
    public func configureUI(_ configuration: ExtensionUIConfiguration) -> Bool { false }
    public func view(for presentation: UUID) -> NSViewController? { nil }
    public func stopUI() -> [Task<Void, Never>] { [] }
    public func stopUI(for presentation: UUID?) -> [Task<Void, Never>] { stopUI() }
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
        let token = (request["token"] as? String).flatMap(UUID.init(uuidString:))
        commands.invoke(request, completion: completion) { [weak self] command, payload in
            guard let self, self.teardownTask == nil, let service = self.service, let token else {
                throw ExtensionPeerError.unavailable
            }
            return try await service.invoke(command, token: token, payload: payload)
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

    @objc(prepareDisableWithCompletion:)
    public func prepareDisable(completion: @escaping (NSError?) -> Void) {
        let suspended = beginSuspension()
        Task { [self] in
            await suspended.value
            let failure: NSError?
            do {
                try await service?.prepareDisable()
                failure = nil
            } catch {
                failure = error as NSError
            }
            withExtendedLifetime(self) { completion(failure) }
        }
    }

    public func stop() async {
        await beginTeardown().value
    }

    @objc(prepareUIToClose:completion:)
    public func prepareUIToClose(_ value: NSString, completion: @escaping (NSString?) -> Void) {
        guard let presentation = UUID(uuidString: value as String) else {
            completion("Invalid presentation.")
            return
        }
        Task { [self] in
            let failure = await service?.prepareUIToClose(presentation)
            withExtendedLifetime(self) { completion(failure.map { $0 as NSString }) }
        }
    }

    public override func responds(to selector: Selector!) -> Bool {
        if selector == NSSelectorFromString("prepareDisableWithCompletion:") {
            return service?.preparesForDisable == true
        }
        if selector == NSSelectorFromString("prepareUIToClose:completion:") {
            return service?.preparesUIToClose == true
        }
        return super.responds(to: selector)
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
            guard service.start(ExtensionHostContext(input: input)) else {
                return Self.result(false)
            }
            started = true
        case "synchronize":
            guard service?.synchronize(ExtensionHostContext(input: input)) == true else {
                return Self.result(false)
            }
        case "configureUI":
            guard suspension == nil, teardownTask == nil, uiRetirements.isEmpty,
                let configuration = ExtensionUIConfiguration(context: input),
                configuration.extensionID == id,
                service?.configureUI(configuration) == true
            else { return Self.result(false) }
        case "view":
            guard let value = input["presentationID"] as? String,
                let presentation = UUID(uuidString: value),
                let controller = service?.view(
                    for: presentation, context: ExtensionHostContext(input: input))
            else { return Self.result(false) }
            return controller
        case "stopUI":
            let presentation = (input["presentationID"] as? String).flatMap(UUID.init(uuidString:))
            for task in service?.stopUI(for: presentation) ?? [] {
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
        let task = Task { [self] in
            await service?.finishBeforeStop()
            let suspended = beginSuspension()
            commands.shutdown()
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
