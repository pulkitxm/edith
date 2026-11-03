import AppKit
import Darwin
import Foundation
import EdithExtensionCore
import ObjectiveC

@MainActor
public final class ExtensionBundleRuntime {
    public enum Role: String, CaseIterable, Sendable {
        case app
        case helper
        case agent
        case cli
        case privileged
    }

    public struct Snapshot: Equatable, Sendable {
        public let id: String
        public let version: String
        public let active: Bool
        public let restartRequired: Bool
    }

    private final class Loaded {
        let package: ExtensionPackage
        let bundle: Bundle
        let handle: UnsafeMutableRawPointer
        let object: NSObject & ExtensionRuntimeProtocol
        let lease: PackageFileLock?
        var active = false

        init(
            package: ExtensionPackage, bundle: Bundle, handle: UnsafeMutableRawPointer,
            object: NSObject & ExtensionRuntimeProtocol, lease: PackageFileLock?
        ) {
            self.package = package
            self.bundle = bundle
            self.handle = handle
            self.object = object
            self.lease = lease
        }
    }

    public let store: ExtensionPackageStore
    public let role: Role
    public let hostABI: String
    public let architecture: String
    private let packageVersion: String?
    private let verify: (URL) throws -> Void
    private let environment: [String: String]
    private let readOnlyPackage: (package: ExtensionPackage, directory: URL)?
    private var loaded: [String: Loaded] = [:]
    private var uiOwnership: NSObject?
    private var rendererCallbacks = RendererCallbacks()
    private var retainedImages: [(Bundle, UnsafeMutableRawPointer, PackageFileLock?)] = []
    private var failedLoads = Set<String>()

    public init(
        store: ExtensionPackageStore, role: Role, hostABI: String, architecture: String = "arm64",
        packageVersion: String? = nil, environment: [String: String] = [:],
        verify: @escaping (URL) throws -> Void
    ) {
        self.store = store
        self.role = role
        self.hostABI = hostABI
        self.architecture = architecture
        self.packageVersion = packageVersion
        self.environment = environment
        self.verify = verify
        readOnlyPackage = nil
    }

    public init(
        readOnlyPackage package: ExtensionPackage, directory: URL, role: Role,
        hostABI: String, environment: [String: String] = [:],
        verify: @escaping (URL) throws -> Void
    ) throws {
        guard [.app, .helper, .agent].contains(role),
            ExtensionHostABI.accepts(package.hostABI, host: hostABI),
            package.architecture == "arm64",
            package.minimumSystemVersion
                <= .init(ProcessInfo.processInfo.operatingSystemVersion)
        else { throw MarketplaceError.invalidBundle }
        store = ExtensionPackageStore(root: directory)
        self.role = role
        self.hostABI = hostABI
        architecture = package.architecture
        packageVersion = package.version
        self.environment = environment
        self.verify = verify
        readOnlyPackage = (package, directory.resolvingSymlinksInPath())
    }

    public func makeRenderer(ownership: NSObject? = nil) throws -> ExtensionBundleRuntime {
        guard let selected = readOnlyPackage else { throw MarketplaceError.invalidBundle }
        let renderer = try ExtensionBundleRuntime(
            readOnlyPackage: selected.package, directory: selected.directory, role: role,
            hostABI: hostABI, environment: environment, verify: verify)
        renderer.uiOwnership = ownership
        return renderer
    }

    public func prepare(id: String) throws { _ = try load(id: id) }

    public func start(id: String, context: NSDictionary) throws {
        guard readOnlyPackage == nil else { throw MarketplaceError.invalidBundle }
        let instance = try load(id: id)
        guard !instance.active else { return }
        if context["recoveryOnly"] as? Bool == true,
            !instance.object.supportsDisablePreparation
        {
            return
        }
        let response = try execute(instance, operation: "start", context: context)
        guard response["ok"] as? Bool == true else {
            _ = try? execute(instance, operation: "stop", context: [:])
            throw BundleCommandError.failed(
                response["error"] as? String ?? "\(id) \(role.rawValue) refused to start")
        }
        instance.active = context["recoveryOnly"] as? Bool != true
    }

    public func synchronize(id: String, context: NSDictionary) throws {
        guard let instance = loaded[id], instance.active else { return }
        let response = try execute(instance, operation: "synchronize", context: context)
        guard response["ok"] as? Bool == true else { throw MarketplaceError.invalidBundle }
    }

    public func stop(id: String) throws {
        guard let instance = loaded[id], instance.active else { return }
        let response = try execute(instance, operation: "stop", context: [:])
        guard response["ok"] as? Bool == true else { throw MarketplaceError.invalidBundle }
        instance.active = false
    }

    public func suspendCommandsAll() async throws {
        try await suspendCommands(includeInactive: false)
    }

    private func suspendCommands(includeInactive: Bool) async throws {
        for instance in loaded.values where instance.active || includeInactive {
            await instance.object.suspend()
        }
    }

    public func prepareDisableAll() async throws {
        try await suspendCommandsAll()
        for instance in loaded.values
        where instance.active && instance.object.supportsDisablePreparation {
            try await instance.object.prepareForDisable()
        }
    }

    public func prepareToStopAll() async throws {
        try await prepareToStop(includeInactive: false)
    }

    private func prepareToStop(includeInactive: Bool) async throws {
        for instance in loaded.values where instance.active || includeInactive {
            await instance.object.prepareForStop()
        }
    }

    public func stopAll() throws {
        var failure: Error?
        for id in loaded.keys {
            do { try stop(id: id) } catch { failure = error }
        }
        if let failure { throw failure }
    }

    public func response(id: String, operation: String, context: NSDictionary = [:]) throws
        -> NSDictionary
    {
        if let selected = readOnlyPackage {
            guard id == selected.package.id else { throw MarketplaceError.invalidBundle }
            if operation == "stopUI", loaded[id] == nil { return ["ok": true] }
            return try rendererCallbacks.response(
                id: id, role: role, operation: operation, context: context,
                execute: {
                    try self.execute(self.load(id: id), operation: operation, context: context)
                })
        }
        return try execute(load(id: id), operation: operation, context: context)
    }

    public func preparePresentationToClose(id: String, presentationID: UUID) async throws {
        guard readOnlyPackage != nil, let instance = loaded[id] else { return }
        try await Self.preparePresentationToClose(
            object: instance.object, presentationID: presentationID)
    }

    static func preparePresentationToClose(
        object: any ExtensionRuntimeProtocol, presentationID: UUID
    ) async throws {
        guard object.supportsPresentationPreparation else { return }
        let completion = BundleCommandCompletion()
        try await withTaskCancellationHandler {
            _ = try await withCheckedThrowingContinuation { continuation in
                guard completion.begin(continuation) else { return }
                Task { @MainActor in
                    let error = await object.preparePresentationToClose(presentationID)
                    completion.finish(
                        error == nil ? .success(Data()) : .failure(MarketplaceError.invalidBundle))
                }
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
        }
    }

    public func supportsCommands(id: String) -> Bool {
        guard let instance = loaded[id], instance.active else { return false }
        return ExtensionRuntimeAPI.supportedVersions.contains(instance.object.runtimeAPIVersion)
    }

    public func command(id: String, token: UUID, command: String, payload: Data) async throws
        -> Data
    {
        guard let instance = loaded[id], instance.active, supportsCommands(id: id) else {
            throw MarketplaceError.invalidBundle
        }
        return try await Self.command(
            object: instance.object, token: token, command: command, payload: payload
        ) { [weak self] in
            _ = try? self?.response(
                id: id, operation: "cancelCommand", context: ["token": token.uuidString])
        }
    }

    static func command(
        object: any ExtensionRuntimeProtocol, token: UUID, command: String, payload: Data,
        cancel: @escaping @MainActor () -> Void
    ) async throws -> Data {
        let completion = BundleCommandCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.begin(continuation) else { return }
                let invocation = Task { @MainActor in
                    do {
                        try Task.checkCancellation()
                        completion.finish(
                            .success(
                                try await object.invokeCommand(
                                    command, token: token, payload: payload)))
                    } catch { completion.finish(.failure(error)) }
                }
                completion.attach(invocation)
            }
        } onCancel: {
            completion.cancel()
            Task { @MainActor in cancel() }
        }
    }

    public func nativeTask(id: String, payload: Data) throws -> Int32 {
        guard readOnlyPackage == nil, role == .app, !payload.isEmpty, payload.count <= 65_536 else {
            throw MarketplaceError.invalidBundle
        }
        let instance = try load(id: id)
        guard let symbol = dlsym(instance.handle, "edith_extension_native_task") else {
            throw MarketplaceError.invalidBundle
        }
        typealias Entry = @convention(c) (UnsafePointer<UInt8>?, Int32) -> Int32
        let entry = unsafeBitCast(symbol, to: Entry.self)
        return payload.withUnsafeBytes { bytes in
            entry(bytes.bindMemory(to: UInt8.self).baseAddress, Int32(bytes.count))
        }
    }

    public func snapshot(id: String) throws -> Snapshot? {
        guard let instance = loaded[id] else { return nil }
        let installed =
            try readOnlyPackage?.package
            ?? store.installedPackage(id: id, hostABI: hostABI, architecture: architecture)
        return Snapshot(
            id: id, version: instance.package.version, active: instance.active,
            restartRequired: installed != instance.package)
    }

    public func viewController(id: String, context: NSDictionary) throws -> NSViewController? {
        let instance = try load(id: id)
        if let uiOwnership {
            let key = unsafeBitCast(
                NSSelectorFromString("edithExtensionUIOwnership"), to: UnsafeRawPointer.self)
            objc_setAssociatedObject(
                instance.object, key, uiOwnership, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        guard let value = context["presentationID"] as? String,
            let presentation = UUID(uuidString: value)
        else { return nil }
        guard
            case let .view(controller) = instance.object.dispatch(
                .view(presentation, ExtensionHostContext(input: context)))
        else { return nil }
        return controller
    }

    public func presentation(
        id: String, context: NSDictionary, compact: Bool, visible: Bool, width: Double,
        intrinsic: Bool
    ) throws -> ExtensionBundlePresentation? {
        let instance = try load(id: id)
        guard let symbol = dlsym(instance.handle, "edith_extension_presentation_create") else {
            throw MarketplaceError.invalidBundle
        }
        typealias Create = @convention(c) () -> UnsafeMutableRawPointer?
        let create = unsafeBitCast(symbol, to: Create.self)
        guard let pointer = create() else { throw MarketplaceError.invalidBundle }
        let presentation = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
        var failure: Error?
        let factory: @convention(block) () -> NSViewController? = {
            do { return try self.viewController(id: id, context: context) } catch {
                failure = error; return nil
            }
        }
        let result = try ExtensionBundlePresentation.make(
            context: presentation,
            input: [
                "compact": compact, "visible": visible, "width": width,
                "intrinsic": intrinsic,
            ], factory: factory)
        if let failure { throw failure }
        return result
    }

    struct RendererCallbacks {
        private struct Binding: Equatable {
            let owner: String
            let location: String
            let target: String?
            let token: String?
        }
        private struct Event: Decodable {
            let version: Int
            let presentationID: UUID
            let sequence: UInt64
            let active: Bool
            let key: Bool
            let visible: Bool
            let action: String?
        }
        private var bindings: [UUID: Binding] = [:]
        private var sequences: [UUID: UInt64] = [:]

        mutating func response(
            id: String, role: Role, operation: String, context: NSDictionary,
            execute: () throws -> NSDictionary
        ) throws -> NSDictionary {
            switch operation {
            case "describe": return try execute()
            case "configureUI":
                if let rawID = context["presentationID"] as? String,
                    let presentation = UUID(uuidString: rawID), let binding = bindings[presentation]
                {
                    guard binding.owner == id, role == .app,
                        context["remoteUI"] as? Bool == true, context["uiOnly"] as? Bool == false,
                        context["extensionID"] as? String == id,
                        context["engineClient"] as? NSObject != nil,
                        context["location"] as? String == binding.location,
                        context["target"] as? String == binding.target,
                        context["herdrPresentationToken"] as? String == binding.token
                    else { throw MarketplaceError.invalidBundle }
                }
                let result = try execute()
                if result["ok"] as? Bool == true,
                    role == .app, context["remoteUI"] as? Bool == true,
                    context["uiOnly"] as? Bool == false,
                    context["extensionID"] as? String == id,
                    context["engineClient"] as? NSObject != nil,
                    let rawID = context["presentationID"] as? String,
                    let presentation = UUID(uuidString: rawID),
                    let location = context["location"] as? String, Self.accepts(id, location)
                {
                    let binding = Binding(
                        owner: id, location: location, target: context["target"] as? String,
                        token: context["herdrPresentationToken"] as? String)
                    if location.hasPrefix("herdr.") {
                        guard let target = binding.target, !target.isEmpty,
                            target.utf8.count <= 4096,
                            !target.utf8.contains(0), let token = binding.token,
                            UUID(uuidString: token) != nil
                        else { throw MarketplaceError.invalidBundle }
                    }
                    guard bindings.count < 64 || bindings[presentation] != nil,
                        bindings[presentation].map({ $0 == binding }) ?? true
                    else { throw MarketplaceError.invalidBundle }
                    bindings[presentation] = binding
                } else if let rawID = context["presentationID"] as? String,
                    let presentation = UUID(uuidString: rawID)
                {
                    bindings[presentation] = nil
                }
                return result
            case "releaseUI":
                if let rawID = context["presentationID"] as? String,
                    let presentation = UUID(uuidString: rawID)
                {
                    bindings[presentation] = nil; sequences[presentation] = nil
                }
                return try execute()
            case "stopUI":
                if let rawID = context["presentationID"] as? String,
                    let presentation = UUID(uuidString: rawID)
                {
                    bindings[presentation] = nil; sequences[presentation] = nil
                } else {
                    bindings.removeAll(); sequences.removeAll()
                }
                return try execute()
            case "terminalUI", "terminalUIStatus":
                guard role == .app, let rawID = context["presentationID"] as? String,
                    let presentation = UUID(uuidString: rawID),
                    let binding = bindings[presentation],
                    binding.owner == id, Self.accepts(id, binding.location)
                else { throw MarketplaceError.invalidBundle }
                if operation == "terminalUIStatus" {
                    guard Set(context.allKeys.compactMap { $0 as? String }) == ["presentationID"]
                    else { throw MarketplaceError.invalidBundle }
                } else {
                    guard
                        Set(context.allKeys.compactMap { $0 as? String }) == [
                            "presentationID", "payload",
                        ],
                        let data = context["payload"] as? Data, !data.isEmpty, data.count <= 1024,
                        let fields = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                        Set(fields.keys).isSubset(of: [
                            "version", "presentationID", "sequence", "active", "key", "visible",
                            "action",
                        ])
                    else { throw MarketplaceError.invalidBundle }
                    let event = try JSONDecoder().decode(Event.self, from: data)
                    guard event.version == 1, event.presentationID == presentation,
                        event.sequence > (sequences[presentation] ?? 0),
                        event.action.map({
                            [
                                "fontZoomIn", "fontZoomOut", "fontZoomReset", "newTab", "closeTab",
                                "nextTab", "previousTab", "windowClosed",
                            ].contains($0)
                        }) ?? true
                    else { throw MarketplaceError.invalidBundle }
                    sequences[presentation] = event.sequence
                }
                return try execute()
            default: throw MarketplaceError.invalidBundle
            }
        }

        private static func accepts(_ id: String, _ location: String) -> Bool {
            switch (id, location) {
            case ("terminal", "main"), ("herdr", "main"), ("herdr", "herdr.agent"),
                ("herdr", "herdr.space"), ("quinjet", "main"):
                true
            default: false
            }
        }
    }

    private func load(id: String) throws -> Loaded {
        if readOnlyPackage == nil {
            guard try !store.pendingRemovals().contains(id) else {
                throw MarketplaceError.packageBusy
            }
        }
        if let instance = loaded[id] { return instance }
        guard !failedLoads.contains(id) else { throw MarketplaceError.invalidBundle }
        let package: ExtensionPackage
        let directory: URL
        let lease: PackageFileLock?
        if let selected = readOnlyPackage {
            guard selected.package.id == id else { throw MarketplaceError.invalidBundle }
            package = selected.package
            directory = selected.directory
            lease = nil
        } else {
            guard
                let installed = try store.installedPackage(
                    id: id, hostABI: hostABI, architecture: architecture, version: packageVersion)
            else { throw MarketplaceError.packageNotInstalled }
            package = installed
            directory = store.directory(for: package)
            lease = try store.lease(package)
        }
        let url =
            readOnlyPackage == nil
            ? store.roleBundle(for: package, role: role)
            : directory.appendingPathComponent(id).appendingPathComponent("\(role.rawValue).bundle")
        try verify(url)
        guard let bundle = Bundle(url: url), let executable = bundle.executableURL else {
            throw MarketplaceError.invalidBundle
        }
        guard bundle.bundleIdentifier == "com.pulkit.edith.extensions.\(id).\(role.rawValue)",
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == package.version,
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == package.hostABI,
            ExtensionHostABI.accepts(package.hostABI, host: hostABI)
        else { throw MarketplaceError.invalidBundle }
        try bundle.loadAndReturnError()
        guard let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) else {
            throw MarketplaceError.invalidBundle
        }
        retainedImages.append((bundle, handle, lease))
        failedLoads.insert(id)
        if !environment.isEmpty { configureEnvironment(bundle: bundle, handle: handle) }
        guard let entrypoint = dlsym(handle, "edith_extension_create") else {
            throw MarketplaceError.invalidBundle
        }
        typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
        let factory = unsafeBitCast(entrypoint, to: Factory.self)
        guard let pointer = factory() else {
            throw MarketplaceError.invalidBundle
        }
        let created = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
        guard let object = created as? (NSObject & ExtensionRuntimeProtocol),
            ExtensionRuntimeAPI.supportedVersions.contains(object.runtimeAPIVersion),
            bundle.object(forInfoDictionaryKey: "EdithRuntimeAPIVersion") as? Int
                == object.runtimeAPIVersion
        else {
            throw MarketplaceError.invalidBundle
        }
        let privileged =
            readOnlyPackage == nil
            ? store.roleBundle(for: package, role: .privileged)
            : directory.appendingPathComponent(id).appendingPathComponent("privileged.bundle")
        guard
            readOnlyPackage != nil || !FileManager.default.fileExists(atPath: privileged.path)
                || object.supportsDisablePreparation
        else { throw MarketplaceError.invalidBundle }
        let instance = Loaded(
            package: package, bundle: bundle, handle: handle, object: object, lease: lease)
        let description = try execute(instance, operation: "describe", context: [:])
        guard description["id"] as? String == id,
            description["version"] as? String == package.version,
            description["hostABI"] as? String == package.hostABI,
            description["role"] as? String == role.rawValue
        else {
            throw MarketplaceError.invalidBundle
        }
        failedLoads.remove(id)
        loaded[id] = instance
        return instance
    }

    private func configureEnvironment(bundle: Bundle, handle: UnsafeMutableRawPointer) {
        typealias Configure = @convention(c) (UnsafeRawPointer) -> Void
        var handles = [handle]
        let directory = bundle.privateFrameworksURL
        let frameworks =
            directory.flatMap {
                try? FileManager.default.contentsOfDirectory(
                    at: $0, includingPropertiesForKeys: nil)
            } ?? []
        for item in frameworks {
            let binary =
                item.pathExtension == "framework"
                ? Bundle(url: item)?.executableURL : item.pathExtension == "dylib" ? item : nil
            guard let binary, let native = dlopen(binary.path, RTLD_NOW | RTLD_NOLOAD) else {
                continue
            }
            handles.append(native)
        }
        let values = environment as NSDictionary
        withExtendedLifetime(values) {
            for image in handles {
                guard let symbol = dlsym(image, "edith_extension_configure_environment") else {
                    continue
                }
                unsafeBitCast(symbol, to: Configure.self)(
                    UnsafeRawPointer(Unmanaged.passUnretained(values).toOpaque()))
            }
        }
    }

    private func execute(_ instance: Loaded, operation: String, context: NSDictionary) throws
        -> NSDictionary
    {
        if let uiOwnership {
            let key = unsafeBitCast(
                NSSelectorFromString("edithExtensionUIOwnership"), to: UnsafeRawPointer.self)
            objc_setAssociatedObject(
                instance.object, key, uiOwnership, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        let input = NSMutableDictionary(dictionary: context)
        if let uiOwnership, !["terminalUI", "terminalUIStatus"].contains(operation) {
            input["hostUIOwnership"] = uiOwnership
        }
        input["operation"] = operation
        guard let request = ExtensionRuntimeRequest(operation: operation, context: input),
            let result = instance.object.dispatch(request).object as? NSDictionary
        else { throw MarketplaceError.invalidBundle }
        return result
    }
}

private enum BundleCommandError: LocalizedError {
    case failed(String)
    var errorDescription: String? {
        switch self {
        case let .failed(message): message
        }
    }
}

private final class BundleCommandCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Data, any Error>?
    private var result: Result<Data, any Error>?
    private var invocation: Task<Void, Never>?

    func attach(_ task: Task<Void, Never>) {
        let completed = lock.withLock {
            guard result == nil else { return true }
            invocation = task
            return false
        }
        if completed { task.cancel() }
    }

    func cancel() { finish(.failure(CancellationError()), cancelInvocation: true) }

    func begin(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        let completedResult = lock.withLock { () -> Result<Data, any Error>? in
            if let result = self.result { return result }
            self.continuation = continuation
            return nil
        }
        if let completedResult { continuation.resume(with: completedResult); return false }
        return true
    }

    func finish(_ result: Result<Data, any Error>, cancelInvocation: Bool = false) {
        let pending = lock.withLock {
            () -> (CheckedContinuation<Data, any Error>?, Task<Void, Never>?) in
            guard self.result == nil else { return (nil, nil) }
            self.result = result
            defer { self.continuation = nil; invocation = nil }
            return (continuation, invocation)
        }
        if cancelInvocation { pending.1?.cancel() }
        pending.0?.resume(with: result)
    }
}
