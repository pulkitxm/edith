import Darwin
import Foundation

enum AccountQuotaCache {
    static let maximumBytes = 65_536
    static let fileName = ".account-limits-cache.json"

    static func read(directory: URL) throws -> Data? {
        try withRoot(directory) { root in
            let descriptor = openat(
                root, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
            if descriptor < 0, errno == ENOENT { return nil }
            guard descriptor >= 0 else { throw ClaudeLimitsReader.Failure.unavailable }
            defer { close(descriptor) }
            try validateFile(descriptor)
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0, metadata.st_size >= 0,
                metadata.st_size <= maximumBytes
            else { throw ClaudeLimitsReader.Failure.unavailable }
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while true {
                try Task.checkCancellation()
                let count = Darwin.read(
                    descriptor, &buffer, min(buffer.count, maximumBytes + 1 - data.count))
                if count < 0, errno == EINTR { continue }
                guard count >= 0 else { throw ClaudeLimitsReader.Failure.unavailable }
                if count == 0 { return data }
                data.append(contentsOf: buffer.prefix(count))
                guard data.count <= maximumBytes else {
                    throw ClaudeLimitsReader.Failure.unavailable
                }
            }
        }
    }

    static func write(_ data: Data, directory: URL) throws {
        guard data.count <= maximumBytes else { throw ClaudeLimitsReader.Failure.unavailable }
        try withRoot(directory) { root in
            try validateExisting(root)
            let temporary = ".quota-write-" + UUID().uuidString
            let descriptor = openat(
                root, temporary, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
            guard descriptor >= 0 else { throw ClaudeLimitsReader.Failure.unavailable }
            defer { close(descriptor); unlinkat(root, temporary, 0) }
            try validateFile(descriptor)
            try data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    try Task.checkCancellation()
                    let count = Darwin.write(
                        descriptor, bytes.baseAddress!.advanced(by: offset),
                        min(4096, bytes.count - offset))
                    if count < 0, errno == EINTR { continue }
                    guard count > 0 else { throw ClaudeLimitsReader.Failure.unavailable }
                    offset += count
                }
            }
            guard fsync(descriptor) == 0 else { throw ClaudeLimitsReader.Failure.unavailable }
            try Task.checkCancellation()
            try validateExisting(root)
            guard renameat(root, temporary, root, fileName) == 0 else {
                throw ClaudeLimitsReader.Failure.unavailable
            }
        }
    }

    private static func withRoot<T>(_ directory: URL, _ body: (Int32) throws -> T) throws -> T {
        let path = directory.path
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard directory.isFileURL, path.hasPrefix("/"), path.utf8.count <= 8192,
            !path.utf8.contains(0), parts.count > 1,
            parts.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else { throw ClaudeLimitsReader.Failure.unavailable }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else { throw ClaudeLimitsReader.Failure.unavailable }
        defer { close(descriptor) }
        for name in parts.dropFirst() {
            try Task.checkCancellation()
            let next = openat(
                descriptor, String(name), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw ClaudeLimitsReader.Failure.unavailable }
            close(descriptor)
            descriptor = next
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & S_IFMT == S_IFDIR, metadata.st_mode & 0o777 == 0o700
        else { throw ClaudeLimitsReader.Failure.unavailable }
        return try body(descriptor)
    }

    private static func validateExisting(_ root: Int32) throws {
        let descriptor = openat(root, fileName, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return }
        guard descriptor >= 0 else { throw ClaudeLimitsReader.Failure.unavailable }
        defer { close(descriptor) }
        try validateFile(descriptor)
    }

    private static func validateFile(_ descriptor: Int32) throws {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_uid == getuid(),
            metadata.st_mode & S_IFMT == S_IFREG, metadata.st_mode & 0o777 == 0o600,
            metadata.st_nlink == 1, metadata.st_size >= 0, metadata.st_size <= maximumBytes
        else { throw ClaudeLimitsReader.Failure.unavailable }
    }
}
