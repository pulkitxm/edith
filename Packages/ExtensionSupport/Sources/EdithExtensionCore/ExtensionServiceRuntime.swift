import AppKit
import Foundation

public struct ExtensionHostContext {
    public let input: NSDictionary

    public init(input: NSDictionary) { self.input = input }

    public var dataDirectory: String? { input["dataDirectory"] as? String }
    public var isHostedFunctionalFixture: Bool { input["hostedFunctionalFixture"] != nil }
}

@MainActor
public protocol ExtensionService: AnyObject {
    var requiresOwnedDataDirectory: Bool { get }
    var requiresDefaultsSuite: Bool { get }
    var preparesForDisable: Bool { get }
    var preparesUIToClose: Bool { get }
    var allowsUIDuringRetirement: Bool { get }
    var statusDetails: [String: Any] { get }
    func acceptsStopUI(for presentation: UUID?) -> Bool
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
    public var requiresDefaultsSuite: Bool { true }
    public var preparesForDisable: Bool { false }
    public var preparesUIToClose: Bool { false }
    public var allowsUIDuringRetirement: Bool { false }
    public var statusDetails: [String: Any] { [:] }
    public func acceptsStopUI(for presentation: UUID?) -> Bool { true }
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
public final class ExtensionServiceRuntime: NSObject, ExtensionRuntimeProtocol {
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
        guard request["hostedFunctionalFixture"] == nil else {
            completion(nil, "The functional fixture is unavailable.")
            return
        }
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

    public var runtimeAPIVersion: Int { ExtensionRuntimeAPI.version }
    public var supportsDisablePreparation: Bool { service?.preparesForDisable == true }
    public var supportsPresentationPreparation: Bool { service?.preparesUIToClose == true }

    public func invokeCommand(_ command: String, token: UUID, payload: Data) async throws -> Data {
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            do {
                let data: Data = try await withCheckedThrowingContinuation { continuation in
                    invoke(["command": command, "token": token.uuidString, "payload": payload]) {
                        data, error in
                        if let data {
                            continuation.resume(returning: data as Data)
                        } else {
                            continuation.resume(
                                throwing: ExtensionPeerError.rejected(
                                    error as String? ?? "The extension command failed."))
                        }
                    }
                    if Task.isCancelled { commands.cancel(token.uuidString) }
                }
                try Task.checkCancellation()
                return data
            } catch {
                try Task.checkCancellation()
                throw error
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.commands.cancel(token.uuidString) }
        }
    }

    public func suspend() async { await beginSuspension().value }

    public func prepareForDisable() async throws {
        await beginSuspension().value
        try await service?.prepareDisable()
    }

    public func prepareForStop() async { await beginTeardown().value }

    public func preparePresentationToClose(_ presentation: UUID) async -> String? {
        await service?.prepareUIToClose(presentation)
    }

    @objc public func execute(_ input: NSDictionary) -> NSObject {
        guard let operation = input["operation"] as? String,
            let request = ExtensionRuntimeRequest(operation: operation, context: input)
        else { return Self.result(false) }
        return dispatch(request).object
    }

    public func dispatch(_ request: ExtensionRuntimeRequest) -> ExtensionRuntimeResponse {
        switch request {
        case .describe:
            return .description(
                ExtensionRuntimeDescription(
                    id: id, role: role,
                    version: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                        as? String ?? "",
                    hostABI: bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String ?? "",
                    apiVersion: runtimeAPIVersion))
        case let .start(context):
            let input = context.input
            guard suspension == nil, teardownTask == nil, let service,
                !service.requiresDefaultsSuite
                    || (input["defaultsSuite"] as? String).map({
                        $0 == scope["EDITH_SHARED_DEFAULTS_SUITE"]
                    }) == true,
                !service.requiresOwnedDataDirectory || ownsDataDirectory(input),
                service.start(context)
            else { return .result(false) }
            started = true
        case let .synchronize(context):
            guard suspension == nil, teardownTask == nil,
                service?.synchronize(context) == true
            else { return .result(false) }
        case let .configureUI(configuration):
            guard suspension == nil, teardownTask == nil,
                uiRetirements.isEmpty || service?.allowsUIDuringRetirement == true,
                configuration.extensionID == id,
                service?.configureUI(configuration) == true
            else { return .result(false) }
        case let .view(presentation, context):
            guard suspension == nil, teardownTask == nil,
                let controller = service?.view(for: presentation, context: context)
            else { return .result(false) }
            return .view(controller)
        case let .stopUI(presentation):
            guard service?.acceptsStopUI(for: presentation) != false else { return .result(false) }
            for task in service?.stopUI(for: presentation) ?? [] {
                let identifier = UUID()
                uiRetirements[identifier] = Task { [self] in
                    await task.value
                    uiRetirements[identifier] = nil
                }
            }
        case let .cancelCommand(token): commands.cancel(token.uuidString)
        case .stop: _ = beginTeardown()
        case .status:
            return .status(
                running: started && teardownTask == nil && service?.isRunning == true,
                details: service?.statusDetails ?? [:])
        case let .custom(operation, context):
            guard teardownTask == nil,
                suspension == nil || operation == "prepareApplicationQuit"
            else { return .result(false) }
            return service?.perform(operation, context: context).map(
                ExtensionRuntimeResponse.custom)
                ?? .result(false)
        }
        return .result(true)
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
