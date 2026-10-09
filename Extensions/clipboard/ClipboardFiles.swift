import Darwin
import Foundation

public enum ClipboardFileError: LocalizedError, Equatable, Sendable {
    case unsafe(String)
    case oversized(String)

    public var errorDescription: String? {
        switch self {
        case .unsafe(let path): "unsafe clipboard file at \(path)"
        case .oversized(let path): "clipboard file is too large at \(path)"
        }
    }
}

public enum ClipboardFiles {
    public static let maximumDocumentBytes = 16 * 1_024 * 1_024

    public static func readRegularFile(
        at url: URL, maximumBytes: Int = maximumDocumentBytes
    ) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw ClipboardFileError.unsafe(url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw ClipboardFileError.unsafe(url.path)
        }
        guard metadata.st_size >= 0, UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            try? handle.close()
            throw ClipboardFileError.oversized(url.path)
        }
        do {
            var data = Data()
            while data.count <= maximumBytes {
                let remaining = maximumBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(64 * 1_024, remaining)),
                    !chunk.isEmpty
                else { break }
                data.append(chunk)
            }
            try handle.close()
            guard data.count <= maximumBytes else {
                throw ClipboardFileError.oversized(url.path)
            }
            return data
        } catch {
            try? handle.close()
            throw error
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        try ClipboardDurableFile.write(data, to: url)
    }

    public static func prepareWrite(_ data: Data, to url: URL) throws -> ClipboardPreparedWrite {
        try ClipboardDurableFile.prepare(data, to: url)
    }
}

public final class ClipboardPreparedWrite: @unchecked Sendable {
    private let lock = NSLock()
    private let temporary: URL
    private let destination: URL
    private var pending = true

    fileprivate init(temporary: URL, destination: URL) {
        self.temporary = temporary
        self.destination = destination
    }

    public func publish() throws {
        try lock.withLock {
            guard pending else { return }
            guard Darwin.rename(temporary.path, destination.path) == 0 else {
                throw CocoaError(.fileWriteUnknown)
            }
            pending = false
        }
    }

    public func finish() throws {
        try ClipboardDurableFile.synchronize(destination.deletingLastPathComponent())
    }

    deinit {
        let shouldRemove = lock.withLock { pending }
        if shouldRemove { try? FileManager.default.removeItem(at: temporary) }
    }
}

enum ClipboardDurableFile {
    static func write(_ data: Data, to url: URL) throws {
        let prepared = try prepare(data, to: url)
        try prepared.publish()
        try prepared.finish()
    }

    static func prepare(_ data: Data, to url: URL) throws -> ClipboardPreparedWrite {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let temporary = directory.appendingPathComponent(
            ".\(url.lastPathComponent).\(UUID().uuidString).tmp")
        let descriptor = open(
            temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            return ClipboardPreparedWrite(temporary: temporary, destination: url)
        } catch {
            try? handle.close()
            try? manager.removeItem(at: temporary)
            throw error
        }
    }

    static func append(_ data: Data, to url: URL) throws {
        let manager = FileManager.default
        let directory = url.deletingLastPathComponent()
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let descriptor = open(
            url.path, O_WRONLY | O_CREAT | O_APPEND | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw ClipboardFileError.unsafe(url.path)
        }
        do {
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
            try synchronize(directory)
        } catch {
            try? handle.close()
            throw error
        }
    }

    static func synchronize(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw CocoaError(.fileWriteUnknown) }
    }
}
