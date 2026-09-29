import CryptoKit
import Darwin
import Foundation

enum VideoProjectFileAccess {
    final class RevisionState {
        var value: Revision

        init(_ data: Data) { value = Revision(data) }
    }

    struct Revision {
        let byteCount: Int
        let digest: SHA256.Digest

        init(_ data: Data) {
            byteCount = data.count
            digest = SHA256.hash(data: data)
        }

        func matches(_ url: URL) throws -> Bool {
            var metadata = stat()
            guard stat(url.path, &metadata) == 0, metadata.st_size == byteCount else {
                return false
            }
            return SHA256.hash(data: try Data(contentsOf: url)) == digest
        }
    }

    final class Lock {
        private let descriptor: Int32

        init(_ descriptor: Int32) { self.descriptor = descriptor }

        deinit {
            flock(descriptor, LOCK_UN)
            close(descriptor)
        }
    }

    static func transaction(_ url: URL) async throws -> Lock {
        let deadline = ContinuousClock.now + .seconds(120)
        while true {
            try Task.checkCancellation()
            if let lock = try acquire(url, purpose: "transaction") { return lock }
            guard ContinuousClock.now < deadline else {
                throw VideoEditorService.Failure(
                    "project_busy", "Another edit transaction is still using this project.")
            }
            try await Task.sleep(for: .milliseconds(25))
        }
    }

    static func publication<T>(_ url: URL, _ body: () throws -> T) throws -> T {
        guard let lock = try acquire(url, purpose: "publication") else {
            throw VideoEditorService.Failure(
                "project_busy", "Another writer is saving this project. Retry the save.")
        }
        return try withExtendedLifetime(lock, body)
    }

    static func identity(_ url: URL) -> String {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let sensitive = try? canonical.deletingLastPathComponent().resourceValues(forKeys: [
            .volumeSupportsCaseSensitiveNamesKey
        ]).volumeSupportsCaseSensitiveNames
        let path = canonical.path.precomposedStringWithCanonicalMapping
        return sensitive == false ? path.lowercased() : path
    }

    private static func acquire(_ url: URL, purpose: String) throws -> Lock? {
        let canonical = url.resolvingSymlinksInPath().standardizedFileURL
        let hash = SHA256.hash(data: Data(identity(canonical).utf8)).map {
            String(format: "%02x", $0)
        }.joined()
        let base =
            ProcessInfo.processInfo.environment["EDITH_TEST_RUNTIME_ROOT"].map {
                URL(fileURLWithPath: $0)
            } ?? FileManager.default.temporaryDirectory
        let directory = base.appendingPathComponent("edith-video-project-locks", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        var directoryInfo = stat()
        guard lstat(directory.path, &directoryInfo) == 0,
            directoryInfo.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR),
            directoryInfo.st_uid == getuid(),
            directoryInfo.st_mode & 0o077 == 0
        else {
            throw VideoEditorService.Failure(
                "invalid_lock", "The project lock directory must be private and owned by this user."
            )
        }
        let path = directory.appendingPathComponent("\(hash).\(purpose).lock")
        let descriptor = open(
            path.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
            info.st_uid == getuid()
        else {
            close(descriptor)
            throw VideoEditorService.Failure(
                "invalid_lock", "The project lock must be a regular file owned by this user.")
        }
        if flock(descriptor, LOCK_EX | LOCK_NB) == 0 { return Lock(descriptor) }
        let code = errno
        close(descriptor)
        if code == EWOULDBLOCK { return nil }
        throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
    }
}

extension VideoProject {
    mutating func encodedForSaving() throws -> Data {
        try validateVideoSettings()
        var project = root["project"] as? [String: Any] ?? [:]
        project["updatedAt"] = ISO8601DateFormatter().string(from: Date())
        root["project"] = project
        return try JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys])
    }
}
