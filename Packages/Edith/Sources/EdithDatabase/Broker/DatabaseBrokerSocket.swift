import Darwin
import Dispatch
import Foundation

enum DatabaseBrokerSocketError: Error, Equatable, Sendable {
    case invalidSocketPath
    case invalidTimeout
    case unsafeSocketEntry
    case listenerAlreadyRunning
    case existingSocketUnavailable
    case socketNotFound
    case connectionRefused
    case connectionTimedOut
    case notOpen
    case unavailable
}

struct DatabaseBrokerSocketIdentity: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
}

enum DatabaseBrokerSocketListenerStage: Equatable, Sendable {
    case existingSocketInspected(DatabaseBrokerSocketIdentity)
    case staleSocketConfirmed(DatabaseBrokerSocketIdentity)
    case staleSocketRemoved(DatabaseBrokerSocketIdentity)
    case socketBound(DatabaseBrokerSocketIdentity)
    case socketPermissionsSet(DatabaseBrokerSocketIdentity)
    case listening(DatabaseBrokerSocketIdentity)
}

struct DatabaseBrokerSocketAddress {
    static let maximumPathBytes =
        MemoryLayout<sockaddr_un>.size
        - MemoryLayout<sa_family_t>.size
        - MemoryLayout<UInt8>.size
        - 1

    private var address: sockaddr_un
    private let length: socklen_t

    init(path: String) throws {
        let pathBytes = Array(path.utf8)
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard
            path.hasPrefix("/"),
            !pathBytes.isEmpty,
            !pathBytes.contains(0),
            pathBytes.count < capacity
        else {
            throw DatabaseBrokerSocketError.invalidSocketPath
        }
        let addressLength =
            MemoryLayout<sockaddr_un>.size - capacity
            + pathBytes.count + 1
        guard let sunLength = UInt8(exactly: addressLength) else {
            throw DatabaseBrokerSocketError.invalidSocketPath
        }
        address.sun_len = sunLength
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: pathBytes)
            buffer[pathBytes.count] = 0
        }
        self.address = address
        length = socklen_t(addressLength)
    }

    func withSockAddr<Result>(
        _ operation: (UnsafePointer<sockaddr>, socklen_t) throws -> Result
    ) rethrows -> Result {
        var address = address
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try operation($0, length)
            }
        }
    }
}

final class DatabaseBrokerSocketConnection: @unchecked Sendable {
    static let defaultTimeoutMilliseconds: Int32 = 3_000
    static let maximumTimeoutMilliseconds: Int32 = 60_000

    private let descriptorState: DatabaseBrokerManagedSocketDescriptor

    fileprivate init(descriptor: Int32) {
        descriptorState = DatabaseBrokerManagedSocketDescriptor(
            descriptor: descriptor)
    }

    static func connect(
        paths: DatabaseBrokerPaths = DatabaseBrokerPaths(),
        timeoutMilliseconds: Int32 = defaultTimeoutMilliseconds
    ) throws -> DatabaseBrokerSocketConnection {
        try connect(
            paths: paths,
            timeoutMilliseconds: timeoutMilliseconds
        ) { descriptor, address in
            address.withSockAddr {
                Darwin.connect(descriptor, $0, $1)
            }
        }
    }

    static func connect(
        paths: DatabaseBrokerPaths,
        timeoutMilliseconds: Int32 = defaultTimeoutMilliseconds,
        performConnect: (Int32, DatabaseBrokerSocketAddress) -> Int32
    ) throws -> DatabaseBrokerSocketConnection {
        let address = try DatabaseBrokerSocketAddress(path: paths.socketFile.path)
        let outcome = try DatabaseBrokerSocketSystem.connect(
            address: address,
            timeoutMilliseconds: timeoutMilliseconds,
            performConnect: performConnect)
        switch outcome {
        case .connected(let descriptor):
            return DatabaseBrokerSocketConnection(descriptor: descriptor)
        case .notFound:
            throw DatabaseBrokerSocketError.socketNotFound
        case .refused:
            throw DatabaseBrokerSocketError.connectionRefused
        case .timedOut:
            throw DatabaseBrokerSocketError.connectionTimedOut
        case .failed:
            throw DatabaseBrokerSocketError.unavailable
        }
    }

    func withSocketDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        try descriptorState.withDescriptor(operation)
    }

    func close() {
        descriptorState.close()
    }

    deinit {
        close()
    }
}

final class DatabaseBrokerSocketListener: @unchecked Sendable {
    static let backlog: Int32 = 64
    static let staleProbeTimeoutMilliseconds: Int32 = 250

    let identity: DatabaseBrokerSocketIdentity

    private let runtimeLock: DatabaseRuntimeLock
    private let descriptorState: DatabaseBrokerManagedSocketDescriptor
    private let snapshot: DatabaseBrokerSocketSnapshot

    private init(
        descriptor: Int32,
        snapshot: DatabaseBrokerSocketSnapshot,
        runtimeLock: DatabaseRuntimeLock
    ) {
        descriptorState = DatabaseBrokerManagedSocketDescriptor(
            descriptor: descriptor)
        self.snapshot = snapshot
        self.runtimeLock = runtimeLock
        identity = snapshot.identity
    }

    static func listen(
        paths: DatabaseBrokerPaths = DatabaseBrokerPaths()
    ) throws -> DatabaseBrokerSocketListener {
        try listen(paths: paths) { _ in }
    }

    static func listen(
        paths: DatabaseBrokerPaths,
        observe: (DatabaseBrokerSocketListenerStage) throws -> Void
    ) throws -> DatabaseBrokerSocketListener {
        let address = try DatabaseBrokerSocketAddress(path: paths.socketFile.path)
        let runtimeLock: DatabaseRuntimeLock
        do {
            runtimeLock = try DatabaseRuntimeLock.acquire(paths: paths)
        } catch DatabaseRuntimeLockError.alreadyHeld {
            throw DatabaseBrokerSocketError.listenerAlreadyRunning
        }
        var pendingListener: DatabaseBrokerPendingListener?
        do {
            let listener = try runtimeLock.withRuntimeDirectoryDescriptor {
                directoryDescriptor in
                let listener = try createListener(
                    address: address,
                    runtimeDirectory: paths.runtimeDirectory,
                    directoryDescriptor: directoryDescriptor,
                    observe: observe)
                pendingListener = listener
                return listener
            }
            pendingListener = nil
            return DatabaseBrokerSocketListener(
                descriptor: listener.descriptor,
                snapshot: listener.snapshot,
                runtimeLock: runtimeLock)
        } catch {
            if let pendingListener {
                _ = shutdown(pendingListener.descriptor, SHUT_RDWR)
                Darwin.close(pendingListener.descriptor)
                try? runtimeLock.withRuntimeDirectoryDescriptor { directoryDescriptor in
                    unlinkIfUnchanged(
                        directoryDescriptor: directoryDescriptor,
                        snapshot: pendingListener.snapshot)
                }
            }
            runtimeLock.release()
            throw error
        }
    }

    func accept() throws -> DatabaseBrokerSocketConnection? {
        try accept { descriptor in
            Darwin.accept(descriptor, nil, nil)
        }
    }

    func accept(
        performAccept: (Int32) -> Int32
    ) throws -> DatabaseBrokerSocketConnection? {
        try withSocketDescriptor { listenerDescriptor in
            var acceptedDescriptor = performAccept(listenerDescriptor)
            while acceptedDescriptor < 0, errno == EINTR {
                acceptedDescriptor = performAccept(listenerDescriptor)
            }
            guard acceptedDescriptor >= 0 else {
                if errno == EAGAIN || errno == EWOULDBLOCK {
                    return nil
                }
                throw DatabaseBrokerSocketError.unavailable
            }
            do {
                try DatabaseBrokerSocketSystem.configure(
                    descriptor: acceptedDescriptor)
                return DatabaseBrokerSocketConnection(
                    descriptor: acceptedDescriptor)
            } catch {
                Darwin.close(acceptedDescriptor)
                throw error
            }
        }
    }

    func withSocketDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        try descriptorState.withDescriptor(operation)
    }

    func close() {
        descriptorState.close { [runtimeLock, snapshot] in
            try? runtimeLock.withRuntimeDirectoryDescriptor { directoryDescriptor in
                Self.unlinkIfUnchanged(
                    directoryDescriptor: directoryDescriptor,
                    snapshot: snapshot)
            }
            runtimeLock.release()
        }
    }

    deinit {
        close()
    }

    static func safeSocketMetadata(
        _ metadata: stat,
        expectedUserID: uid_t = geteuid()
    ) -> Bool {
        metadata.st_mode & S_IFMT == S_IFSOCK
            && metadata.st_uid == expectedUserID
            && metadata.st_nlink == 1
            && metadata.st_mode & mode_t(0o7777) == mode_t(0o600)
    }

    private static func createListener(
        address: DatabaseBrokerSocketAddress,
        runtimeDirectory: URL,
        directoryDescriptor: Int32,
        observe: (DatabaseBrokerSocketListenerStage) throws -> Void
    ) throws -> DatabaseBrokerPendingListener {
        try removeStaleSocketIfPresent(
            address: address,
            directoryDescriptor: directoryDescriptor,
            observe: observe)
        let descriptor = try DatabaseBrokerSocketSystem.makeDescriptor()
        var cleanupEntry: DatabaseBrokerSocketEntry?
        do {
            let temporaryFilename = try availableTemporaryFilename(
                directoryDescriptor: directoryDescriptor)
            let temporaryPath =
                runtimeDirectory
                .appendingPathComponent(temporaryFilename)
                .path
            let temporaryAddress = try DatabaseBrokerSocketAddress(
                path: temporaryPath)
            guard
                temporaryAddress.withSockAddr({
                    bind(descriptor, $0, $1)
                }) == 0
            else {
                throw DatabaseBrokerSocketError.unsafeSocketEntry
            }

            guard
                let boundSnapshot = try socketSnapshot(
                    directoryDescriptor: directoryDescriptor,
                    filename: temporaryFilename),
                boundSnapshot.isOwnedSocket
            else {
                throw DatabaseBrokerSocketError.unsafeSocketEntry
            }
            cleanupEntry = DatabaseBrokerSocketEntry(
                filename: temporaryFilename,
                snapshot: boundSnapshot)
            try requireUnchanged(
                directoryDescriptor: directoryDescriptor,
                filename: temporaryFilename,
                snapshot: boundSnapshot)

            guard
                fchmodat(
                    directoryDescriptor,
                    temporaryFilename,
                    mode_t(0o600),
                    AT_SYMLINK_NOFOLLOW) == 0
            else {
                throw DatabaseBrokerSocketError.unavailable
            }
            guard
                let securedSnapshot = try socketSnapshot(
                    directoryDescriptor: directoryDescriptor,
                    filename: temporaryFilename),
                securedSnapshot.identity == boundSnapshot.identity
            else {
                throw DatabaseBrokerSocketError.unsafeSocketEntry
            }
            cleanupEntry = DatabaseBrokerSocketEntry(
                filename: temporaryFilename,
                snapshot: securedSnapshot)
            guard securedSnapshot.isSafe else {
                throw DatabaseBrokerSocketError.unsafeSocketEntry
            }
            try observe(.socketPermissionsSet(securedSnapshot.identity))
            try requireUnchanged(
                directoryDescriptor: directoryDescriptor,
                filename: temporaryFilename,
                snapshot: securedSnapshot)

            guard
                renameatx_np(
                    directoryDescriptor,
                    temporaryFilename,
                    directoryDescriptor,
                    DatabaseBrokerPaths.socketFilename,
                    UInt32(RENAME_EXCL)) == 0
            else {
                throw DatabaseBrokerSocketError.unsafeSocketEntry
            }
            cleanupEntry = DatabaseBrokerSocketEntry(
                filename: DatabaseBrokerPaths.socketFilename,
                snapshot: securedSnapshot)
            try observe(.socketBound(securedSnapshot.identity))
            try requireUnchanged(
                directoryDescriptor: directoryDescriptor,
                snapshot: securedSnapshot)

            guard Darwin.listen(descriptor, backlog) == 0 else {
                throw DatabaseBrokerSocketError.unavailable
            }
            try observe(.listening(securedSnapshot.identity))
            try requireUnchanged(
                directoryDescriptor: directoryDescriptor,
                snapshot: securedSnapshot)
            return DatabaseBrokerPendingListener(
                descriptor: descriptor,
                snapshot: securedSnapshot)
        } catch {
            _ = shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
            if let cleanupEntry {
                unlinkIfUnchanged(
                    directoryDescriptor: directoryDescriptor,
                    filename: cleanupEntry.filename,
                    snapshot: cleanupEntry.snapshot)
            }
            throw error
        }
    }

    private static func removeStaleSocketIfPresent(
        address: DatabaseBrokerSocketAddress,
        directoryDescriptor: Int32,
        observe: (DatabaseBrokerSocketListenerStage) throws -> Void
    ) throws {
        guard
            let existingSnapshot = try socketSnapshot(
                directoryDescriptor: directoryDescriptor)
        else {
            return
        }
        guard existingSnapshot.isSafe else {
            throw DatabaseBrokerSocketError.unsafeSocketEntry
        }
        try observe(.existingSocketInspected(existingSnapshot.identity))
        let outcome = try DatabaseBrokerSocketSystem.connect(
            address: address,
            timeoutMilliseconds: staleProbeTimeoutMilliseconds)
        if case .connected(let descriptor) = outcome {
            _ = shutdown(descriptor, SHUT_RDWR)
            Darwin.close(descriptor)
        }
        try requireUnchanged(
            directoryDescriptor: directoryDescriptor,
            snapshot: existingSnapshot)
        switch outcome {
        case .connected:
            throw DatabaseBrokerSocketError.listenerAlreadyRunning
        case .refused:
            try observe(.staleSocketConfirmed(existingSnapshot.identity))
            try requireUnchanged(
                directoryDescriptor: directoryDescriptor,
                snapshot: existingSnapshot)
            guard
                unlinkat(
                    directoryDescriptor,
                    DatabaseBrokerPaths.socketFilename,
                    0) == 0
            else {
                throw DatabaseBrokerSocketError.unavailable
            }
            try observe(.staleSocketRemoved(existingSnapshot.identity))
        case .notFound, .timedOut, .failed:
            throw DatabaseBrokerSocketError.existingSocketUnavailable
        }
    }

    private static func socketSnapshot(
        directoryDescriptor: Int32,
        filename: String = DatabaseBrokerPaths.socketFilename
    ) throws -> DatabaseBrokerSocketSnapshot? {
        var metadata = stat()
        guard
            fstatat(
                directoryDescriptor,
                filename,
                &metadata,
                AT_SYMLINK_NOFOLLOW) == 0
        else {
            if errno == ENOENT {
                return nil
            }
            throw DatabaseBrokerSocketError.unsafeSocketEntry
        }
        return DatabaseBrokerSocketSnapshot(metadata: metadata)
    }

    private static func requireUnchanged(
        directoryDescriptor: Int32,
        filename: String = DatabaseBrokerPaths.socketFilename,
        snapshot: DatabaseBrokerSocketSnapshot
    ) throws {
        guard
            let current = try socketSnapshot(
                directoryDescriptor: directoryDescriptor,
                filename: filename),
            current == snapshot,
            current.isSafe || snapshot.isOwnedSocket
        else {
            throw DatabaseBrokerSocketError.unsafeSocketEntry
        }
    }

    private static func unlinkIfUnchanged(
        directoryDescriptor: Int32,
        filename: String = DatabaseBrokerPaths.socketFilename,
        snapshot: DatabaseBrokerSocketSnapshot
    ) {
        guard
            let current = try? socketSnapshot(
                directoryDescriptor: directoryDescriptor,
                filename: filename),
            current == snapshot
        else {
            return
        }
        _ = unlinkat(
            directoryDescriptor,
            filename,
            0)
    }

    private static func availableTemporaryFilename(
        directoryDescriptor: Int32
    ) throws -> String {
        let alphabet = Array("0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz-_")
        for _ in 0..<16 {
            let suffix = String(
                (0..<9).map { _ in
                    alphabet[Int(arc4random_uniform(UInt32(alphabet.count)))]
                })
            let filename = ".s\(suffix)"
            if try socketSnapshot(
                directoryDescriptor: directoryDescriptor,
                filename: filename) == nil
            {
                return filename
            }
        }
        throw DatabaseBrokerSocketError.unavailable
    }
}

private final class DatabaseBrokerManagedSocketDescriptor: @unchecked Sendable {
    private let stateLock = NSLock()
    private var descriptor: Int32
    private var borrowCount = 0
    private var isClosing = false
    private var closeHandler: (() -> Void)?

    init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    func withDescriptor<Result>(
        _ operation: (Int32) throws -> Result
    ) throws -> Result {
        let borrowedDescriptor = try stateLock.withLock { () throws -> Int32 in
            guard descriptor >= 0, !isClosing else {
                throw DatabaseBrokerSocketError.notOpen
            }
            borrowCount += 1
            return descriptor
        }
        defer { finishBorrow() }
        return try operation(borrowedDescriptor)
    }

    func close(_ handler: (() -> Void)? = nil) {
        var closedDescriptor = Int32(-1)
        var completedHandler: (() -> Void)?
        stateLock.lock()
        if !isClosing, descriptor >= 0 {
            isClosing = true
            closeHandler = handler
            _ = shutdown(descriptor, SHUT_RDWR)
            if borrowCount == 0 {
                closedDescriptor = descriptor
                descriptor = -1
                completedHandler = closeHandler
                closeHandler = nil
            }
        }
        stateLock.unlock()
        if closedDescriptor >= 0 {
            Darwin.close(closedDescriptor)
            completedHandler?()
        }
    }

    private func finishBorrow() {
        var closedDescriptor = Int32(-1)
        var completedHandler: (() -> Void)?
        stateLock.lock()
        borrowCount -= 1
        if isClosing, borrowCount == 0, descriptor >= 0 {
            closedDescriptor = descriptor
            descriptor = -1
            completedHandler = closeHandler
            closeHandler = nil
        }
        stateLock.unlock()
        if closedDescriptor >= 0 {
            Darwin.close(closedDescriptor)
            completedHandler?()
        }
    }

    deinit {
        close()
    }
}

private struct DatabaseBrokerPendingListener {
    let descriptor: Int32
    let snapshot: DatabaseBrokerSocketSnapshot
}

private struct DatabaseBrokerSocketEntry {
    let filename: String
    let snapshot: DatabaseBrokerSocketSnapshot
}

private struct DatabaseBrokerSocketSnapshot: Equatable {
    let identity: DatabaseBrokerSocketIdentity
    let fileType: mode_t
    let permissions: mode_t
    let userIdentifier: uid_t
    let linkCount: nlink_t

    init(metadata: stat) {
        identity = DatabaseBrokerSocketIdentity(
            device: metadata.st_dev,
            inode: metadata.st_ino)
        fileType = metadata.st_mode & S_IFMT
        permissions = metadata.st_mode & mode_t(0o7777)
        userIdentifier = metadata.st_uid
        linkCount = metadata.st_nlink
    }

    var isOwnedSocket: Bool {
        fileType == S_IFSOCK
            && userIdentifier == geteuid()
            && linkCount == 1
    }

    var isSafe: Bool {
        isOwnedSocket && permissions == mode_t(0o600)
    }
}

private enum DatabaseBrokerSocketConnectOutcome {
    case connected(Int32)
    case notFound
    case refused
    case timedOut
    case failed(Int32)
}

private enum DatabaseBrokerSocketSystem {
    static func makeDescriptor() throws -> Int32 {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DatabaseBrokerSocketError.unavailable
        }
        do {
            try configure(descriptor: descriptor)
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func configure(descriptor: Int32) throws {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        guard
            descriptorFlags >= 0,
            fcntl(descriptor, F_SETFD, descriptorFlags | FD_CLOEXEC) == 0
        else {
            throw DatabaseBrokerSocketError.unavailable
        }
        let statusFlags = fcntl(descriptor, F_GETFL)
        guard
            statusFlags >= 0,
            fcntl(descriptor, F_SETFL, statusFlags | O_NONBLOCK) == 0
        else {
            throw DatabaseBrokerSocketError.unavailable
        }
        var enabled = Int32(1)
        let optionResult = withUnsafePointer(to: &enabled) { pointer in
            setsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                socklen_t(MemoryLayout<Int32>.size))
        }
        guard optionResult == 0 else {
            throw DatabaseBrokerSocketError.unavailable
        }
    }

    static func connect(
        address: DatabaseBrokerSocketAddress,
        timeoutMilliseconds: Int32
    ) throws -> DatabaseBrokerSocketConnectOutcome {
        try connect(
            address: address,
            timeoutMilliseconds: timeoutMilliseconds
        ) { descriptor, address in
            address.withSockAddr {
                Darwin.connect(descriptor, $0, $1)
            }
        }
    }

    static func connect(
        address: DatabaseBrokerSocketAddress,
        timeoutMilliseconds: Int32,
        performConnect: (Int32, DatabaseBrokerSocketAddress) -> Int32
    ) throws -> DatabaseBrokerSocketConnectOutcome {
        guard
            timeoutMilliseconds > 0,
            timeoutMilliseconds
                <= DatabaseBrokerSocketConnection.maximumTimeoutMilliseconds
        else {
            throw DatabaseBrokerSocketError.invalidTimeout
        }
        let descriptor = try makeDescriptor()
        let connectResult = performConnect(descriptor, address)
        if connectResult == 0 {
            return .connected(descriptor)
        }
        let connectError = errno
        if connectError == ENOENT {
            close(descriptor)
            return .notFound
        }
        if connectError == ECONNREFUSED {
            close(descriptor)
            return .refused
        }
        guard
            connectError == EINPROGRESS
                || connectError == EALREADY
                || connectError == EINTR
        else {
            close(descriptor)
            return .failed(connectError)
        }
        let completion = waitForConnection(
            descriptor: descriptor,
            timeoutMilliseconds: timeoutMilliseconds)
        switch completion {
        case .connected:
            return .connected(descriptor)
        case .notFound:
            close(descriptor)
            return .notFound
        case .refused:
            close(descriptor)
            return .refused
        case .timedOut:
            close(descriptor)
            return .timedOut
        case .failed(let failure):
            close(descriptor)
            return .failed(failure)
        }
    }

    private static func waitForConnection(
        descriptor: Int32,
        timeoutMilliseconds: Int32
    ) -> DatabaseBrokerSocketConnectOutcome {
        let start = DispatchTime.now().uptimeNanoseconds
        let timeoutNanoseconds = UInt64(timeoutMilliseconds) * 1_000_000
        let deadline = start.addingReportingOverflow(timeoutNanoseconds)
        guard !deadline.overflow else {
            return .failed(EINVAL)
        }
        while true {
            let now = DispatchTime.now().uptimeNanoseconds
            guard now < deadline.partialValue else {
                return .timedOut
            }
            let remainingNanoseconds = deadline.partialValue - now
            let roundedMilliseconds = (remainingNanoseconds + 999_999) / 1_000_000
            let pollTimeout = Int32(
                min(roundedMilliseconds, UInt64(Int32.max)))
            var pollDescriptor = pollfd(
                fd: descriptor,
                events: Int16(POLLOUT),
                revents: 0)
            let pollResult = poll(&pollDescriptor, 1, pollTimeout)
            if pollResult == 0 {
                return .timedOut
            }
            if pollResult < 0 {
                if errno == EINTR {
                    continue
                }
                return .failed(errno)
            }
            var socketError = Int32()
            var socketErrorLength = socklen_t(MemoryLayout<Int32>.size)
            let optionResult = withUnsafeMutablePointer(to: &socketError) { pointer in
                getsockopt(
                    descriptor,
                    SOL_SOCKET,
                    SO_ERROR,
                    pointer,
                    &socketErrorLength)
            }
            guard
                optionResult == 0,
                socketErrorLength == socklen_t(MemoryLayout<Int32>.size)
            else {
                return .failed(errno)
            }
            if socketError == 0 {
                return .connected(descriptor)
            }
            if socketError == ENOENT {
                return .notFound
            }
            if socketError == ECONNREFUSED {
                return .refused
            }
            return .failed(socketError)
        }
    }
}
