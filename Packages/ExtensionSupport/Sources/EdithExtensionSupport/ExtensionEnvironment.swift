import Foundation

public enum ExtensionEnvironment {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var overrides: [String: String] = [:]

    public static var values: [String: String] {
        let configured = lock.withLock { overrides }
        return ProcessInfo.processInfo.environment.merging(configured) { $1 }
    }

    public static subscript(key: String) -> String? {
        lock.withLock { overrides[key] } ?? ProcessInfo.processInfo.environment[key]
    }

    public static func configure(_ values: [String: String]) {
        lock.withLock { overrides.merge(values) { $1 } }
    }
}

@_cdecl("edith_extension_configure_environment")
public func configureExtensionEnvironment(_ pointer: UnsafeRawPointer) {
    let dictionary = Unmanaged<NSDictionary>.fromOpaque(pointer).takeUnretainedValue()
    var values: [String: String] = [:]
    for case let (key as String, value as String) in dictionary { values[key] = value }
    ExtensionEnvironment.configure(values)
}
