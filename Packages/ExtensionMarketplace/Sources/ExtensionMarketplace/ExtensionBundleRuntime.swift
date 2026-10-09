import AppKit
import Darwin
import Foundation

@MainActor
public final class ExtensionBundleRuntime {
    public enum Role: String, CaseIterable, Sendable {
        case app
        case helper
        case agent
        case cli
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
        let object: NSObject
        let lease: PackageFileLock
        var active = false

        init(
            package: ExtensionPackage, bundle: Bundle, handle: UnsafeMutableRawPointer,
            object: NSObject, lease: PackageFileLock
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
    private var loaded: [String: Loaded] = [:]
    private var retainedImages: [(Bundle, UnsafeMutableRawPointer, PackageFileLock)] = []
    private var failedLoads = Set<String>()

    public init(
        store: ExtensionPackageStore, role: Role, hostABI: String, architecture: String = "arm64",
        packageVersion: String? = nil, verify: @escaping (URL) throws -> Void
    ) {
        self.store = store
        self.role = role
        self.hostABI = hostABI
        self.architecture = architecture
        self.packageVersion = packageVersion
        self.verify = verify
    }

    public func start(id: String, context: NSDictionary) throws {
        let instance = try load(id: id)
        guard !instance.active else { return }
        let response = try execute(instance, operation: "start", context: context)
        guard response["ok"] as? Bool == true else {
            _ = try? execute(instance, operation: "stop", context: [:])
            throw MarketplaceError.invalidBundle
        }
        instance.active = true
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

    public func prepareToStopAll() async throws {
        let selector = NSSelectorFromString("prepareToStopWithCompletion:")
        for instance in loaded.values
        where instance.active && instance.object.responds(to: selector) {
            let completion = BundleCommandCompletion()
            _ = try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    guard completion.begin(continuation) else { return }
                    typealias Prepare =
                        @convention(c) (AnyObject, Selector, @convention(block) () -> Void) -> Void
                    let prepare = unsafeBitCast(
                        instance.object.method(for: selector), to: Prepare.self)
                    let callback: @convention(block) () -> Void = {
                        completion.finish(.success(Data()))
                    }
                    prepare(instance.object, selector, callback)
                }
            } onCancel: {
                completion.finish(.failure(CancellationError()))
            }
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
        try execute(load(id: id), operation: operation, context: context)
    }

    public func supportsCommands(id: String) -> Bool {
        guard let instance = loaded[id], instance.active else { return false }
        return instance.object.responds(to: NSSelectorFromString("invoke:completion:"))
    }

    public func command(id: String, token: UUID, command: String, payload: Data) async throws
        -> Data
    {
        guard let instance = loaded[id], instance.active, supportsCommands(id: id) else {
            throw MarketplaceError.invalidBundle
        }
        let completion = BundleCommandCompletion()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                guard completion.begin(continuation) else { return }
                let selector = NSSelectorFromString("invoke:completion:")
                typealias Invoke =
                    @convention(c) (
                        AnyObject, Selector, NSDictionary,
                        @convention(block) (NSData?, NSString?) -> Void
                    ) -> Void
                let invoke = unsafeBitCast(instance.object.method(for: selector), to: Invoke.self)
                let callback: @convention(block) (NSData?, NSString?) -> Void = {
                    payload, message in
                    if let payload {
                        completion.finish(.success(payload as Data))
                    } else {
                        completion.finish(
                            .failure(
                                BundleCommandError.failed(
                                    message as String? ?? "The extension command failed.")))
                    }
                }
                invoke(
                    instance.object, selector,
                    ["token": token.uuidString, "command": command, "payload": payload]
                        as NSDictionary, callback)
            }
        } onCancel: {
            completion.finish(.failure(CancellationError()))
            Task { @MainActor [weak self] in
                _ = try? self?.response(
                    id: id, operation: "cancelCommand", context: ["token": token.uuidString])
            }
        }
    }

    public func snapshot(id: String) throws -> Snapshot? {
        guard let instance = loaded[id] else { return nil }
        let installed = try store.installedPackage(
            id: id, hostABI: hostABI, architecture: architecture)
        return Snapshot(
            id: id, version: instance.package.version, active: instance.active,
            restartRequired: installed != instance.package)
    }

    public func viewController(id: String, context: NSDictionary) throws -> NSViewController? {
        let instance = try load(id: id)
        let input = NSMutableDictionary(dictionary: context)
        input["operation"] = "view"
        return instance.object.perform(NSSelectorFromString("execute:"), with: input)?
            .takeUnretainedValue() as? NSViewController
    }

    private func load(id: String) throws -> Loaded {
        guard try !store.pendingRemovals().contains(id) else { throw MarketplaceError.packageBusy }
        if let instance = loaded[id] { return instance }
        guard !failedLoads.contains(id) else { throw MarketplaceError.invalidBundle }
        guard
            let package = try store.installedPackages().filter({
                $0.id == id && $0.hostABI == hostABI && $0.architecture == architecture
                    && (packageVersion == nil || $0.version == packageVersion)
            }).max(by: { $0.version.compare($1.version, options: .numeric) == .orderedAscending })
        else {
            throw MarketplaceError.packageNotInstalled
        }
        let lease = try store.lease(package)
        let url = store.directory(for: package).appendingPathComponent(id).appendingPathComponent(
            "\(role.rawValue).bundle")
        try verify(url)
        guard let bundle = Bundle(url: url), let executable = bundle.executableURL else {
            throw MarketplaceError.invalidBundle
        }
        guard bundle.bundleIdentifier == "com.pulkit.edith.extensions.\(id).\(role.rawValue)",
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == package.version,
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == hostABI
        else { throw MarketplaceError.invalidBundle }
        try bundle.loadAndReturnError()
        guard let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL) else {
            throw MarketplaceError.invalidBundle
        }
        retainedImages.append((bundle, handle, lease))
        failedLoads.insert(id)
        guard let entrypoint = dlsym(handle, "edith_extension_create") else {
            throw MarketplaceError.invalidBundle
        }
        typealias Factory = @convention(c) () -> UnsafeMutableRawPointer?
        let factory = unsafeBitCast(entrypoint, to: Factory.self)
        guard let pointer = factory() else {
            throw MarketplaceError.invalidBundle
        }
        let object = Unmanaged<NSObject>.fromOpaque(pointer).takeRetainedValue()
        guard object.responds(to: NSSelectorFromString("execute:")) else {
            throw MarketplaceError.invalidBundle
        }
        let instance = Loaded(
            package: package, bundle: bundle, handle: handle, object: object, lease: lease)
        let description = try execute(instance, operation: "describe", context: [:])
        guard description["id"] as? String == id,
            description["version"] as? String == package.version,
            description["hostABI"] as? String == hostABI,
            description["role"] as? String == role.rawValue
        else {
            throw MarketplaceError.invalidBundle
        }
        failedLoads.remove(id)
        loaded[id] = instance
        return instance
    }

    private func execute(_ instance: Loaded, operation: String, context: NSDictionary) throws
        -> NSDictionary
    {
        let input = NSMutableDictionary(dictionary: context)
        input["operation"] = operation
        guard
            let result = instance.object.perform(NSSelectorFromString("execute:"), with: input)?
                .takeUnretainedValue() as? NSDictionary
        else {
            throw MarketplaceError.invalidBundle
        }
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

    func begin(_ continuation: CheckedContinuation<Data, any Error>) -> Bool {
        let completedResult = lock.withLock { () -> Result<Data, any Error>? in
            if let result = self.result { return result }
            self.continuation = continuation
            return nil
        }
        if let completedResult { continuation.resume(with: completedResult); return false }
        return true
    }

    func finish(_ result: Result<Data, any Error>) {
        let continuation = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
            guard self.result == nil else { return nil }
            self.result = result
            defer { self.continuation = nil }
            return self.continuation
        }
        continuation?.resume(with: result)
    }
}
