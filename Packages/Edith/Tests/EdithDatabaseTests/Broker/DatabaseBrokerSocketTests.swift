import Darwin
import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerSocketTestError: Error {
    case fixtureFailure
}

private struct DatabaseBrokerSocketFixture {
    let root: URL
    let paths: DatabaseBrokerPaths
}

private enum DatabaseBrokerSocketFixtures {
    static func make() throws -> DatabaseBrokerSocketFixture {
        let suffix = UUID().uuidString.prefix(12)
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("edb-\(suffix)", isDirectory: true)
        try createDirectory(root)
        return DatabaseBrokerSocketFixture(
            root: root,
            paths: DatabaseBrokerPaths(
                dataDirectory: root.appendingPathComponent("d", isDirectory: true),
                runtimeDirectory: root.appendingPathComponent("r", isDirectory: true)))
    }

    static func createDirectory(_ url: URL, mode: mode_t = mode_t(0o700)) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard chmod(url.path, mode) == 0 else {
            throw DatabaseBrokerSocketTestError.fixtureFailure
        }
    }

    static func createFile(
        _ url: URL,
        contents: String = "",
        mode: mode_t = mode_t(0o600)
    ) throws {
        try Data(contents.utf8).write(to: url)
        guard chmod(url.path, mode) == 0 else {
            throw DatabaseBrokerSocketTestError.fixtureFailure
        }
    }

    static func metadata(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw DatabaseBrokerSocketTestError.fixtureFailure
        }
        return metadata
    }

    static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw DatabaseBrokerSocketTestError.fixtureFailure
        }
    }

    static func bindSocket(
        paths: DatabaseBrokerPaths,
        listening: Bool,
        mode: mode_t = mode_t(0o600)
    ) throws -> Int32 {
        if !FileManager.default.fileExists(atPath: paths.runtimeDirectory.path) {
            try createDirectory(paths.runtimeDirectory)
        }
        let address = try DatabaseBrokerSocketAddress(path: paths.socketFile.path)
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else {
            throw DatabaseBrokerSocketTestError.fixtureFailure
        }
        do {
            guard
                address.withSockAddr({ bind(descriptor, $0, $1) }) == 0,
                chmod(paths.socketFile.path, mode) == 0,
                !listening || Darwin.listen(descriptor, 64) == 0
            else {
                throw DatabaseBrokerSocketTestError.fixtureFailure
            }
            return descriptor
        } catch {
            close(descriptor)
            throw error
        }
    }

    static func removeSocket(
        descriptor: Int32,
        path: URL
    ) {
        if descriptor >= 0 {
            _ = shutdown(descriptor, SHUT_RDWR)
            close(descriptor)
        }
        _ = unlink(path.path)
    }

    static func descriptorIsSecure(_ descriptor: Int32) -> Bool {
        let descriptorFlags = fcntl(descriptor, F_GETFD)
        let statusFlags = fcntl(descriptor, F_GETFL)
        var noSignalPipe = Int32()
        var noSignalPipeLength = socklen_t(MemoryLayout<Int32>.size)
        let optionResult = withUnsafeMutablePointer(to: &noSignalPipe) { pointer in
            getsockopt(
                descriptor,
                SOL_SOCKET,
                SO_NOSIGPIPE,
                pointer,
                &noSignalPipeLength)
        }
        return descriptorFlags >= 0
            && descriptorFlags & FD_CLOEXEC != 0
            && statusFlags >= 0
            && statusFlags & O_NONBLOCK != 0
            && optionResult == 0
            && noSignalPipeLength == socklen_t(MemoryLayout<Int32>.size)
            && noSignalPipe == 1
    }
}

@Suite struct DatabaseBrokerSocketTests {
    @Test func listensConnectsAndAcceptsWithSecureDescriptors() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let listener = try DatabaseBrokerSocketListener.listen(paths: fixture.paths)
        defer { listener.close() }

        #expect(DatabaseBrokerSocketListener.backlog == 64)
        let metadata = try DatabaseBrokerSocketFixtures.metadata(fixture.paths.socketFile)
        #expect(DatabaseBrokerSocketListener.safeSocketMetadata(metadata))
        #expect(listener.identity.device == metadata.st_dev)
        #expect(listener.identity.inode == metadata.st_ino)
        #expect(
            try listener.withSocketDescriptor {
                DatabaseBrokerSocketFixtures.descriptorIsSecure($0)
            })
        #expect(throws: DatabaseBrokerSocketError.listenerAlreadyRunning) {
            _ = try DatabaseBrokerSocketListener.listen(paths: fixture.paths)
        }

        let client = try DatabaseBrokerSocketConnection.connect(paths: fixture.paths)
        defer { client.close() }
        #expect(
            try client.withSocketDescriptor {
                DatabaseBrokerSocketFixtures.descriptorIsSecure($0)
            })
        let acceptedCandidate = try listener.accept()
        let accepted = try #require(acceptedCandidate)
        defer { accepted.close() }
        #expect(
            try accepted.withSocketDescriptor {
                DatabaseBrokerSocketFixtures.descriptorIsSecure($0)
            })
        #expect(try listener.accept() == nil)
    }

    @Test func closeIsIdempotentAndReleasesRuntimeOwnershipAfterCleanup() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let listener = try DatabaseBrokerSocketListener.listen(paths: fixture.paths)
        let client = try DatabaseBrokerSocketConnection.connect(paths: fixture.paths)
        let acceptedCandidate = try listener.accept()
        let accepted = try #require(acceptedCandidate)

        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            client.close()
            accepted.close()
            listener.close()
        }
        listener.close()
        client.close()
        accepted.close()

        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socketFile.path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.ownerLockFile.path))
        #expect(throws: DatabaseBrokerSocketError.notOpen) {
            try listener.withSocketDescriptor { _ in () }
        }
        #expect(throws: DatabaseBrokerSocketError.notOpen) {
            try client.withSocketDescriptor { _ in () }
        }
        #expect(throws: DatabaseBrokerSocketError.notOpen) {
            try accepted.withSocketDescriptor { _ in () }
        }
        let runtimeLock = try DatabaseRuntimeLock.acquire(paths: fixture.paths)
        runtimeLock.release()
    }

    @Test func preAcquiredOwnershipTransfersToListenerUntilClose() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtimeLock = try DatabaseBrokerSocketListener.acquireOwnership(
            paths: fixture.paths)
        let listener = try DatabaseBrokerSocketListener.listen(
            paths: fixture.paths,
            runtimeLock: runtimeLock)

        #expect(throws: DatabaseBrokerSocketError.listenerAlreadyRunning) {
            _ = try DatabaseBrokerSocketListener.acquireOwnership(paths: fixture.paths)
        }

        listener.close()
        let reacquired = try DatabaseBrokerSocketListener.acquireOwnership(
            paths: fixture.paths)
        reacquired.release()
    }

    @Test func preAcquiredOwnershipReleasesWhenAddressValidationFails() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtimeDirectory = fixture.root.appendingPathComponent(
            String(repeating: "r", count: 80),
            isDirectory: true)
        let paths = DatabaseBrokerPaths(
            dataDirectory: fixture.paths.dataDirectory,
            runtimeDirectory: runtimeDirectory)
        let runtimeLock = try DatabaseBrokerSocketListener.acquireOwnership(paths: paths)

        #expect(throws: DatabaseBrokerSocketError.invalidSocketPath) {
            _ = try DatabaseBrokerSocketListener.listen(
                paths: paths,
                runtimeLock: runtimeLock)
        }

        let reacquired = try DatabaseBrokerSocketListener.acquireOwnership(paths: paths)
        reacquired.release()
    }

    @Test func preAcquiredOwnershipReleasesWhenListenerConstructionFails() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let runtimeLock = try DatabaseBrokerSocketListener.acquireOwnership(
            paths: fixture.paths)

        #expect(throws: DatabaseBrokerSocketTestError.fixtureFailure) {
            _ = try DatabaseBrokerSocketListener.listen(
                paths: fixture.paths,
                runtimeLock: runtimeLock
            ) { stage in
                guard case .socketBound = stage else { return }
                throw DatabaseBrokerSocketTestError.fixtureFailure
            }
        }

        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socketFile.path))
        let reacquired = try DatabaseBrokerSocketListener.acquireOwnership(
            paths: fixture.paths)
        reacquired.release()
    }

    @Test func rejectsInvalidPathsAndTimeoutsBeforeConnecting() throws {
        #expect(DatabaseBrokerSocketAddress.maximumPathBytes == 103)
        #expect(throws: DatabaseBrokerSocketError.invalidSocketPath) {
            _ = try DatabaseBrokerSocketAddress(path: "")
        }
        #expect(throws: DatabaseBrokerSocketError.invalidSocketPath) {
            _ = try DatabaseBrokerSocketAddress(path: "relative/broker.sock")
        }
        #expect(throws: DatabaseBrokerSocketError.invalidSocketPath) {
            _ = try DatabaseBrokerSocketAddress(path: "/private/tmp/broker\0.sock")
        }
        let maximumPath =
            "/"
            + String(
                repeating: "a",
                count: DatabaseBrokerSocketAddress.maximumPathBytes - 1)
        _ = try DatabaseBrokerSocketAddress(path: maximumPath)
        #expect(throws: DatabaseBrokerSocketError.invalidSocketPath) {
            _ = try DatabaseBrokerSocketAddress(path: maximumPath + "a")
        }

        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(throws: DatabaseBrokerSocketError.socketNotFound) {
            _ = try DatabaseBrokerSocketConnection.connect(paths: fixture.paths)
        }
        #expect(throws: DatabaseBrokerSocketError.invalidTimeout) {
            _ = try DatabaseBrokerSocketConnection.connect(
                paths: fixture.paths,
                timeoutMilliseconds: 0)
        }
        #expect(throws: DatabaseBrokerSocketError.invalidTimeout) {
            _ = try DatabaseBrokerSocketConnection.connect(
                paths: fixture.paths,
                timeoutMilliseconds:
                    DatabaseBrokerSocketConnection.maximumTimeoutMilliseconds + 1)
        }

        let longRuntime = URL(
            fileURLWithPath: "/private/tmp/" + String(repeating: "b", count: 100),
            isDirectory: true)
        let longPaths = DatabaseBrokerPaths(
            dataDirectory: fixture.paths.dataDirectory,
            runtimeDirectory: longRuntime)
        #expect(throws: DatabaseBrokerSocketError.invalidSocketPath) {
            _ = try DatabaseBrokerSocketListener.listen(paths: longPaths)
        }
        #expect(!FileManager.default.fileExists(atPath: longRuntime.path))
    }

    @Test func rejectsAndPreservesUnsafeExistingEntries() throws {
        let symlink = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: symlink.root) }
        try DatabaseBrokerSocketFixtures.createDirectory(symlink.paths.runtimeDirectory)
        let symlinkTarget = symlink.root.appendingPathComponent("target")
        try DatabaseBrokerSocketFixtures.createFile(symlinkTarget, contents: "preserved")
        try FileManager.default.createSymbolicLink(
            at: symlink.paths.socketFile,
            withDestinationURL: symlinkTarget)
        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: symlink.paths)
        }
        let symlinkMetadata = try DatabaseBrokerSocketFixtures.metadata(
            symlink.paths.socketFile)
        #expect(symlinkMetadata.st_mode & S_IFMT == S_IFLNK)
        #expect(try String(contentsOf: symlinkTarget, encoding: .utf8) == "preserved")

        let nonSocket = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: nonSocket.root) }
        try DatabaseBrokerSocketFixtures.createDirectory(nonSocket.paths.runtimeDirectory)
        try DatabaseBrokerSocketFixtures.createFile(
            nonSocket.paths.socketFile,
            contents: "preserved")
        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: nonSocket.paths)
        }
        #expect(
            try String(contentsOf: nonSocket.paths.socketFile, encoding: .utf8)
                == "preserved")

        let wrongMode = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: wrongMode.root) }
        let wrongModeDescriptor = try DatabaseBrokerSocketFixtures.bindSocket(
            paths: wrongMode.paths,
            listening: false,
            mode: mode_t(0o666))
        close(wrongModeDescriptor)
        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: wrongMode.paths)
        }
        let wrongModeMetadata = try DatabaseBrokerSocketFixtures.metadata(
            wrongMode.paths.socketFile)
        #expect(wrongModeMetadata.st_mode & mode_t(0o7777) == mode_t(0o666))

        let linked = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: linked.root) }
        let linkedDescriptor = try DatabaseBrokerSocketFixtures.bindSocket(
            paths: linked.paths,
            listening: false)
        close(linkedDescriptor)
        let secondLink = linked.paths.runtimeDirectory.appendingPathComponent("second-link")
        guard link(linked.paths.socketFile.path, secondLink.path) == 0 else {
            throw DatabaseBrokerSocketTestError.fixtureFailure
        }
        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: linked.paths)
        }
        let linkedMetadata = try DatabaseBrokerSocketFixtures.metadata(linked.paths.socketFile)
        #expect(linkedMetadata.st_nlink == 2)
        #expect(FileManager.default.fileExists(atPath: secondLink.path))
    }

    @Test func rejectsUnexpectedSocketOwner() {
        var metadata = stat()
        metadata.st_mode = S_IFSOCK | mode_t(0o600)
        metadata.st_uid = geteuid() &+ 1
        metadata.st_nlink = 1
        #expect(!DatabaseBrokerSocketListener.safeSocketMetadata(metadata))
    }

    @Test func preservesExistingLiveListener() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let existingDescriptor = try DatabaseBrokerSocketFixtures.bindSocket(
            paths: fixture.paths,
            listening: true)
        defer {
            DatabaseBrokerSocketFixtures.removeSocket(
                descriptor: existingDescriptor,
                path: fixture.paths.socketFile)
        }
        let before = try DatabaseBrokerSocketFixtures.metadata(fixture.paths.socketFile)

        #expect(throws: DatabaseBrokerSocketError.listenerAlreadyRunning) {
            _ = try DatabaseBrokerSocketListener.listen(paths: fixture.paths)
        }
        let after = try DatabaseBrokerSocketFixtures.metadata(fixture.paths.socketFile)
        #expect(before.st_dev == after.st_dev)
        #expect(before.st_ino == after.st_ino)
        #expect(after.st_mode & mode_t(0o7777) == mode_t(0o600))
    }

    @Test func removesUnchangedStaleSocketBeforeListening() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staleDescriptor = try DatabaseBrokerSocketFixtures.bindSocket(
            paths: fixture.paths,
            listening: false)
        close(staleDescriptor)
        let staleMetadata = try DatabaseBrokerSocketFixtures.metadata(fixture.paths.socketFile)
        var stages: [DatabaseBrokerSocketListenerStage] = []

        let listener = try DatabaseBrokerSocketListener.listen(paths: fixture.paths) {
            stages.append($0)
        }
        defer { listener.close() }
        let activeMetadata = try DatabaseBrokerSocketFixtures.metadata(fixture.paths.socketFile)
        #expect(listener.identity.device == activeMetadata.st_dev)
        #expect(listener.identity.inode == activeMetadata.st_ino)
        #expect(
            staleMetadata.st_dev != activeMetadata.st_dev
                || staleMetadata.st_ino != activeMetadata.st_ino)
        #expect(
            stages == [
                .existingSocketInspected(
                    DatabaseBrokerSocketIdentity(
                        device: staleMetadata.st_dev,
                        inode: staleMetadata.st_ino)),
                .staleSocketConfirmed(
                    DatabaseBrokerSocketIdentity(
                        device: staleMetadata.st_dev,
                        inode: staleMetadata.st_ino)),
                .staleSocketRemoved(
                    DatabaseBrokerSocketIdentity(
                        device: staleMetadata.st_dev,
                        inode: staleMetadata.st_ino)),
                .socketPermissionsSet(listener.identity),
                .socketBound(listener.identity),
                .listening(listener.identity),
            ])
    }

    @Test func rechecksStaleInodeBeforeUnlinking() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staleDescriptor = try DatabaseBrokerSocketFixtures.bindSocket(
            paths: fixture.paths,
            listening: false)
        close(staleDescriptor)
        let movedStale = fixture.root.appendingPathComponent("stale.sock")
        var replacementDescriptor = Int32(-1)
        defer {
            DatabaseBrokerSocketFixtures.removeSocket(
                descriptor: replacementDescriptor,
                path: fixture.paths.socketFile)
        }

        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: fixture.paths) { stage in
                guard case .staleSocketConfirmed = stage else { return }
                try DatabaseBrokerSocketFixtures.move(
                    fixture.paths.socketFile,
                    to: movedStale)
                replacementDescriptor = try DatabaseBrokerSocketFixtures.bindSocket(
                    paths: fixture.paths,
                    listening: true)
            }
        }
        let replacementMetadata = try DatabaseBrokerSocketFixtures.metadata(
            fixture.paths.socketFile)
        #expect(replacementMetadata.st_mode & S_IFMT == S_IFSOCK)
        #expect(FileManager.default.fileExists(atPath: movedStale.path))
    }

    @Test func preservesEntryCreatedAfterStaleRemoval() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let staleDescriptor = try DatabaseBrokerSocketFixtures.bindSocket(
            paths: fixture.paths,
            listening: false)
        close(staleDescriptor)

        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: fixture.paths) { stage in
                guard case .staleSocketRemoved = stage else { return }
                try DatabaseBrokerSocketFixtures.createFile(
                    fixture.paths.socketFile,
                    contents: "replacement")
            }
        }
        #expect(
            try String(contentsOf: fixture.paths.socketFile, encoding: .utf8)
                == "replacement")
    }

    @Test func preservesBoundSocketReplacementDuringSetup() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let movedSocket = fixture.root.appendingPathComponent("bound.sock")

        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: fixture.paths) { stage in
                guard case .socketBound = stage else { return }
                try DatabaseBrokerSocketFixtures.move(
                    fixture.paths.socketFile,
                    to: movedSocket)
                try DatabaseBrokerSocketFixtures.createFile(
                    fixture.paths.socketFile,
                    contents: "replacement")
            }
        }
        #expect(FileManager.default.fileExists(atPath: movedSocket.path))
        #expect(
            try String(contentsOf: fixture.paths.socketFile, encoding: .utf8)
                == "replacement")
    }

    @Test func preservesTemporarySocketReplacementBeforePublication() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let movedSocket = fixture.root.appendingPathComponent("temporary.sock")
        var capturedReplacementURL: URL?

        #expect(throws: DatabaseBrokerSocketError.unsafeSocketEntry) {
            _ = try DatabaseBrokerSocketListener.listen(paths: fixture.paths) { stage in
                guard case .socketPermissionsSet = stage else { return }
                let filenames = try FileManager.default.contentsOfDirectory(
                    atPath: fixture.paths.runtimeDirectory.path)
                let temporaryFilename = try #require(
                    filenames.first { $0.hasPrefix(".s") })
                let temporaryURL = fixture.paths.runtimeDirectory.appendingPathComponent(
                    temporaryFilename)
                capturedReplacementURL = temporaryURL
                try DatabaseBrokerSocketFixtures.move(
                    temporaryURL,
                    to: movedSocket)
                try DatabaseBrokerSocketFixtures.createFile(
                    temporaryURL,
                    contents: "replacement")
            }
        }
        let replacementURL = try #require(capturedReplacementURL)
        #expect(FileManager.default.fileExists(atPath: movedSocket.path))
        #expect(
            try String(contentsOf: replacementURL, encoding: .utf8)
                == "replacement")
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socketFile.path))
    }

    @Test func retriesInterruptedConnectAndAccept() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let listener = try DatabaseBrokerSocketListener.listen(paths: fixture.paths)
        defer { listener.close() }

        let client = try DatabaseBrokerSocketConnection.connect(
            paths: fixture.paths
        ) { descriptor, address in
            let result = address.withSockAddr {
                Darwin.connect(descriptor, $0, $1)
            }
            if result == 0 {
                errno = EINTR
                return -1
            }
            return result
        }
        defer { client.close() }
        var acceptCallCount = 0
        let acceptedCandidate = try listener.accept { descriptor in
            acceptCallCount += 1
            if acceptCallCount == 1 {
                errno = EINTR
                return -1
            }
            return Darwin.accept(descriptor, nil, nil)
        }
        let accepted = try #require(acceptedCandidate)
        accepted.close()
        #expect(acceptCallCount == 2)
    }

    @Test func closeInterruptsBorrowedConnectionBeforeDescriptorRelease() throws {
        let fixture = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let listener = try DatabaseBrokerSocketListener.listen(paths: fixture.paths)
        defer { listener.close() }
        let client = try DatabaseBrokerSocketConnection.connect(paths: fixture.paths)
        defer { client.close() }
        let acceptedCandidate = try listener.accept()
        let accepted = try #require(acceptedCandidate)
        let borrowStarted = DispatchSemaphore(value: 0)
        let borrowFinished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            try? accepted.withSocketDescriptor { descriptor in
                borrowStarted.signal()
                var pollDescriptor = pollfd(
                    fd: descriptor,
                    events: Int16(POLLIN),
                    revents: 0)
                _ = poll(&pollDescriptor, 1, 5_000)
            }
            borrowFinished.signal()
        }
        try #require(borrowStarted.wait(timeout: .now() + .seconds(1)) == .success)

        accepted.close()
        #expect(borrowFinished.wait(timeout: .now() + .seconds(1)) == .success)
        #expect(throws: DatabaseBrokerSocketError.notOpen) {
            try accepted.withSocketDescriptor { _ in () }
        }
    }

    @Test func closeUnlinksOnlyCapturedUnchangedSocket() throws {
        let replacement = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: replacement.root) }
        let listener = try DatabaseBrokerSocketListener.listen(paths: replacement.paths)
        let movedSocket = replacement.root.appendingPathComponent("active.sock")
        try DatabaseBrokerSocketFixtures.move(
            replacement.paths.socketFile,
            to: movedSocket)
        try DatabaseBrokerSocketFixtures.createFile(
            replacement.paths.socketFile,
            contents: "replacement")
        listener.close()
        #expect(FileManager.default.fileExists(atPath: movedSocket.path))
        #expect(
            try String(contentsOf: replacement.paths.socketFile, encoding: .utf8)
                == "replacement")
        let replacementLock = try DatabaseRuntimeLock.acquire(paths: replacement.paths)
        replacementLock.release()

        let mode = try DatabaseBrokerSocketFixtures.make()
        defer { try? FileManager.default.removeItem(at: mode.root) }
        let modeListener = try DatabaseBrokerSocketListener.listen(paths: mode.paths)
        guard chmod(mode.paths.socketFile.path, mode_t(0o644)) == 0 else {
            throw DatabaseBrokerSocketTestError.fixtureFailure
        }
        modeListener.close()
        let modeMetadata = try DatabaseBrokerSocketFixtures.metadata(mode.paths.socketFile)
        #expect(modeMetadata.st_mode & mode_t(0o7777) == mode_t(0o644))
        let modeLock = try DatabaseRuntimeLock.acquire(paths: mode.paths)
        modeLock.release()
    }
}
