import Foundation

public struct AppDirectories: Equatable, Sendable {
    public let configuration: URL
    public let data: URL
    public let cache: URL
    public let runtime: URL

    public init(
        platform: AppPlatform,
        homeDirectory: URL,
        environment: [String: String] = [:]
    ) {
        switch platform {
        case .macOS:
            configuration = homeDirectory.appendingPathComponent(
                "Library/Application Support/Edith")
            data = configuration
            cache = homeDirectory.appendingPathComponent("Library/Caches/Edith")
            runtime = cache.appendingPathComponent("Runtime")
        case .linux:
            configuration = Self.baseDirectory(
                environment["XDG_CONFIG_HOME"],
                fallback: homeDirectory.appendingPathComponent(".config")
            ).appendingPathComponent("edith")
            data = Self.baseDirectory(
                environment["XDG_DATA_HOME"],
                fallback: homeDirectory.appendingPathComponent(".local/share")
            ).appendingPathComponent("edith")
            cache = Self.baseDirectory(
                environment["XDG_CACHE_HOME"],
                fallback: homeDirectory.appendingPathComponent(".cache")
            ).appendingPathComponent("edith")
            runtime = Self.baseDirectory(
                environment["XDG_RUNTIME_DIR"], fallback: cache.appendingPathComponent("runtime")
            ).appendingPathComponent("edith")
        }
    }

    public static var current: AppDirectories {
        AppDirectories(
            platform: .current,
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser,
            environment: ProcessInfo.processInfo.environment)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for directory in Set([configuration, data, cache, runtime]) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }

    private static func baseDirectory(_ value: String?, fallback: URL) -> URL {
        guard let value, value.hasPrefix("/") else { return fallback }
        return URL(fileURLWithPath: value).standardizedFileURL
    }
}
