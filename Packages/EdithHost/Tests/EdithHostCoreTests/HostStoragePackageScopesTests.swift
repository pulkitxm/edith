import Darwin
import Foundation
import Testing

@testable import EdithHostCore

struct HostStoragePackageScopesTests {
    @Test func roleAndCameraCopiesAreIncludedExactlyOnce() throws {
        let root = try syntheticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let layout = HostStoragePackageScopes(
            key: "fixture", directory: root, extensionID: "virtualCamera",
            roles: ["app", "helper", "agent", "cli", "privileged"])
        let paths = [
            "virtualCamera/ExtensionCarrier.app/Contents/MacOS/Edith",
            "virtualCamera/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith",
            "virtualCamera/ExtensionCarrier.app/Contents/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/virtualCamera/app.bundle/Contents/MacOS/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/MacOS/Edith",
            "virtualCamera/CameraCarrier.app/Contents/Frameworks/Contained.framework/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/cameraCarrier.bundle/Contents/MacOS/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/cameraCarrier.bundle/Contents/Frameworks/Contained.framework/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/privileged.bundle/Contents/MacOS/Runtime",
            "virtualCamera/CameraCarrier.app/Contents/PlugIns/privileged.bundle/Contents/Frameworks/Contained.framework/Runtime",
            "virtualCamera/package.json",
        ]
        for (index, path) in paths.enumerated() {
            let file = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 65, count: (index + 1) * 100).write(to: file)
        }
        let measurement = try HostStorageAccounting.scan(scopes: layout.scopes)
        expectReadable(measurement, root: root)
        let executables = layout.executableScopeIDs.reduce(Int64(0)) {
            $0 + (measurement.bytes[$1]?.logical ?? 0)
        }
        let frameworks = layout.frameworkScopeIDs.reduce(Int64(0)) {
            $0 + (measurement.bytes[$1]?.logical ?? 0)
        }
        #expect(executables == 2400)
        #expect(frameworks == 2100)
        #expect(measurement.bytes["fixture"]?.logical == 1000)
        #expect(measurement.total.logical == 5500)
        #expect(measurement.total.complete)
        #expect(Set(layout.scopes.map(\.id)).count == layout.scopes.count)
    }

    @Test func sharedHistoryIsMeasuredOnceWithoutAssigningItToOneExtension() throws {
        let root = try syntheticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = try write(root, "data/downloads.json", count: 700)
        _ = try write(root, "data/usage.json", count: 300)
        _ = try write(root, "other-host-record", count: 100)
        let layout = HostStorageDataScopes(
            scopes: [
                .init(id: "host", root: root),
                .init(id: "usage", root: root.appendingPathComponent("data")),
                .init(id: "music-history", root: file),
                .init(id: "downloads-history", root: file),
            ],
            owners: [
                "usage": ["usage"], "music": ["music-history"], "downloads": ["downloads-history"],
            ])
        let measurement = try HostStorageAccounting.scan(scopes: layout.scopes)
        expectReadable(measurement, root: root)
        #expect(layout.ownedIDs["music"] == [])
        #expect(layout.ownedIDs["downloads"] == [])
        #expect(layout.sharedIDs["music"] == layout.sharedIDs["downloads"])
        #expect(layout.sharedScopeIDs.count == 1)
        #expect(measurement.bytes[layout.sharedScopeIDs[0]]?.logical == 700)
        #expect(measurement.bytes["usage"]?.logical == 300)
        #expect(measurement.bytes["host"]?.logical == 100)
        #expect(measurement.total.logical == 1100)
        #expect(measurement.total.complete)
    }

    @Test func allPackagesRollbackCopiesAndTransientFilesRemainExclusiveDuringDeletion() throws {
        let root = try syntheticRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try write(root, "App/Contents/MacOS/Edith", count: 1000)
        _ = try write(root, "Data/saved-agent-session", count: 701)
        _ = try write(root, "Data/shared-history", count: 702)
        _ = try write(root, "Packages/.downloads/archive.zip", count: 703)
        _ = try write(root, "Packages/.staging/transient", count: 704)
        var scopes: [HostStorageScope] = [
            .init(id: "app", root: root.appendingPathComponent("App"), expected: true),
            .init(id: "data", root: root.appendingPathComponent("Data")),
            .init(id: "cache", root: root.appendingPathComponent("Packages")),
        ]
        var packageIDs: [String] = []
        var removeURLs: [URL] = []
        for number in 0..<39 {
            for version in number == 0 ? [1, 2] : [2] {
                let id = "synthetic\(number)"
                let directory = root.appendingPathComponent("Packages/\(id)/\(version)")
                let layout = HostStoragePackageScopes(
                    key: id + ":" + String(version), directory: directory, extensionID: id,
                    roles: ["app", "cli"])
                scopes += layout.scopes
                packageIDs += layout.scopes.map(\.id)
                let prefix = "Packages/\(id)/\(version)/\(id)/ExtensionCarrier.app/Contents"
                _ = try write(root, prefix + "/MacOS/Edith", count: 100)
                _ = try write(
                    root, prefix + "/Extensions/ExtensionWorker.appex/Contents/MacOS/Edith",
                    count: 200)
                _ = try write(
                    root,
                    prefix
                        + "/Extensions/ExtensionWorker.appex/Contents/Resources/Payload/\(id)/app.bundle/Contents/MacOS/Runtime",
                    count: 300)
                _ = try write(root, "Packages/\(id)/\(version)/package.json", count: 400)
                if number == 0 { removeURLs.append(directory) }
            }
        }
        let before = try HostStorageAccounting.scan(scopes: scopes)
        expectReadable(before, root: root)
        let packageBytes = packageIDs.reduce(Int64(0)) { $0 + (before.bytes[$1]?.logical ?? 0) }
        #expect(packageBytes == 40_000)
        #expect(before.bytes["cache"]?.logical == 1407)
        #expect(before.bytes["data"]?.logical == 1403)
        #expect(before.total.logical == 43_810)
        #expect(before.total.complete)
        for directory in removeURLs { try FileManager.default.removeItem(at: directory) }
        let remainingScopes = scopes.filter { scope in
            !removeURLs.contains { scope.root == $0 || scope.root.path.hasPrefix($0.path + "/") }
        }
        let after = try HostStorageAccounting.scan(scopes: remainingScopes)
        expectReadable(after, root: root)
        #expect(before.total.logical - after.total.logical == 2000)
        #expect(after.bytes["data"] == before.bytes["data"])
        #expect(after.bytes["cache"]?.logical == before.bytes["cache"]?.logical)
        #expect(after.total.complete)
        #expect(
            try Data(contentsOf: root.appendingPathComponent("Data/saved-agent-session")).count
                == 701)
        #expect(
            try Data(contentsOf: root.appendingPathComponent("Data/shared-history")).count == 702)
    }

    @Test func ownedSymlinkTemporaryDirectoryProducesCanonicalReadableRoot() throws {
        let parent = try syntheticRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        let target = parent.appendingPathComponent("actual-temp")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        let alias = parent.appendingPathComponent("linked-temp")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: target)
        let root = try syntheticRoot(temporaryDirectory: alias)
        #expect(root.deletingLastPathComponent().path == target.path)
        #expect(!root.path.hasPrefix(alias.path + "/"))
        _ = try write(root, "owned-record", count: 321)
        let measurement = try HostStorageAccounting.scan(scopes: [.init(id: "owned", root: root)])
        expectReadable(measurement, root: root)
        #expect(measurement.bytes["owned"]?.logical == 321)
        #expect(measurement.total.complete)
    }

    private func syntheticRoot(temporaryDirectory: URL? = nil) throws -> URL {
        let temporaryDirectory =
            temporaryDirectory
            ?? URL(
                fileURLWithPath: ProcessInfo.processInfo.environment["TMPDIR"]
                    ?? NSTemporaryDirectory())
        let root = temporaryDirectory.appendingPathComponent(
            "synthetic-storage-" + UUID().uuidString)
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let canonical = root.path.withCString({ realpath($0, nil) }) else {
            let error = POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
            try? FileManager.default.removeItem(at: root)
            throw error
        }
        defer { free(canonical) }
        return URL(fileURLWithPath: String(cString: canonical), isDirectory: true)
    }

    private func expectReadable(_ measurement: HostStorageMeasurement, root: URL) {
        let diagnostic = Comment(
            rawValue: "owned root: \(root.path); storage issues: \(measurement.issues)")
        #expect(measurement.issues.isEmpty, diagnostic)
        #expect(measurement.total.exists, diagnostic)
        #expect(measurement.total.allocated > 0, diagnostic)
    }

    private func write(_ root: URL, _ path: String, count: Int) throws -> URL {
        let file = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: count).write(to: file)
        return file
    }
}
