import Darwin
import Foundation

public final class ExtensionNativeLibrary: @unchecked Sendable {
    private final class Registry: @unchecked Sendable {
        let lock = NSLock()
        var images: [String: ExtensionNativeLibrary] = [:]
    }

    private static let registry = Registry()
    public let package: ExtensionPackage
    private let handle: UnsafeMutableRawPointer
    private let lease: PackageFileLock

    private init(package: ExtensionPackage, handle: UnsafeMutableRawPointer, lease: PackageFileLock)
    {
        self.package = package
        self.handle = handle
        self.lease = lease
    }

    public static func load(
        id: String, store: ExtensionPackageStore, hostABI: String,
        role: ExtensionBundleRuntime.Role = .app, architecture: String = "arm64",
        verify: (URL) throws -> Void
    ) throws -> ExtensionNativeLibrary {
        registry.lock.lock()
        defer { registry.lock.unlock() }
        guard try !store.pendingRemovals().contains(id) else { throw MarketplaceError.packageBusy }
        let key =
            "\(store.root.standardizedFileURL.path)/\(id)/\(hostABI)/\(architecture)/\(role.rawValue)"
        if let existing = registry.images[key] { return existing }
        guard
            let package = try store.installedPackage(
                id: id, hostABI: hostABI, architecture: architecture)
        else { throw MarketplaceError.packageNotInstalled }
        let lease = try store.lease(package)
        let url = store.directory(for: package).appendingPathComponent(id)
            .appendingPathComponent("\(role.rawValue).bundle")
        try verify(url)
        guard let bundle = Bundle(url: url),
            bundle.bundleIdentifier == "com.pulkit.edith.extensions.\(id).\(role.rawValue)",
            bundle.object(forInfoDictionaryKey: "EdithHostABI") as? String == hostABI,
            bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
                == package.version,
            let executable = bundle.executableURL,
            let handle = dlopen(executable.path, RTLD_NOW | RTLD_LOCAL)
        else { throw MarketplaceError.invalidBundle }
        let library = ExtensionNativeLibrary(package: package, handle: handle, lease: lease)
        registry.images[key] = library
        return library
    }

    public func symbol<T>(_ name: String, as type: T.Type) throws -> T {
        guard MemoryLayout<T>.size == MemoryLayout<UnsafeMutableRawPointer>.size,
            let symbol = dlsym(handle, name)
        else { throw MarketplaceError.invalidBundle }
        return unsafeBitCast(symbol, to: type)
    }
}
