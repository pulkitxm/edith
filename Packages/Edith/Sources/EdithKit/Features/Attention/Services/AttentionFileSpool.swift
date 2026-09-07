import Darwin
import Foundation

public enum AttentionFileSpool {
    public static func drain(
        directory: URL, consume: (Data) throws -> Bool
    ) throws -> Int {
        let manager = FileManager.default
        guard manager.fileExists(atPath: directory.path) else { return 0 }
        let lock = directory.deletingLastPathComponent().appendingPathComponent(".lock")
        let descriptor = open(
            lock.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK, 0o600)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteNoPermission) }
        defer { close(descriptor) }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            throw CocoaError(.fileWriteNoPermission)
        }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            throw CocoaError(.fileLocking)
        }
        defer { _ = flock(descriptor, LOCK_UN) }
        let files = try manager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "jsonl" }.sorted { $0.path < $1.path }
        for file in files {
            try Task.checkCancellation()
            guard let data = try UsageDataFiles.readRegularFile(at: file, maximumBytes: 67_108_864)
            else {
                continue
            }
            if try consume(data) {
                try manager.removeItem(at: file)
            } else {
                try manager.moveItem(
                    at: file, to: file.appendingPathExtension("unreadable.\(UUID().uuidString)"))
            }
        }
        return files.count
    }
}
