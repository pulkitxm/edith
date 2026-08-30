import Darwin
import Dispatch
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseRuntimeLockTestError: Error {
    case fixtureFailure
}

private enum DatabaseRuntimeLockAcquisition: @unchecked Sendable {
    case acquired(DatabaseRuntimeLock)
    case rejected(DatabaseRuntimeLockError)
    case unexpected
}

private struct DatabaseRuntimeLockFixture {
    let root: URL
    let paths: DatabaseBrokerPaths
}

private enum DatabaseRuntimeLockFixtures {
    static func make(
        runtimeComponents: [String] = ["runtime"]
    ) throws -> DatabaseRuntimeLockFixture {
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &resolvedPath) != nil else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        let root = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
            .appendingPathComponent("edith-database-runtime-lock-\(UUID().uuidString)")
        try createDirectory(root)
        let runtimeDirectory = runtimeComponents.reduce(root) { directory, component in
            directory.appendingPathComponent(component, isDirectory: true)
        }
        return DatabaseRuntimeLockFixture(
            root: root,
            paths: DatabaseBrokerPaths(
                dataDirectory: root.appendingPathComponent("data", isDirectory: true),
                runtimeDirectory: runtimeDirectory))
    }

    static func createDirectory(_ url: URL, mode: mode_t = mode_t(0o700)) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard chmod(url.path, mode) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
    }

    static func createFile(
        _ url: URL,
        contents: String = "",
        mode: mode_t = mode_t(0o600)
    ) throws {
        try Data(contents.utf8).write(to: url)
        guard chmod(url.path, mode) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
    }

    static func metadata(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        return metadata
    }

    static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
    }
}

@Suite struct DatabaseRuntimeLockTests {
    @Test func acquiresCanonicalOwnerLockAndRetainsDirectoryAccess() throws {
        let fixture = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let lock = try DatabaseRuntimeLock.acquire(paths: fixture.paths)

        let directoryMetadata = try DatabaseRuntimeLockFixtures.metadata(
            fixture.paths.runtimeDirectory)
        let lockMetadata = try DatabaseRuntimeLockFixtures.metadata(fixture.paths.ownerLockFile)
        #expect(directoryMetadata.st_mode & S_IFMT == S_IFDIR)
        #expect(directoryMetadata.st_mode & mode_t(0o7777) == mode_t(0o700))
        #expect(directoryMetadata.st_uid == geteuid())
        #expect(lockMetadata.st_mode & S_IFMT == S_IFREG)
        #expect(lockMetadata.st_mode & mode_t(0o7777) == mode_t(0o600))
        #expect(lockMetadata.st_uid == geteuid())
        #expect(lockMetadata.st_nlink == 1)

        let descriptorMetadata = try lock.withRuntimeDirectoryDescriptor { descriptor in
            var metadata = stat()
            guard fstat(descriptor, &metadata) == 0 else {
                throw DatabaseRuntimeLockTestError.fixtureFailure
            }
            let probe = "descriptor-probe"
            let probeDescriptor = openat(
                descriptor,
                probe,
                O_RDWR | O_CLOEXEC | O_NOFOLLOW | O_CREAT | O_EXCL,
                mode_t(0o600))
            guard probeDescriptor >= 0 else {
                throw DatabaseRuntimeLockTestError.fixtureFailure
            }
            close(probeDescriptor)
            guard unlinkat(descriptor, probe, 0) == 0 else {
                throw DatabaseRuntimeLockTestError.fixtureFailure
            }
            return metadata
        }
        #expect(descriptorMetadata.st_dev == directoryMetadata.st_dev)
        #expect(descriptorMetadata.st_ino == directoryMetadata.st_ino)

        #expect(throws: DatabaseRuntimeLockError.alreadyHeld) {
            _ = try DatabaseRuntimeLock.acquire(paths: fixture.paths)
        }
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            lock.release()
        }
        lock.release()
        #expect(FileManager.default.fileExists(atPath: fixture.paths.ownerLockFile.path))
        #expect(throws: DatabaseRuntimeLockError.notHeld) {
            try lock.withRuntimeDirectoryDescriptor { _ in () }
        }

        let reacquired = try DatabaseRuntimeLock.acquire(paths: fixture.paths)
        reacquired.release()
        var deinitialized: DatabaseRuntimeLock? = try DatabaseRuntimeLock.acquire(
            paths: fixture.paths)
        #expect(deinitialized != nil)
        deinitialized = nil
        let afterDeinit = try DatabaseRuntimeLock.acquire(paths: fixture.paths)
        afterDeinit.release()
    }

    @Test func rejectsInvalidAndSymlinkedRuntimePaths() throws {
        let fixture = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalidPaths = DatabaseBrokerPaths(
            dataDirectory: fixture.paths.dataDirectory,
            runtimeDirectory: URL(string: "https://example.invalid/runtime")!)
        #expect(throws: DatabaseRuntimeLockError.invalidRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(paths: invalidPaths)
        }

        let realAncestor = fixture.root.appendingPathComponent("real-ancestor")
        try DatabaseRuntimeLockFixtures.createDirectory(realAncestor)
        let linkedAncestor = fixture.root.appendingPathComponent("linked-ancestor")
        try FileManager.default.createSymbolicLink(
            at: linkedAncestor,
            withDestinationURL: realAncestor)
        let linkedPaths = DatabaseBrokerPaths(
            dataDirectory: fixture.paths.dataDirectory,
            runtimeDirectory: linkedAncestor.appendingPathComponent("database"))
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(paths: linkedPaths)
        }
        let linkedMetadata = try DatabaseRuntimeLockFixtures.metadata(linkedAncestor)
        #expect(linkedMetadata.st_mode & S_IFMT == S_IFLNK)
        #expect(
            !FileManager.default.fileExists(
                atPath: realAncestor.appendingPathComponent("database").path))

        let runtimeTarget = fixture.root.appendingPathComponent("runtime-target")
        try DatabaseRuntimeLockFixtures.createDirectory(runtimeTarget)
        try FileManager.default.createSymbolicLink(
            at: fixture.paths.runtimeDirectory,
            withDestinationURL: runtimeTarget)
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(paths: fixture.paths)
        }
        let runtimeMetadata = try DatabaseRuntimeLockFixtures.metadata(
            fixture.paths.runtimeDirectory)
        #expect(runtimeMetadata.st_mode & S_IFMT == S_IFLNK)
    }

    @Test func rejectsRuntimeDirectoryModeAndOwnerMismatches() throws {
        let fixture = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        try DatabaseRuntimeLockFixtures.createDirectory(
            fixture.paths.runtimeDirectory,
            mode: mode_t(0o755))
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(paths: fixture.paths)
        }
        let metadata = try DatabaseRuntimeLockFixtures.metadata(fixture.paths.runtimeDirectory)
        #expect(metadata.st_mode & mode_t(0o7777) == mode_t(0o755))

        var unexpectedOwner = metadata
        unexpectedOwner.st_mode = S_IFDIR | mode_t(0o700)
        unexpectedOwner.st_uid = geteuid() &+ 1
        #expect(
            !DatabaseBrokerPaths.safeDirectoryMetadata(
                unexpectedOwner,
                requireMode: true))
    }

    @Test func rejectsAndPreservesUnsafeOwnerLockTargets() throws {
        let symlink = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: symlink.root) }
        try DatabaseRuntimeLockFixtures.createDirectory(symlink.paths.runtimeDirectory)
        let symlinkTarget = symlink.root.appendingPathComponent("symlink-target")
        try DatabaseRuntimeLockFixtures.createFile(symlinkTarget, contents: "preserved")
        try FileManager.default.createSymbolicLink(
            at: symlink.paths.ownerLockFile,
            withDestinationURL: symlinkTarget)
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(paths: symlink.paths)
        }
        let symlinkMetadata = try DatabaseRuntimeLockFixtures.metadata(
            symlink.paths.ownerLockFile)
        #expect(symlinkMetadata.st_mode & S_IFMT == S_IFLNK)
        #expect(try String(contentsOf: symlinkTarget, encoding: .utf8) == "preserved")

        let nonregular = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: nonregular.root) }
        try DatabaseRuntimeLockFixtures.createDirectory(nonregular.paths.runtimeDirectory)
        try DatabaseRuntimeLockFixtures.createDirectory(nonregular.paths.ownerLockFile)
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(paths: nonregular.paths)
        }
        let nonregularMetadata = try DatabaseRuntimeLockFixtures.metadata(
            nonregular.paths.ownerLockFile)
        #expect(nonregularMetadata.st_mode & S_IFMT == S_IFDIR)

        let wrongMode = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: wrongMode.root) }
        try DatabaseRuntimeLockFixtures.createDirectory(wrongMode.paths.runtimeDirectory)
        try DatabaseRuntimeLockFixtures.createFile(
            wrongMode.paths.ownerLockFile,
            mode: mode_t(0o644))
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(paths: wrongMode.paths)
        }
        let wrongModeMetadata = try DatabaseRuntimeLockFixtures.metadata(
            wrongMode.paths.ownerLockFile)
        #expect(wrongModeMetadata.st_mode & mode_t(0o7777) == mode_t(0o644))

        let linked = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: linked.root) }
        try DatabaseRuntimeLockFixtures.createDirectory(linked.paths.runtimeDirectory)
        try DatabaseRuntimeLockFixtures.createFile(linked.paths.ownerLockFile)
        let secondLink = linked.paths.runtimeDirectory.appendingPathComponent("second-link")
        guard link(linked.paths.ownerLockFile.path, secondLink.path) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(paths: linked.paths)
        }
        let linkedMetadata = try DatabaseRuntimeLockFixtures.metadata(
            linked.paths.ownerLockFile)
        #expect(linkedMetadata.st_nlink == 2)
        #expect(FileManager.default.fileExists(atPath: secondLink.path))
    }

    @Test func rejectsUnexpectedOwnerLockOwner() {
        var metadata = stat()
        metadata.st_mode = S_IFREG | mode_t(0o600)
        metadata.st_uid = geteuid() &+ 1
        metadata.st_nlink = 1
        #expect(!DatabaseRuntimeLock.safeLockFileMetadata(metadata))
    }

    @Test func detectsRuntimeLeafAndAncestorReplacementDuringAcquisition() throws {
        let leaf = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: leaf.root) }
        let movedLeaf = leaf.root.appendingPathComponent("opened-runtime")
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(paths: leaf.paths) { stage in
                guard case .runtimeDirectoryOpened = stage else { return }
                try DatabaseRuntimeLockFixtures.move(
                    leaf.paths.runtimeDirectory,
                    to: movedLeaf)
                try DatabaseRuntimeLockFixtures.createDirectory(leaf.paths.runtimeDirectory)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: leaf.paths.ownerLockFile.path))
        #expect(
            !FileManager.default.fileExists(
                atPath: movedLeaf.appendingPathComponent(
                    DatabaseBrokerPaths.ownerLockFilename
                ).path))

        let ancestor = try DatabaseRuntimeLockFixtures.make(
            runtimeComponents: ["ancestor", "database"])
        defer { try? FileManager.default.removeItem(at: ancestor.root) }
        let ancestorDirectory = ancestor.root.appendingPathComponent("ancestor")
        try DatabaseRuntimeLockFixtures.createDirectory(ancestorDirectory)
        try DatabaseRuntimeLockFixtures.createDirectory(ancestor.paths.runtimeDirectory)
        let movedAncestor = ancestor.root.appendingPathComponent("opened-ancestor")
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(paths: ancestor.paths) { stage in
                guard case .runtimeDirectoryOpened = stage else { return }
                try DatabaseRuntimeLockFixtures.move(ancestorDirectory, to: movedAncestor)
                try DatabaseRuntimeLockFixtures.createDirectory(ancestorDirectory)
                try DatabaseRuntimeLockFixtures.createDirectory(
                    ancestor.paths.runtimeDirectory)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: ancestor.paths.ownerLockFile.path))
    }

    @Test func detectsOwnerLockReplacementDuringAndAfterAcquisition() throws {
        let acquiring = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: acquiring.root) }
        let movedLock = acquiring.root.appendingPathComponent("opened-owner.lock")
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(paths: acquiring.paths) { stage in
                guard case .lockAcquired = stage else { return }
                try DatabaseRuntimeLockFixtures.move(
                    acquiring.paths.ownerLockFile,
                    to: movedLock)
                try DatabaseRuntimeLockFixtures.createFile(
                    acquiring.paths.ownerLockFile,
                    contents: "replacement")
            }
        }
        #expect(FileManager.default.fileExists(atPath: movedLock.path))
        #expect(
            try String(contentsOf: acquiring.paths.ownerLockFile, encoding: .utf8)
                == "replacement")
        let movedDescriptor = open(movedLock.path, O_RDWR | O_CLOEXEC | O_NOFOLLOW)
        guard movedDescriptor >= 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        defer { close(movedDescriptor) }
        #expect(flock(movedDescriptor, LOCK_EX | LOCK_NB) == 0)
        _ = flock(movedDescriptor, LOCK_UN)

        let held = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: held.root) }
        let lock = try DatabaseRuntimeLock.acquire(paths: held.paths)
        let originalLock = held.root.appendingPathComponent("original-owner.lock")
        try DatabaseRuntimeLockFixtures.move(held.paths.ownerLockFile, to: originalLock)
        try DatabaseRuntimeLockFixtures.createFile(held.paths.ownerLockFile)
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            try lock.withRuntimeDirectoryDescriptor { _ in () }
        }
        lock.release()
    }

    @Test func revalidatesRuntimeAncestryAndLockMetadataWhileHeld() throws {
        let ancestry = try DatabaseRuntimeLockFixtures.make(
            runtimeComponents: ["ancestor", "database"])
        defer { try? FileManager.default.removeItem(at: ancestry.root) }
        let ancestorDirectory = ancestry.root.appendingPathComponent("ancestor")
        try DatabaseRuntimeLockFixtures.createDirectory(ancestorDirectory)
        let ancestryLock = try DatabaseRuntimeLock.acquire(paths: ancestry.paths)
        let movedAncestor = ancestry.root.appendingPathComponent("moved-ancestor")
        try DatabaseRuntimeLockFixtures.move(ancestorDirectory, to: movedAncestor)
        try DatabaseRuntimeLockFixtures.createDirectory(ancestorDirectory)
        try DatabaseRuntimeLockFixtures.createDirectory(ancestry.paths.runtimeDirectory)
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            try ancestryLock.withRuntimeDirectoryDescriptor { _ in () }
        }
        ancestryLock.release()

        let metadata = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: metadata.root) }
        let metadataLock = try DatabaseRuntimeLock.acquire(paths: metadata.paths)
        guard chmod(metadata.paths.ownerLockFile.path, mode_t(0o644)) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            try metadataLock.withRuntimeDirectoryDescriptor { _ in () }
        }
        guard chmod(metadata.paths.ownerLockFile.path, mode_t(0o600)) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        let secondLink = metadata.paths.runtimeDirectory.appendingPathComponent("second-link")
        guard link(metadata.paths.ownerLockFile.path, secondLink.path) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            try metadataLock.withRuntimeDirectoryDescriptor { _ in () }
        }
        metadataLock.release()

        let postOperation = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: postOperation.root) }
        let postOperationLock = try DatabaseRuntimeLock.acquire(paths: postOperation.paths)
        let movedRuntime = postOperation.root.appendingPathComponent("moved-runtime")
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            try postOperationLock.withRuntimeDirectoryDescriptor { _ in
                try DatabaseRuntimeLockFixtures.move(
                    postOperation.paths.runtimeDirectory,
                    to: movedRuntime)
                try DatabaseRuntimeLockFixtures.createDirectory(
                    postOperation.paths.runtimeDirectory)
            }
        }
        postOperationLock.release()
    }

    @Test func concurrentAcquisitionHasSingleWinner() async throws {
        let fixture = try DatabaseRuntimeLockFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let attempts = 64
        let acquisitions = await withTaskGroup(of: DatabaseRuntimeLockAcquisition.self) { group in
            for _ in 0..<attempts {
                group.addTask {
                    do {
                        return .acquired(
                            try DatabaseRuntimeLock.acquire(paths: fixture.paths))
                    } catch let error as DatabaseRuntimeLockError {
                        return .rejected(error)
                    } catch {
                        return .unexpected
                    }
                }
            }
            var acquisitions: [DatabaseRuntimeLockAcquisition] = []
            for await acquisition in group {
                acquisitions.append(acquisition)
            }
            return acquisitions
        }

        let winners = acquisitions.compactMap { acquisition -> DatabaseRuntimeLock? in
            guard case .acquired(let lock) = acquisition else { return nil }
            return lock
        }
        let rejections = acquisitions.compactMap { acquisition -> DatabaseRuntimeLockError? in
            guard case .rejected(let error) = acquisition else { return nil }
            return error
        }
        #expect(winners.count == 1)
        #expect(rejections.count == attempts - 1)
        #expect(rejections.allSatisfy { $0 == .alreadyHeld })
        #expect(acquisitions.count == attempts)
        winners.forEach { $0.release() }

        let reacquired = try DatabaseRuntimeLock.acquire(paths: fixture.paths)
        reacquired.release()
    }
}
