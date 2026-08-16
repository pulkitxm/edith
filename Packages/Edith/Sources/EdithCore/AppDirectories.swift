import Foundation

public struct AppDirectories: Equatable, Sendable {
    public let configuration: URL
    public let data: URL
    public let cache: URL
    public let runtime: URL

    public init(
        homeDirectory: URL
    ) {
        configuration = homeDirectory.appendingPathComponent(
            "Library/Application Support/Edith")
        data = configuration
        cache = homeDirectory.appendingPathComponent("Library/Caches/Edith")
        runtime = cache.appendingPathComponent("Runtime")
    }

    public static var current: AppDirectories {
        AppDirectories(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser)
    }

    public func prepare(fileManager: FileManager = .default) throws {
        for directory in Set([configuration, data, cache, runtime]) {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        }
    }
}
