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
    private let verify: (URL) throws -> Void
    private var loaded: [String: Loaded] = [:]
    private var retainedImages: [(Bundle, UnsafeMutableRawPointer, PackageFileLock)] = []
    private var failedLoads = Set<String>()

    public init(
        store: ExtensionPackageStore, role: Role, hostABI: String, architecture: String = "arm64",
        verify: @escaping (URL) throws -> Void
    ) {
        self.store = store
        self.role = role
        self.hostABI = hostABI
        self.architecture = architecture
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
        if let instance = loaded[id] { return instance }
        guard !failedLoads.contains(id) else { throw MarketplaceError.invalidBundle }
        guard
            let package = try store.installedPackage(
                id: id, hostABI: hostABI, architecture: architecture)
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
