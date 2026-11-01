import Foundation

public struct ExtensionScope: Sendable {
    public let environment: @Sendable () -> [String: String]
    public let value: @Sendable (String) -> String?
    public let defaults: @Sendable () -> UserDefaults
    public let dataRoot: @Sendable () -> URL

    public init(
        environment: @escaping @Sendable () -> [String: String],
        value: @escaping @Sendable (String) -> String?,
        defaults: @escaping @Sendable () -> UserDefaults,
        dataRoot: @escaping @Sendable () -> URL
    ) {
        self.environment = environment
        self.value = value
        self.defaults = defaults
        self.dataRoot = dataRoot
    }

    public subscript(key: String) -> String? { value(key) }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [UInt: ExtensionScope] = [:]

    public static var process: ExtensionScope { processScope }

    public static func resolve(_ image: UnsafeRawPointer) -> ExtensionScope {
        lock.withLock { images[UInt(bitPattern: image)] } ?? processScope
    }

    public static func register(_ scope: ExtensionScope, image: UnsafeRawPointer) {
        lock.withLock { images[UInt(bitPattern: image)] = scope }
    }

    public static func temporaryDataRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-extension-\(UUID().uuidString)", isDirectory: true)
    }

    public static func childEnvironment(
        _ environment: [String: String], executable: String
    ) -> [String: String] {
        guard executable != Bundle.main.executablePath else { return environment }
        return environment.filter { !isPrivate($0.key) }
    }

    public static func isPrivate(_ key: String) -> Bool {
        key.hasPrefix("EDITH_EXTENSION_")
            || ["EDITH_SHARED_DEFAULTS_SUITE", "EDITH_SURFACE_DEFAULTS_SUITE"].contains(key)
    }

    private static let processStore = ExtensionDefaults.store(
        environment: ProcessInfo.processInfo.environment,
        applicationIdentifier: Bundle.main.bundleIdentifier)
    private static let processTemporaryRoot = temporaryDataRoot()

    private static let processScope = ExtensionScope(
        environment: { ProcessInfo.processInfo.environment },
        value: { ProcessInfo.processInfo.environment[$0] },
        defaults: { processStore },
        dataRoot: {
            ExtensionDataLayout.resolve(
                environment: ProcessInfo.processInfo.environment, fallback: processTemporaryRoot)
        })
}
