import CryptoKit
import Darwin
import Foundation

struct UsageNativeFileLimits: Sendable {
    var files = 100_000
    var records = 2_000_000
    var bytes = 2_147_483_648
    var lineBytes = 33_554_432
    var documentBytes = 67_108_864
}

enum UsageNativeFileIO {
    static func privateDirectory(_ root: URL) throws {
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700])
        var status = stat()
        guard lstat(root.path, &status) == 0,
            status.st_mode & S_IFMT == S_IFDIR, status.st_uid == getuid(),
            status.st_mode & 0o077 == 0
        else { throw UsageNativeFailure.unsafePath }
    }

    static func files(under root: URL, extensions: Set<String>, limit: Int = 100_000) throws
        -> [URL]
    {
        try Task.checkCancellation()
        var status = stat()
        guard lstat(root.path, &status) == 0 else {
            if errno == ENOENT { return [] }
            throw UsageNativeFailure.unsafePath
        }
        guard status.st_mode & S_IFMT == S_IFDIR else { throw UsageNativeFailure.unsafePath }
        guard
            let iterator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [
                    .isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey,
                ],
                options: [.skipsPackageDescendants])
        else { return [] }
        var result: [URL] = []
        var inspected = 0
        for case let path as URL in iterator {
            try Task.checkCancellation()
            inspected += 1
            guard inspected <= limit * 8 else { throw UsageNativeFailure.capacity }
            var entry = stat()
            guard lstat(path.path, &entry) == 0 else {
                if errno == ENOENT { continue }
                throw UsageNativeFailure.unsafePath
            }
            if entry.st_mode & S_IFMT == S_IFLNK { iterator.skipDescendants(); continue }
            if entry.st_mode & S_IFMT == S_IFREG,
                extensions.contains(path.pathExtension.lowercased())
            {
                result.append(path)
                guard result.count <= limit else { throw UsageNativeFailure.capacity }
            }
        }
        return result.sorted { $0.path < $1.path }
    }

    static func read(_ path: URL, maximum: Int = 67_108_864) throws -> Data {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw UsageNativeFailure.unsafePath }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0, before.st_size <= maximum
        else { throw UsageNativeFailure.capacity }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == -1, errno == EINTR { continue }
            guard count >= 0 else { throw UsageNativeFailure.invalidInput("file") }
            if count == 0 { break }
            guard data.count + count <= maximum else { throw UsageNativeFailure.capacity }
            data.append(contentsOf: buffer.prefix(count))
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, unchanged(before, after), data.count == before.st_size
        else {
            throw UsageNativeFailure.invalidInput("changed file")
        }
        return data
    }

    static func optionalObject(_ path: URL, maximum: Int = 67_108_864) throws -> [String: Any]? {
        var status = stat()
        guard lstat(path.path, &status) == 0 else {
            if errno == ENOENT { return nil }
            throw UsageNativeFailure.unsafePath
        }
        return try UsageNativeJSON.object(read(path, maximum: maximum))
    }

    static func lines(
        _ path: URL, previousBytes: Int = 0,
        limits: UsageNativeFileLimits = .init(),
        consume: (Data, Int, Int) throws -> Void
    ) throws -> (Int, Int, Double, String, String) {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw UsageNativeFailure.unsafePath }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0, before.st_size <= limits.bytes
        else { throw UsageNativeFailure.capacity }
        var digest = SHA256(), prefix = SHA256()
        var buffer = [UInt8](repeating: 0, count: 65_536)
        var tail = Data(), offset = 0, position = 0, complete = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == -1, errno == EINTR { continue }
            guard count >= 0 else { throw UsageNativeFailure.invalidInput("file") }
            if count == 0 { break }
            let chunk = Data(buffer.prefix(count))
            digest.update(data: chunk)
            if position < previousBytes {
                prefix.update(data: chunk.prefix(min(count, previousBytes - position)))
            }
            position += count
            guard position <= limits.bytes else { throw UsageNativeFailure.capacity }
            tail.append(chunk)
            while let newline = tail.firstIndex(of: 10) {
                let end = tail.distance(from: tail.startIndex, to: newline) + 1
                let line = tail.prefix(end - 1)
                guard line.count <= limits.lineBytes else { throw UsageNativeFailure.capacity }
                try consume(Data(line), offset, offset + end)
                offset += end; complete = offset; tail.removeFirst(end)
            }
            guard tail.count <= limits.lineBytes else { throw UsageNativeFailure.capacity }
        }
        if !tail.isEmpty, (try? JSONSerialization.jsonObject(with: tail)) != nil {
            try consume(tail, offset, position); complete = position
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, unchanged(before, after), position == before.st_size
        else {
            throw UsageNativeFailure.invalidInput("changed file")
        }
        return (
            position, complete,
            Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1e9,
            digest.finalize().map { String(format: "%02x", $0) }.joined(),
            prefix.finalize().map { String(format: "%02x", $0) }.joined()
        )
    }

    static func unchanged(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
    }
}
