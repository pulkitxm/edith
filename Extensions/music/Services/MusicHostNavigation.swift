import EdithExtensionSupport
import Foundation

struct MusicHostNavigationRequest: Codable, Equatable, Sendable {
    var section: String
    var path: String?
}

@MainActor enum MusicHostNavigation {
    static var navigate: ((MusicHostNavigationRequest) async throws -> Void)?
    private(set) static var folderIntent: MusicUIFolderIntent?
    private static var revision: UInt64 = 0
    private static var generation: UInt64 = 0

    static func reset() {
        generation &+= 1; revision = 0; folderIntent = nil
    }

    static func open(section: String = "music", path: String? = nil) async throws {
        guard ["music", "downloads"].contains(section), let navigate else {
            throw ExtensionPeerError.rejected("Navigation to the owning app window is unavailable.")
        }
        if let path,
            path.hasPrefix("/") || path.split(separator: "/").contains("..") || path.contains("\0")
                || path.utf8.count > 4096
        {
            throw ExtensionPeerError.invalidRequest
        }
        let token = generation
        try await navigate(.init(section: section, path: path))
        try Task.checkCancellation()
        guard generation == token else { throw CancellationError() }
        if section == "music", let path {
            revision &+= 1
            folderIntent = .init(revision: revision, path: path)
        }
    }
}
