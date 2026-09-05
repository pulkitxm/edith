import Foundation

public struct AppDirectories: Equatable, Sendable {
    public let configuration: URL
    public let data: URL
    public let cache: URL
    public let runtime: URL
    public let logs: URL

    public init(
        homeDirectory: URL
    ) {
        configuration = homeDirectory.appendingPathComponent(
            "Library/Application Support/Edith")
        data = configuration
        cache = homeDirectory.appendingPathComponent("Library/Caches/Edith")
        runtime = cache.appendingPathComponent("Runtime")
        logs = homeDirectory.appendingPathComponent("Library/Logs/Edith")
    }

    public static var current: AppDirectories {
        let directory =
            ProcessInfo.processInfo.environment["EDITH_DATABASE_HOME"].map {
                URL(fileURLWithPath: $0, isDirectory: true)
            } ?? FileManager.default.homeDirectoryForCurrentUser
        return AppDirectories(homeDirectory: directory)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for directory in Set([configuration, data, cache, runtime]) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
