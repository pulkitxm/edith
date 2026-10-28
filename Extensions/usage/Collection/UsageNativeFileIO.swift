import CryptoKit
import Darwin
import Foundation

struct UsageNativeFileLimits: Sendable {
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

    static func files(under root: URL, extensions: Set<String>) throws -> [URL] {
        try Task.checkCancellation()
        var status = stat()
        guard lstat(root.path, &status) == 0 else {
            if errno == ENOENT { return [] }
            throw UsageNativeFailure.unsafePath
        }
        if status.st_mode & S_IFMT == S_IFREG {
            return extensions.contains(root.pathExtension.lowercased()) ? [root] : []
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
        for case let path as URL in iterator {
            try Task.checkCancellation()
            var entry = stat()
            guard lstat(path.path, &entry) == 0 else {
                if errno == ENOENT { continue }
                throw UsageNativeFailure.unsafePath
            }
            if entry.st_mode & S_IFMT == S_IFLNK { iterator.skipDescendants(); continue }
            if entry.st_mode & S_IFMT == S_IFREG,
                (extensions.contains(path.pathExtension.lowercased())
                    || extensions.contains("jsonl")
                        && (path.lastPathComponent.contains(".jsonl.deleted.")
                            || path.lastPathComponent.contains(".jsonl.reset.")))
            {
                result.append(path)
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

    static let anchorBytes = 65_536

    static func anchor(_ descriptor: Int32, upTo end: Int) -> String? {
        func window(_ start: Int, _ count: Int) -> String? {
            var bytes = [UInt8](repeating: 0, count: count)
            var done = 0
            while done < count {
                let read = bytes.withUnsafeMutableBytes {
                    pread(descriptor, $0.baseAddress! + done, count - done, off_t(start + done))
                }
                if read == -1, errno == EINTR { continue }
                guard read > 0 else { return nil }
                done += read
            }
            return UsageNativeJSON.hash(Data(bytes))
        }
        guard end >= 0, let head = window(0, min(end, anchorBytes)),
            let tail = window(max(0, end - anchorBytes), min(end, anchorBytes))
        else { return nil }
        return head + ":" + tail
    }

    static func anchorMatches(_ path: URL, upTo end: Int, anchor expected: String) -> Bool {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & S_IFMT == S_IFREG,
            Int(status.st_size) >= end
        else { return false }
        return anchor(descriptor, upTo: end) == expected
    }

    static func lines(
        _ path: URL, previousBytes: Int = 0, startingAt start: Int = 0,
        limits: UsageNativeFileLimits = .init(),
        consume: (Data, Int, Int) throws -> Void
    ) throws -> (Int, Int, Double, String, String, Int) {
        let descriptor = open(path.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw UsageNativeFailure.unsafePath }
        defer { close(descriptor) }
        var before = stat()
        guard fstat(descriptor, &before) == 0, before.st_mode & S_IFMT == S_IFREG,
            before.st_size >= 0
        else { throw UsageNativeFailure.unsafePath }
        guard start <= before.st_size else { throw UsageNativeFailure.invalidInput("file") }
        if start > 0, lseek(descriptor, off_t(start), SEEK_SET) != off_t(start) {
            throw UsageNativeFailure.invalidInput("file")
        }
        var prefix = SHA256()
        var buffer = [UInt8](repeating: 0, count: 262_144)
        var carry = [UInt8](), offset = start, position = start, complete = start
        var oversized = false, oversizedLength = 0, skipped = 0
        while true {
            try Task.checkCancellation()
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count == -1, errno == EINTR { continue }
            guard count >= 0 else { throw UsageNativeFailure.invalidInput("file") }
            if count == 0 { break }
            try buffer.withUnsafeBytes { raw in
                let chunk = UnsafeRawBufferPointer(rebasing: raw[0..<count])
                if start == 0, position < previousBytes {
                    prefix.update(
                        bufferPointer: UnsafeRawBufferPointer(
                            rebasing: chunk[0..<min(count, previousBytes - position)]))
                }
                position += count
                var start = 0
                while start < count {
                    guard let found = memchr(chunk.baseAddress! + start, 10, count - start) else {
                        break
                    }
                    let stop = chunk.baseAddress!.distance(to: UnsafeRawPointer(found))
                    if oversized {
                        oversizedLength += stop - start
                        offset += oversizedLength + 1; complete = offset
                        oversized = false; oversizedLength = 0; skipped += 1
                    } else if carry.count + stop - start > limits.lineBytes {
                        offset += carry.count + stop - start + 1; complete = offset
                        carry.removeAll(keepingCapacity: true); skipped += 1
                    } else {
                        let length = carry.count + stop - start
                        var line = Data(capacity: length)
                        line.append(contentsOf: carry)
                        line.append(
                            contentsOf: UnsafeRawBufferPointer(rebasing: chunk[start..<stop]))
                        carry.removeAll(keepingCapacity: true)
                        try autoreleasepool { try consume(line, offset, offset + length + 1) }
                        offset += length + 1; complete = offset
                    }
                    start = stop + 1
                }
                if oversized {
                    oversizedLength += count - start
                } else if carry.count + count - start > limits.lineBytes {
                    oversized = true
                    oversizedLength = carry.count + count - start
                    carry.removeAll(keepingCapacity: true)
                } else {
                    carry.append(contentsOf: UnsafeRawBufferPointer(rebasing: chunk[start..<count]))
                }
            }
        }
        if !oversized, !carry.isEmpty,
            (try? JSONSerialization.jsonObject(with: Data(carry))) != nil
        {
            try consume(Data(carry), offset, position); complete = position
        }
        var after = stat()
        guard fstat(descriptor, &after) == 0, unchanged(before, after), position == before.st_size
        else {
            throw UsageNativeFailure.invalidInput("changed file")
        }
        guard let anchor = anchor(descriptor, upTo: complete) else {
            throw UsageNativeFailure.invalidInput("file")
        }
        return (
            position, complete,
            Double(before.st_mtimespec.tv_sec) + Double(before.st_mtimespec.tv_nsec) / 1e9,
            anchor,
            UsageNativeJSON.hex(prefix.finalize()), skipped
        )
    }

    static func unchanged(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_size == right.st_size
            && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec
            && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
    }
}
