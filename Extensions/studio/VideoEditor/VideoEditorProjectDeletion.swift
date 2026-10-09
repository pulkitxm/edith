import Darwin
import EdithExtensionSupport
import EdithExtensionUI
import Foundation

extension VideoEditorService {
    public struct TrashReceipt: Codable, Sendable {
        public let version: Int
        public let path: String
        public let projectID: String
        public let trashedPath: String?
        public let revision: String
        public let written: Bool
    }

    public static func trashProject(_ url: URL, dryRun: Bool = false) async throws -> TrashReceipt {
        try await trashProject(url, dryRun: dryRun, registry: VideoProjectRegistry()) { source in
            var destination: NSURL?
            try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
            return destination as URL?
        }
    }

    static func trashProject(
        _ url: URL, dryRun: Bool = false, registry: VideoProjectRegistry,
        moveToTrash: (URL) throws -> URL?
    ) async throws -> TrashReceipt {
        try require(
            url.isFileURL && url.pathExtension == "openscreen",
            "Expected a local .openscreen project file.")
        var metadata = stat()
        try require(
            lstat(url.path, &metadata) == 0
                && metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            "Expected a regular project file, not a folder or symbolic link.")
        let source = VideoProjectRegistry.canonical(url)
        let lock = dryRun ? nil : try await VideoProjectFileAccess.transaction(source)
        defer { withExtendedLifetime(lock) {} }
        let snapshot = try readProject(source)
        let receipt = try VideoProjectFileAccess.publication(source) {
            try VideoProjectFileAccess.publication(registry.directory) {
                var current = stat()
                try require(
                    lstat(source.path, &current) == 0
                        && current.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
                    "Expected a regular project file, not a folder or symbolic link.")
                try registry.checkIdentity(snapshot.project, at: source)
                guard try snapshot.revision.fingerprint.matches(source) else {
                    throw Failure(
                        "project_changed", "The project changed before it could be trashed.")
                }
                let records = try registry.recordsForPath(source)
                try Task.checkCancellation()
                let trashed = dryRun ? nil : try moveToTrash(source)
                if !dryRun {
                    for record in records { try FileManager.default.removeItem(at: record) }
                }
                return TrashReceipt(
                    version: 1, path: source.path, projectID: snapshot.project.id,
                    trashedPath: trashed?.path, revision: snapshot.revision.fingerprint.hexDigest,
                    written: !dryRun)
            }
        }
        if !dryRun { IPC.post(IPC.Name.videoProjectLibraryChanged) }
        return receipt
    }
}
