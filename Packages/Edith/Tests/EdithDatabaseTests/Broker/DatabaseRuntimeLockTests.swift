import Darwin
import Dispatch
import EdithDatabase
import Foundation
import Testing

private enum DatabaseRuntimeLockTestError: Error {
    case fixtureFailure
}

private enum DatabaseRuntimeLockAcquisition: @unchecked Sendable {
    case acquired(DatabaseRuntimeLock)
    case rejected(DatabaseRuntimeLockError)
    case unexpected
}

private enum DatabaseRuntimeLockFixtures {
    static func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-database-runtime-lock-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard chmod(root.path, mode_t(0o700)) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        return root
    }

    static func createDirectory(_ url: URL, mode: mode_t = mode_t(0o700)) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard chmod(url.path, mode) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
    }

    static func createFile(_ url: URL, mode: mode_t = mode_t(0o600)) throws {
        try Data().write(to: url)
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
}

@Suite struct DatabaseRuntimeLockTests {
    @Test func createsSecureDirectoryAndFileAndReleasesIdempotently() throws {
        let root = try DatabaseRuntimeLockFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeDirectory = root.appendingPathComponent("runtime")
        let filename = "custom-broker.lock"
        let lockURL = runtimeDirectory.appendingPathComponent(filename)
        let lock = try DatabaseRuntimeLock.acquire(
            runtimeDirectory: runtimeDirectory,
            filename: filename)

        let directoryMetadata = try DatabaseRuntimeLockFixtures.metadata(runtimeDirectory)
        let lockMetadata = try DatabaseRuntimeLockFixtures.metadata(lockURL)
        #expect(directoryMetadata.st_mode & S_IFMT == S_IFDIR)
        #expect(directoryMetadata.st_mode & mode_t(0o7777) == mode_t(0o700))
        #expect(directoryMetadata.st_uid == geteuid())
        #expect(lockMetadata.st_mode & S_IFMT == S_IFREG)
        #expect(lockMetadata.st_mode & mode_t(0o7777) == mode_t(0o600))
        #expect(lockMetadata.st_uid == geteuid())
        #expect(lockMetadata.st_nlink == 1)

        #expect(throws: DatabaseRuntimeLockError.alreadyHeld) {
            _ = try DatabaseRuntimeLock.acquire(
                runtimeDirectory: runtimeDirectory,
                filename: filename)
        }
        DispatchQueue.concurrentPerform(iterations: 32) { _ in
            lock.release()
        }
        lock.release()
        #expect(FileManager.default.fileExists(atPath: lockURL.path))

        let reacquired = try DatabaseRuntimeLock.acquire(
            runtimeDirectory: runtimeDirectory,
            filename: filename)
        reacquired.release()
        var deinitialized: DatabaseRuntimeLock? = try DatabaseRuntimeLock.acquire(
            runtimeDirectory: runtimeDirectory,
            filename: filename)
        #expect(deinitialized != nil)
        deinitialized = nil
        let afterDeinit = try DatabaseRuntimeLock.acquire(
            runtimeDirectory: runtimeDirectory,
            filename: filename)
        afterDeinit.release()
    }

    @Test func rejectsUnsafeRuntimeDirectories() throws {
        let root = try DatabaseRuntimeLockFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let realDirectory = root.appendingPathComponent("real")
        try DatabaseRuntimeLockFixtures.createDirectory(realDirectory)
        let symbolicDirectory = root.appendingPathComponent("symbolic")
        try FileManager.default.createSymbolicLink(
            at: symbolicDirectory,
            withDestinationURL: realDirectory)
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(runtimeDirectory: symbolicDirectory)
        }

        let permissiveDirectory = root.appendingPathComponent("permissive")
        try DatabaseRuntimeLockFixtures.createDirectory(
            permissiveDirectory,
            mode: mode_t(0o755))
        #expect(throws: DatabaseRuntimeLockError.unsafeRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(runtimeDirectory: permissiveDirectory)
        }

        #expect(throws: DatabaseRuntimeLockError.invalidRuntimeDirectory) {
            _ = try DatabaseRuntimeLock.acquire(
                runtimeDirectory: URL(string: "https://example.invalid/runtime")!)
        }
    }

    @Test func rejectsSymlinkNonregularAndMultiplyLinkedLockTargets() throws {
        let root = try DatabaseRuntimeLockFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }

        let symlinkRuntime = root.appendingPathComponent("symlink-runtime")
        try DatabaseRuntimeLockFixtures.createDirectory(symlinkRuntime)
        let symlinkTarget = root.appendingPathComponent("symlink-target")
        try DatabaseRuntimeLockFixtures.createFile(symlinkTarget)
        try FileManager.default.createSymbolicLink(
            at: symlinkRuntime.appendingPathComponent(DatabaseRuntimeLock.defaultFilename),
            withDestinationURL: symlinkTarget)
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(runtimeDirectory: symlinkRuntime)
        }

        let nonregularRuntime = root.appendingPathComponent("nonregular-runtime")
        try DatabaseRuntimeLockFixtures.createDirectory(nonregularRuntime)
        try DatabaseRuntimeLockFixtures.createDirectory(
            nonregularRuntime.appendingPathComponent(DatabaseRuntimeLock.defaultFilename))
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(runtimeDirectory: nonregularRuntime)
        }

        let wrongModeRuntime = root.appendingPathComponent("wrong-mode-runtime")
        try DatabaseRuntimeLockFixtures.createDirectory(wrongModeRuntime)
        try DatabaseRuntimeLockFixtures.createFile(
            wrongModeRuntime.appendingPathComponent(DatabaseRuntimeLock.defaultFilename),
            mode: mode_t(0o644))
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(runtimeDirectory: wrongModeRuntime)
        }

        let linkedRuntime = root.appendingPathComponent("linked-runtime")
        try DatabaseRuntimeLockFixtures.createDirectory(linkedRuntime)
        let linkedLock = linkedRuntime.appendingPathComponent(DatabaseRuntimeLock.defaultFilename)
        try DatabaseRuntimeLockFixtures.createFile(linkedLock)
        let secondLink = linkedRuntime.appendingPathComponent("second-link")
        guard link(linkedLock.path, secondLink.path) == 0 else {
            throw DatabaseRuntimeLockTestError.fixtureFailure
        }
        #expect(throws: DatabaseRuntimeLockError.unsafeLockFile) {
            _ = try DatabaseRuntimeLock.acquire(runtimeDirectory: linkedRuntime)
        }
    }

    @Test func validatesCallerSpecifiedFilenameWithoutTraversal() throws {
        let root = try DatabaseRuntimeLockFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let invalidFilenames = [
            "",
            ".",
            "..",
            "../broker.lock",
            "nested/broker.lock",
            "broker lock",
            String(repeating: "a", count: DatabaseRuntimeLock.maximumFilenameBytes + 1),
        ]
        for filename in invalidFilenames {
            #expect(throws: DatabaseRuntimeLockError.invalidLockFilename) {
                _ = try DatabaseRuntimeLock.acquire(
                    runtimeDirectory: root.appendingPathComponent("runtime"),
                    filename: filename)
            }
        }
        #expect(
            !FileManager.default.fileExists(atPath: root.appendingPathComponent("runtime").path))
    }

    @Test func concurrentAcquisitionHasSingleWinner() async throws {
        let root = try DatabaseRuntimeLockFixtures.root()
        defer { try? FileManager.default.removeItem(at: root) }
        let runtimeDirectory = root.appendingPathComponent("runtime")
        let attempts = 64
        let acquisitions = await withTaskGroup(of: DatabaseRuntimeLockAcquisition.self) { group in
            for _ in 0..<attempts {
                group.addTask {
                    do {
                        return .acquired(
                            try DatabaseRuntimeLock.acquire(
                                runtimeDirectory: runtimeDirectory))
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

        let reacquired = try DatabaseRuntimeLock.acquire(runtimeDirectory: runtimeDirectory)
        reacquired.release()
    }
}
