import Darwin
import Foundation

public enum DatabaseRuntimeLockError: Error, Equatable, Sendable {
    case invalidRuntimeDirectory
    case unsafeRuntimeDirectory
    case unsafeLockFile
    case alreadyHeld
    case notHeld
    case unavailable
}

enum DatabaseRuntimeLockAcquisitionStage: Sendable {
    case runtimeDirectoryOpened
    case lockFileOpened
    case lockAcquired
}

public final class DatabaseRuntimeLock: @unchecked Sendable {
    private struct State {
        let runtimeDirectory: DatabaseBrokerRuntimeDirectory
        let lockDescriptor: Int32
    }

    private let stateLock = NSLock()
    private var state: State?

    private init(
        runtimeDirectory: DatabaseBrokerRuntimeDirectory,
        lockDescriptor: Int32
    ) {
        state = State(
            runtimeDirectory: runtimeDirectory,
            lockDescriptor: lockDescriptor)
    }

    public static func acquire(
        paths: DatabaseBrokerPaths = DatabaseBrokerPaths()
    ) throws -> DatabaseRuntimeLock {
        try acquire(paths: paths) { _ in }
    }

    static func acquire(
        paths: DatabaseBrokerPaths,
        observe: (DatabaseRuntimeLockAcquisitionStage) throws -> Void
    ) throws -> DatabaseRuntimeLock {
        let runtimeDirectory = try openRuntimeDirectory(paths: paths)
        var lockDescriptor: Int32?
        var ownsLock = false
        do {
            try observe(.runtimeDirectoryOpened)
            guard runtimeDirectory.revalidate() else {
                throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
            }

            let openedLock = try openLockFile(
                directoryDescriptor: runtimeDirectory.descriptor)
            lockDescriptor = openedLock
            try observe(.lockFileOpened)
            try validate(
                runtimeDirectory: runtimeDirectory,
                lockDescriptor: openedLock)

            guard flock(openedLock, LOCK_EX | LOCK_NB) == 0 else {
                let failure = errno
                if failure == EWOULDBLOCK || failure == EAGAIN {
                    throw DatabaseRuntimeLockError.alreadyHeld
                }
                throw DatabaseRuntimeLockError.unavailable
            }
            ownsLock = true
            try observe(.lockAcquired)
            try validate(
                runtimeDirectory: runtimeDirectory,
                lockDescriptor: openedLock)
            return DatabaseRuntimeLock(
                runtimeDirectory: runtimeDirectory,
                lockDescriptor: openedLock)
        } catch {
            if let lockDescriptor {
                if ownsLock {
                    _ = flock(lockDescriptor, LOCK_UN)
                }
                close(lockDescriptor)
            }
            runtimeDirectory.close()
            throw error
        }
    }

    func withRuntimeDirectoryDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard let state else {
            throw DatabaseRuntimeLockError.notHeld
        }
        try Self.validate(
            runtimeDirectory: state.runtimeDirectory,
            lockDescriptor: state.lockDescriptor)
        do {
            let result = try operation(state.runtimeDirectory.descriptor)
            try Self.validate(
                runtimeDirectory: state.runtimeDirectory,
                lockDescriptor: state.lockDescriptor)
            return result
        } catch {
            try Self.validate(
                runtimeDirectory: state.runtimeDirectory,
                lockDescriptor: state.lockDescriptor)
            throw error
        }
    }

    public func release() {
        let released = stateLock.withLock { () -> State? in
            defer { state = nil }
            return state
        }
        guard let released else { return }
        _ = flock(released.lockDescriptor, LOCK_UN)
        close(released.lockDescriptor)
        released.runtimeDirectory.close()
    }

    deinit {
        release()
    }

    private static func openRuntimeDirectory(
        paths: DatabaseBrokerPaths
    ) throws -> DatabaseBrokerRuntimeDirectory {
        do {
            return try paths.openRuntimeDirectory()
        } catch let error as DatabaseBrokerPathsError {
            switch error {
            case .invalidRuntimeDirectory:
                throw DatabaseRuntimeLockError.invalidRuntimeDirectory
            case .unsafeRuntimeDirectory:
                throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
            case .unavailable:
                throw DatabaseRuntimeLockError.unavailable
            case .invalidDataDirectory, .unsafeDataDirectory, .unsafeMetadataFile:
                throw DatabaseRuntimeLockError.unavailable
            }
        }
    }

    private static func openLockFile(
        directoryDescriptor: Int32
    ) throws -> Int32 {
        let flags = O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK
        var descriptor = openat(
            directoryDescriptor,
            DatabaseBrokerPaths.ownerLockFilename,
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
            descriptor = openat(
                directoryDescriptor,
                DatabaseBrokerPaths.ownerLockFilename,
                flags)
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

    private static func validate(
        runtimeDirectory: DatabaseBrokerRuntimeDirectory,
        lockDescriptor: Int32
    ) throws {
        guard runtimeDirectory.revalidate() else {
            throw DatabaseRuntimeLockError.unsafeRuntimeDirectory
        }
        guard
            validLockFile(lockDescriptor),
            pathReferencesLockFile(
                directoryDescriptor: runtimeDirectory.descriptor,
                descriptor: lockDescriptor)
        else {
            throw DatabaseRuntimeLockError.unsafeLockFile
        }
    }

    static func safeLockFileMetadata(
        _ metadata: stat,
        expectedUserID: uid_t = geteuid()
    ) -> Bool {
        metadata.st_mode & S_IFMT == S_IFREG
            && metadata.st_uid == expectedUserID
            && metadata.st_nlink == 1
            && metadata.st_mode & mode_t(0o7777) == mode_t(0o600)
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
        descriptor: Int32
    ) -> Bool {
        var pathMetadata = stat()
        var descriptorMetadata = stat()
        return fstatat(
            directoryDescriptor,
            DatabaseBrokerPaths.ownerLockFilename,
            &pathMetadata,
            AT_SYMLINK_NOFOLLOW) == 0
            && fstat(descriptor, &descriptorMetadata) == 0
            && safeLockFileMetadata(descriptorMetadata)
            && sameFile(pathMetadata, descriptorMetadata)
    }

    private static func sameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }
}
