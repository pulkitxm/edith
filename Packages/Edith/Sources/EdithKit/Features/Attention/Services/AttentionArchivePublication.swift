import Darwin
import Foundation

public final class AttentionArchivePublication {
    private let parent: Int32
    private let staged: String
    private let name: String
    private let stagedURL: URL
    private var published = false
    private var replaced = false
    private var finished = false

    public init(source: URL, destination: URL) throws {
        let directory = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw AttentionArchiveError.unsafe }
        let temporary = ".attention-stage-\(UUID().uuidString)"
        let temporaryURL = directory.appendingPathComponent(temporary)
        do {
            try AttentionArchiveCopy.copy(from: source, to: temporaryURL)
            try FileManager.default.createDirectory(
                at: temporaryURL, withIntermediateDirectories: true)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            close(descriptor)
            throw error
        }
        parent = descriptor
        name = destination.lastPathComponent
        staged = temporary
        stagedURL = temporaryURL
    }

    deinit {
        if !finished { try? rollback() }
        close(parent)
    }

    public func publish() throws {
        guard !finished, !published else { return }
        try Task.checkCancellation()
        var metadata = stat()
        if fstatat(parent, name, &metadata, AT_SYMLINK_NOFOLLOW) == 0 {
            guard metadata.st_mode & S_IFMT == S_IFDIR else { throw AttentionArchiveError.unsafe }
            guard renameatx_np(parent, staged, parent, name, UInt32(RENAME_SWAP)) == 0 else {
                throw AttentionArchiveError.unsafe
            }
            replaced = true
        } else {
            guard errno == ENOENT,
                renameatx_np(parent, staged, parent, name, UInt32(RENAME_EXCL)) == 0
            else { throw AttentionArchiveError.unsafe }
        }
        published = true
    }

    public func finish() {
        finished = true
        try? FileManager.default.removeItem(at: stagedURL)
    }

    public func rollback() throws {
        guard !finished else { return }
        if published {
            let result =
                replaced
                ? renameatx_np(parent, staged, parent, name, UInt32(RENAME_SWAP))
                : renameatx_np(parent, name, parent, staged, UInt32(RENAME_EXCL))
            guard result == 0 else { throw AttentionArchiveError.unsafe }
            published = false
        }
        finish()
    }
}
