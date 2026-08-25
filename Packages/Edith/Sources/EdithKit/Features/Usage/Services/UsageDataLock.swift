import Darwin
import Foundation

public enum UsageDataLockError: LocalizedError, Equatable, Sendable {
    case unavailable(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let path): "usage data lock unavailable at \(path)"
        }
    }
}

public final class UsageDataLock: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    public static func lockURL(dataDirectory: URL) -> URL {
        dataDirectory.appendingPathComponent("usage-data.lock")
    }

    public static func dataDirectory(containingMachinesDirectory directory: URL) -> URL {
        directory.lastPathComponent == "machines"
            ? directory.deletingLastPathComponent() : directory
    }

    public static func acquire(dataDirectory: URL) throws -> UsageDataLock {
        let manager = FileManager.default
        try manager.createDirectory(at: dataDirectory, withIntermediateDirectories: true)
        return try acquire(at: lockURL(dataDirectory: dataDirectory))
    }

    static func acquire(at url: URL, nonblocking: Bool = false) throws -> UsageDataLock {
        let descriptor = open(
            url.path, O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK,
            mode_t(S_IRUSR | S_IWUSR))
        guard descriptor >= 0 else {
            throw UsageDataLockError.unavailable(url.path)
        }
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            close(descriptor)
            throw UsageDataLockError.unavailable(url.path)
        }
        let operation = LOCK_EX | (nonblocking ? LOCK_NB : 0)
        while flock(descriptor, operation) != 0 {
            guard errno == EINTR else {
                close(descriptor)
                throw UsageDataLockError.unavailable(url.path)
            }
        }
        return UsageDataLock(descriptor: descriptor)
    }

    public static func withLock<T>(dataDirectory: URL, _ body: () throws -> T) throws -> T {
        let lock = try acquire(dataDirectory: dataDirectory)
        defer { lock.release() }
        return try body()
    }

    public func release() {
        let released = stateLock.withLock { () -> Int32 in
            guard descriptor >= 0 else { return -1 }
            let value = descriptor
            descriptor = -1
            return value
        }
        guard released >= 0 else { return }
        _ = flock(released, LOCK_UN)
        close(released)
    }

    deinit {
        release()
    }
}

public enum UsageDataFileError: LocalizedError, Equatable, Sendable {
    case unsafe(String)
    case oversized(String)

    public var errorDescription: String? {
        switch self {
        case .unsafe(let path): "unsafe usage data file at \(path)"
        case .oversized(let path): "usage data file is too large at \(path)"
        }
    }
}

public enum UsageDataFiles {
    public static let maximumMachineDocumentBytes = 64 * 1_024 * 1_024
    public static let maximumUsageDocumentBytes = 256 * 1_024 * 1_024
    public static let maximumLimitsHistoryBytes = 512 * 1_024 * 1_024

    public static func readRegularFile(
        at url: URL, maximumBytes: Int = maximumUsageDocumentBytes
    ) throws -> Data? {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0, errno == ENOENT { return nil }
        guard descriptor >= 0 else { throw UsageDataFileError.unsafe(url.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0, metadata.st_mode & S_IFMT == S_IFREG else {
            try? handle.close()
            throw UsageDataFileError.unsafe(url.path)
        }
        guard metadata.st_size >= 0, UInt64(metadata.st_size) <= UInt64(maximumBytes) else {
            try? handle.close()
            throw UsageDataFileError.oversized(url.path)
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
                throw UsageDataFileError.oversized(url.path)
            }
            return data
        } catch {
            try? handle.close()
            throw error
        }
    }

    public static func write(_ data: Data, to url: URL) throws {
        try UsageDurableFile.write(data, to: url)
    }

    public static func prepareWrite(_ data: Data, to url: URL) throws -> UsageDataPreparedWrite {
        try UsageDurableFile.prepare(data, to: url)
    }
}

public final class UsageDataPreparedWrite: @unchecked Sendable {
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
        try UsageDurableFile.synchronize(destination.deletingLastPathComponent())
    }

    deinit {
        let shouldRemove = lock.withLock { pending }
        if shouldRemove { try? FileManager.default.removeItem(at: temporary) }
    }
}

public enum UsageDataTransactionError: LocalizedError, Equatable, Sendable {
    case refreshBusy

    public var errorDescription: String? {
        switch self {
        case .refreshBusy: "usage refresh is busy"
        }
    }
}

public enum UsageDataTransaction {
    public static func withExclusiveAccess<T>(
        dataDirectory: URL, willAcquireDataLock: (() -> Void)? = nil,
        _ body: () throws -> T
    ) throws -> T {
        try FileManager.default.createDirectory(
            at: dataDirectory, withIntermediateDirectories: true)
        guard
            let transaction = try? UsageDataLock.acquire(
                at: dataDirectory.appendingPathComponent("usage-transaction.lock"),
                nonblocking: true)
        else { throw UsageDataTransactionError.refreshBusy }
        defer { transaction.release() }
        willAcquireDataLock?()
        return try UsageDataLock.withLock(dataDirectory: dataDirectory, body)
    }
}

enum UsageDurableFile {
    static func write(_ data: Data, to url: URL) throws {
        let prepared = try prepare(data, to: url)
        try prepared.publish()
        try prepared.finish()
    }

    static func prepare(_ data: Data, to url: URL) throws -> UsageDataPreparedWrite {
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
            return UsageDataPreparedWrite(temporary: temporary, destination: url)
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
            throw UsageDataFileError.unsafe(url.path)
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
