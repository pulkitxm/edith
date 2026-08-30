import Darwin
import Foundation

public enum DatabaseRuntimeLockError: Error, Equatable, Sendable {
    case invalidRuntimeDirectory
    case invalidLockFilename
    case unsafeRuntimeDirectory
    case unsafeLockFile
    case alreadyHeld
    case unavailable
}

public final class DatabaseRuntimeLock: @unchecked Sendable {
    public static let defaultFilename = "database-runtime.lock"
    public static let maximumFilenameBytes = 128

    private struct State {
        let descriptor: Int32
    }

    private struct OpenDirectory {
        let descriptor: Int32
        let metadata: stat
    }

    private let stateLock = NSLock()
    private var state: State?

    private init(descriptor: Int32) {
        state = State(descriptor: descriptor)
    }

    public static func acquire(
        runtimeDirectory: URL,
        filename: String = defaultFilename
    ) throws -> DatabaseRuntimeLock {
        guard validFilename(filename) else {
            throw DatabaseRuntimeLockError.invalidLockFilename
        }
        let directory = try openRuntimeDirectory(runtimeDirectory)
        defer { close(directory.descriptor) }
        let descriptor = try openLockFile(
            directoryDescriptor: directory.descriptor,
            filename: filename)
        var ownsLock = false
        do {
            guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno
                if failure == EWOULDBLOCK || failure == EAGAIN {
                    throw DatabaseRuntimeLockError.alreadyHeld
                }
                throw DatabaseRuntimeLockError.unavailable
            }
            ownsLock = true
            guard validLockFile(descriptor) else {
                throw DatabaseRuntimeLockError.unsafeLockFile
            }
            guard
                pathReferencesLockFile(
                    directoryDescriptor: directory.descriptor,
                    filename: filename,
                    descriptor: descriptor)
            else {
                throw DatabaseRuntimeLockError.unsafeLockFile
            }
            guard
                runtimeDirectoryStillReferences(
                    runtimeDirectory,
                    expected: directory.metadata),
                validRuntimeDirectory(directory.descriptor)
            else {
                throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
            }
            return DatabaseRuntimeLock(descriptor: descriptor)
        } catch {
            if ownsLock {
                _ = flock(descriptor, LOCK_UN)
            }
            close(descriptor)
            throw error
        }
    }

    public func release() {
        let released = stateLock.withLock { () -> State? in
            defer { state = nil }
            return state
        }
        guard let released else { return }
        _ = flock(released.descriptor, LOCK_UN)
        close(released.descriptor)
    }

    deinit {
        release()
    }

    private static func validFilename(_ filename: String) -> Bool {
        let bytes = filename.utf8
        guard
            !bytes.isEmpty,
            bytes.count <= maximumFilenameBytes,
            filename != ".",
            filename != ".."
        else {
            return false
        }
        return bytes.allSatisfy { byte in
            (UInt8(ascii: "a")...UInt8(ascii: "z")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
                || (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || byte == UInt8(ascii: ".")
                || byte == UInt8(ascii: "-")
                || byte == UInt8(ascii: "_")
        }
    }

    private static func openRuntimeDirectory(_ url: URL) throws -> OpenDirectory {
        guard validRuntimeDirectoryURL(url) else {
            throw DatabaseRuntimeLockError.invalidRuntimeDirectory
        }
        let path = url.path
        let creationResult = mkdir(path, mode_t(0o700))
        let created = creationResult == 0
        if !created, errno != EEXIST {
            if errno == ELOOP || errno == ENOTDIR {
                throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
            }
            throw DatabaseRuntimeLockError.unavailable
        }

        var pathMetadata = stat()
        guard lstat(path, &pathMetadata) == 0 else {
            throw DatabaseRuntimeLockError.unavailable
        }
        guard safeRuntimeDirectoryMetadata(pathMetadata, requireMode: !created) else {
            throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
        }

        let descriptor = open(
            path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR {
                throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
            }
            throw DatabaseRuntimeLockError.unavailable
        }
        do {
            var descriptorMetadata = stat()
            guard fstat(descriptor, &descriptorMetadata) == 0 else {
                throw DatabaseRuntimeLockError.unavailable
            }
            guard
                safeRuntimeDirectoryMetadata(descriptorMetadata, requireMode: !created),
                sameFile(pathMetadata, descriptorMetadata)
            else {
                throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
            }
            if created {
                guard fchmod(descriptor, mode_t(0o700)) == 0 else {
                    throw DatabaseRuntimeLockError.unavailable
                }
                guard
                    fstat(descriptor, &descriptorMetadata) == 0,
                    safeRuntimeDirectoryMetadata(descriptorMetadata, requireMode: true)
                else {
                    throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
                }
            }
            guard runtimeDirectoryStillReferences(url, expected: descriptorMetadata) else {
                throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
            }
            return OpenDirectory(descriptor: descriptor, metadata: descriptorMetadata)
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func openLockFile(
        directoryDescriptor: Int32,
        filename: String
    ) throws -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var descriptor = openat(
            directoryDescriptor,
            filename,
            flags | O_CREAT | O_EXCL,
            mode_t(0o600))
        let created = descriptor >= 0
        if descriptor < 0 {
            guard errno == EEXIST else {
                if errno == ELOOP || errno == EISDIR || errno == ENOTDIR {
                    throw DatabaseRuntimeLockError.unsafeLockFile
                }
                throw DatabaseRuntimeLockError.unavailable
            }
            descriptor = openat(directoryDescriptor, filename, flags)
            guard descriptor >= 0 else {
                throw DatabaseRuntimeLockError.unsafeLockFile
            }
        }
        do {
            guard validLockFile(descriptor, requireMode: !created) else {
                throw DatabaseRuntimeLockError.unsafeLockFile
            }
            if created {
                guard fchmod(descriptor, mode_t(0o600)) == 0 else {
                    throw DatabaseRuntimeLockError.unavailable
                }
                guard validLockFile(descriptor) else {
                    throw DatabaseRuntimeLockError.unsafeLockFile
                }
            }
            guard
                pathReferencesLockFile(
                    directoryDescriptor: directoryDescriptor,
                    filename: filename,
                    descriptor: descriptor)
            else {
                throw DatabaseRuntimeLockError.unsafeLockFile
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    private static func validRuntimeDirectoryURL(_ url: URL) -> Bool {
        guard
            url.isFileURL,
            url.host == nil || url.host?.isEmpty == true || url.host == "localhost",
            url.query == nil,
            url.fragment == nil
        else {
            return false
        }
        let path = url.path
        return path.hasPrefix("/") && !path.utf8.isEmpty && !path.utf8.contains(0)
    }

    private static func safeRuntimeDirectoryMetadata(
        _ metadata: stat,
        requireMode: Bool
    ) -> Bool {
        guard
            metadata.st_mode & S_IFMT == S_IFDIR,
            metadata.st_uid == geteuid()
        else {
            return false
        }
        return !requireMode || metadata.st_mode & mode_t(0o7777) == mode_t(0o700)
    }

    private static func validRuntimeDirectory(_ descriptor: Int32) -> Bool {
        var metadata = stat()
        return fstat(descriptor, &metadata) == 0
            && safeRuntimeDirectoryMetadata(metadata, requireMode: true)
    }

    private static func validLockFile(
        _ descriptor: Int32,
        requireMode: Bool = true
    ) -> Bool {
        var metadata = stat()
        guard
            fstat(descriptor, &metadata) == 0,
            metadata.st_mode & S_IFMT == S_IFREG,
            metadata.st_uid == geteuid(),
            metadata.st_nlink == 1
        else {
            return false
        }
        return !requireMode || metadata.st_mode & mode_t(0o7777) == mode_t(0o600)
    }

    private static func pathReferencesLockFile(
        directoryDescriptor: Int32,
        filename: String,
        descriptor: Int32
    ) -> Bool {
        var pathMetadata = stat()
        var descriptorMetadata = stat()
        return fstatat(
            directoryDescriptor,
            filename,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW) == 0
            && fstat(descriptor, &descriptorMetadata) == 0
            && descriptorMetadata.st_mode & S_IFMT == S_IFREG
            && descriptorMetadata.st_uid == geteuid()
            && descriptorMetadata.st_nlink == 1
            && descriptorMetadata.st_mode & mode_t(0o7777) == mode_t(0o600)
            && sameFile(pathMetadata, descriptorMetadata)
    }

    private static func runtimeDirectoryStillReferences(
        _ url: URL,
        expected: stat
    ) -> Bool {
        var metadata = stat()
        return lstat(url.path, &metadata) == 0
            && safeRuntimeDirectoryMetadata(metadata, requireMode: true)
            && sameFile(metadata, expected)
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
}
