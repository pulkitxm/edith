import Darwin
import EdithCore
import Foundation
import Testing

@testable import EdithDatabase

private enum DatabaseBrokerPathsTestError: Error {
    case fixtureFailure
}

private struct DatabaseBrokerPathsFixture {
    let root: URL
    let paths: DatabaseBrokerPaths
}

private enum DatabaseBrokerPathsFixtures {
    static func make() throws -> DatabaseBrokerPathsFixture {
        var resolvedPath = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(FileManager.default.temporaryDirectory.path, &resolvedPath) != nil else {
            throw DatabaseBrokerPathsTestError.fixtureFailure
        }
        let root = URL(fileURLWithPath: String(cString: resolvedPath), isDirectory: true)
            .appendingPathComponent("edith-database-broker-paths-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        guard chmod(root.path, mode_t(0o700)) == 0 else {
            throw DatabaseBrokerPathsTestError.fixtureFailure
        }
        let appDirectories = AppDirectories(homeDirectory: root)
        try appDirectories.prepare()
        return DatabaseBrokerPathsFixture(
            root: root,
            paths: DatabaseBrokerPaths(directories: appDirectories))
    }

    static func createDirectory(_ url: URL, mode: mode_t = mode_t(0o700)) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        guard chmod(url.path, mode) == 0 else {
            throw DatabaseBrokerPathsTestError.fixtureFailure
        }
    }

    static func createFile(
        _ url: URL,
        contents: String = "",
        mode: mode_t = mode_t(0o600)
    ) throws {
        try Data(contents.utf8).write(to: url)
        guard chmod(url.path, mode) == 0 else {
            throw DatabaseBrokerPathsTestError.fixtureFailure
        }
    }

    static func metadata(_ url: URL) throws -> stat {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0 else {
            throw DatabaseBrokerPathsTestError.fixtureFailure
        }
        return metadata
    }

    static func move(_ source: URL, to destination: URL) throws {
        guard rename(source.path, destination.path) == 0 else {
            throw DatabaseBrokerPathsTestError.fixtureFailure
        }
    }
}

@Suite struct DatabaseBrokerPathsTests {
    @Test func derivesCanonicalPathsFromAppDirectories() {
        let appDirectories = AppDirectories(
            homeDirectory: URL(fileURLWithPath: "/Users/example"))
        let paths = DatabaseBrokerPaths(directories: appDirectories)

        #expect(
            paths.dataDirectory.path
                == "/Users/example/Library/Application Support/Edith/database")
        #expect(
            paths.metadataFile.path
                == "/Users/example/Library/Application Support/Edith/database/metadata.sqlite3")
        #expect(
            paths.runtimeDirectory.path
                == "/Users/example/Library/Caches/Edith/Runtime/database")
        #expect(
            paths.ownerLockFile.path
                == "/Users/example/Library/Caches/Edith/Runtime/database/owner.lock")
        #expect(
            paths.socketFile.path
                == "/Users/example/Library/Caches/Edith/Runtime/database/broker.sock")
    }

    @Test func createsSecureStorageAndPreparesIdempotently() throws {
        let fixture = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }

        try fixture.paths.prepare()
        let firstData = try DatabaseBrokerPathsFixtures.metadata(fixture.paths.dataDirectory)
        let firstRuntime = try DatabaseBrokerPathsFixtures.metadata(fixture.paths.runtimeDirectory)
        let firstMetadata = try DatabaseBrokerPathsFixtures.metadata(fixture.paths.metadataFile)

        #expect(firstData.st_mode & S_IFMT == S_IFDIR)
        #expect(firstData.st_mode & mode_t(0o7777) == mode_t(0o700))
        #expect(firstData.st_uid == geteuid())
        #expect(firstRuntime.st_mode & S_IFMT == S_IFDIR)
        #expect(firstRuntime.st_mode & mode_t(0o7777) == mode_t(0o700))
        #expect(firstRuntime.st_uid == geteuid())
        #expect(firstMetadata.st_mode & S_IFMT == S_IFREG)
        #expect(firstMetadata.st_mode & mode_t(0o7777) == mode_t(0o600))
        #expect(firstMetadata.st_uid == geteuid())
        #expect(firstMetadata.st_nlink == 1)
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.ownerLockFile.path))
        #expect(!FileManager.default.fileExists(atPath: fixture.paths.socketFile.path))

        try fixture.paths.prepare()
        let secondData = try DatabaseBrokerPathsFixtures.metadata(fixture.paths.dataDirectory)
        let secondRuntime = try DatabaseBrokerPathsFixtures.metadata(fixture.paths.runtimeDirectory)
        let secondMetadata = try DatabaseBrokerPathsFixtures.metadata(fixture.paths.metadataFile)
        #expect(firstData.st_dev == secondData.st_dev)
        #expect(firstData.st_ino == secondData.st_ino)
        #expect(firstRuntime.st_dev == secondRuntime.st_dev)
        #expect(firstRuntime.st_ino == secondRuntime.st_ino)
        #expect(firstMetadata.st_dev == secondMetadata.st_dev)
        #expect(firstMetadata.st_ino == secondMetadata.st_ino)
    }

    @Test func rejectsInvalidDirectoryURLs() throws {
        let fixture = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let remote = URL(string: "https://example.invalid/database")!
        let queried = URL(string: "file:///tmp/database?unexpected=true")!

        #expect(throws: DatabaseBrokerPathsError.invalidDataDirectory) {
            try DatabaseBrokerPaths(
                dataDirectory: remote,
                runtimeDirectory: fixture.paths.runtimeDirectory
            ).prepare()
        }
        #expect(throws: DatabaseBrokerPathsError.invalidRuntimeDirectory) {
            try DatabaseBrokerPaths(
                dataDirectory: fixture.paths.dataDirectory,
                runtimeDirectory: queried
            ).prepare()
        }
    }

    @Test func rejectsAndPreservesUnsafeDataAndRuntimeDirectories() throws {
        let dataSymlink = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: dataSymlink.root) }
        let dataTarget = dataSymlink.root.appendingPathComponent("data-target")
        try DatabaseBrokerPathsFixtures.createDirectory(dataTarget)
        try FileManager.default.createSymbolicLink(
            at: dataSymlink.paths.dataDirectory,
            withDestinationURL: dataTarget)
        #expect(throws: DatabaseBrokerPathsError.unsafeDataDirectory) {
            try dataSymlink.paths.prepare()
        }
        let dataSymlinkMetadata = try DatabaseBrokerPathsFixtures.metadata(
            dataSymlink.paths.dataDirectory)
        #expect(dataSymlinkMetadata.st_mode & S_IFMT == S_IFLNK)

        let dataFile = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: dataFile.root) }
        try DatabaseBrokerPathsFixtures.createFile(dataFile.paths.dataDirectory)
        #expect(throws: DatabaseBrokerPathsError.unsafeDataDirectory) {
            try dataFile.paths.prepare()
        }
        let dataFileMetadata = try DatabaseBrokerPathsFixtures.metadata(
            dataFile.paths.dataDirectory)
        #expect(dataFileMetadata.st_mode & S_IFMT == S_IFREG)

        let runtimeMode = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: runtimeMode.root) }
        try DatabaseBrokerPathsFixtures.createDirectory(
            runtimeMode.paths.runtimeDirectory,
            mode: mode_t(0o755))
        #expect(throws: DatabaseBrokerPathsError.unsafeRuntimeDirectory) {
            try runtimeMode.paths.prepare()
        }
        let runtimeModeMetadata = try DatabaseBrokerPathsFixtures.metadata(
            runtimeMode.paths.runtimeDirectory)
        #expect(runtimeModeMetadata.st_mode & mode_t(0o7777) == mode_t(0o755))

        let runtimeSymlink = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: runtimeSymlink.root) }
        let runtimeTarget = runtimeSymlink.root.appendingPathComponent("runtime-target")
        try DatabaseBrokerPathsFixtures.createDirectory(runtimeTarget)
        try FileManager.default.createSymbolicLink(
            at: runtimeSymlink.paths.runtimeDirectory,
            withDestinationURL: runtimeTarget)
        #expect(throws: DatabaseBrokerPathsError.unsafeRuntimeDirectory) {
            try runtimeSymlink.paths.prepare()
        }
        let runtimeSymlinkMetadata = try DatabaseBrokerPathsFixtures.metadata(
            runtimeSymlink.paths.runtimeDirectory)
        #expect(runtimeSymlinkMetadata.st_mode & S_IFMT == S_IFLNK)
    }

    @Test func rejectsSymlinkedDirectoryAncestors() throws {
        let fixture = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let realHome = fixture.root.appendingPathComponent("real-home")
        try DatabaseBrokerPathsFixtures.createDirectory(realHome)
        let realDirectories = AppDirectories(homeDirectory: realHome)
        try realDirectories.prepare()
        let linkedHome = fixture.root.appendingPathComponent("linked-home")
        try FileManager.default.createSymbolicLink(
            at: linkedHome,
            withDestinationURL: realHome)
        let linkedPaths = DatabaseBrokerPaths(
            directories: AppDirectories(homeDirectory: linkedHome))

        #expect(throws: DatabaseBrokerPathsError.unsafeDataDirectory) {
            try linkedPaths.prepare()
        }
        let linkedHomeMetadata = try DatabaseBrokerPathsFixtures.metadata(linkedHome)
        #expect(linkedHomeMetadata.st_mode & S_IFMT == S_IFLNK)
        #expect(!FileManager.default.fileExists(atPath: linkedPaths.dataDirectory.path))

        let runtimeAncestor = fixture.root.appendingPathComponent("runtime-ancestor")
        try DatabaseBrokerPathsFixtures.createDirectory(runtimeAncestor)
        let linkedRuntimeAncestor = fixture.root.appendingPathComponent("linked-runtime-ancestor")
        try FileManager.default.createSymbolicLink(
            at: linkedRuntimeAncestor,
            withDestinationURL: runtimeAncestor)
        let runtimePaths = DatabaseBrokerPaths(
            dataDirectory: fixture.paths.dataDirectory,
            runtimeDirectory: linkedRuntimeAncestor.appendingPathComponent("database"))

        #expect(throws: DatabaseBrokerPathsError.unsafeRuntimeDirectory) {
            try runtimePaths.prepare()
        }
        let linkedRuntimeMetadata = try DatabaseBrokerPathsFixtures.metadata(
            linkedRuntimeAncestor)
        #expect(linkedRuntimeMetadata.st_mode & S_IFMT == S_IFLNK)
        #expect(
            !FileManager.default.fileExists(
                atPath: runtimeAncestor.appendingPathComponent("database").path))
    }

    @Test func rejectsAndPreservesUnsafeMetadataTargets() throws {
        let symlink = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: symlink.root) }
        try DatabaseBrokerPathsFixtures.createDirectory(symlink.paths.dataDirectory)
        let symlinkTarget = symlink.root.appendingPathComponent("metadata-target")
        try DatabaseBrokerPathsFixtures.createFile(
            symlinkTarget,
            contents: "preserved")
        try FileManager.default.createSymbolicLink(
            at: symlink.paths.metadataFile,
            withDestinationURL: symlinkTarget)
        #expect(throws: DatabaseBrokerPathsError.unsafeMetadataFile) {
            try symlink.paths.prepare()
        }
        let symlinkMetadata = try DatabaseBrokerPathsFixtures.metadata(
            symlink.paths.metadataFile)
        #expect(symlinkMetadata.st_mode & S_IFMT == S_IFLNK)
        #expect(try String(contentsOf: symlinkTarget, encoding: .utf8) == "preserved")

        let wrongMode = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: wrongMode.root) }
        try DatabaseBrokerPathsFixtures.createDirectory(wrongMode.paths.dataDirectory)
        try DatabaseBrokerPathsFixtures.createFile(
            wrongMode.paths.metadataFile,
            mode: mode_t(0o644))
        #expect(throws: DatabaseBrokerPathsError.unsafeMetadataFile) {
            try wrongMode.paths.prepare()
        }
        let wrongModeMetadata = try DatabaseBrokerPathsFixtures.metadata(
            wrongMode.paths.metadataFile)
        #expect(wrongModeMetadata.st_mode & mode_t(0o7777) == mode_t(0o644))

        let nonregular = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: nonregular.root) }
        try DatabaseBrokerPathsFixtures.createDirectory(nonregular.paths.dataDirectory)
        try DatabaseBrokerPathsFixtures.createDirectory(nonregular.paths.metadataFile)
        #expect(throws: DatabaseBrokerPathsError.unsafeMetadataFile) {
            try nonregular.paths.prepare()
        }
        let nonregularMetadata = try DatabaseBrokerPathsFixtures.metadata(
            nonregular.paths.metadataFile)
        #expect(nonregularMetadata.st_mode & S_IFMT == S_IFDIR)

        let linked = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: linked.root) }
        try DatabaseBrokerPathsFixtures.createDirectory(linked.paths.dataDirectory)
        try DatabaseBrokerPathsFixtures.createFile(linked.paths.metadataFile)
        let secondLink = linked.paths.dataDirectory.appendingPathComponent("metadata-second-link")
        guard link(linked.paths.metadataFile.path, secondLink.path) == 0 else {
            throw DatabaseBrokerPathsTestError.fixtureFailure
        }
        #expect(throws: DatabaseBrokerPathsError.unsafeMetadataFile) {
            try linked.paths.prepare()
        }
        let linkedMetadata = try DatabaseBrokerPathsFixtures.metadata(linked.paths.metadataFile)
        #expect(linkedMetadata.st_nlink == 2)
        #expect(FileManager.default.fileExists(atPath: secondLink.path))
    }

    @Test func detectsDirectoryAndMetadataReplacement() throws {
        let data = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: data.root) }
        let movedData = data.root.appendingPathComponent("opened-data")
        #expect(throws: DatabaseBrokerPathsError.unsafeDataDirectory) {
            try data.paths.prepare { stage in
                guard case .dataDirectoryOpened = stage else { return }
                try DatabaseBrokerPathsFixtures.move(data.paths.dataDirectory, to: movedData)
                try DatabaseBrokerPathsFixtures.createDirectory(data.paths.dataDirectory)
            }
        }

        let metadata = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: metadata.root) }
        let movedMetadata = metadata.root.appendingPathComponent("opened-metadata")
        #expect(throws: DatabaseBrokerPathsError.unsafeMetadataFile) {
            try metadata.paths.prepare { stage in
                guard case .metadataFileOpened = stage else { return }
                try DatabaseBrokerPathsFixtures.move(
                    metadata.paths.metadataFile,
                    to: movedMetadata)
                try DatabaseBrokerPathsFixtures.createFile(metadata.paths.metadataFile)
            }
        }

        let runtime = try DatabaseBrokerPathsFixtures.make()
        defer { try? FileManager.default.removeItem(at: runtime.root) }
        let movedRuntime = runtime.root.appendingPathComponent("opened-runtime")
        #expect(throws: DatabaseBrokerPathsError.unsafeRuntimeDirectory) {
            try runtime.paths.prepare { stage in
                guard case .runtimeDirectoryOpened = stage else { return }
                try DatabaseBrokerPathsFixtures.move(
                    runtime.paths.runtimeDirectory,
                    to: movedRuntime)
                try DatabaseBrokerPathsFixtures.createDirectory(runtime.paths.runtimeDirectory)
            }
        }
    }
}
