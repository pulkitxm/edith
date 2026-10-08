import CryptoKit
import Foundation
import Testing
import ZIPFoundation
@testable import ExtensionMarketplace

struct PackageFixture {
    let directory: URL
    let store: ExtensionPackageStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "extension-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = ExtensionPackageStore(root: directory.appendingPathComponent("installed"))
    }

    func clean() { try? FileManager.default.removeItem(at: directory) }

    func archive(
        _ version: String = "1.0.0", hostABI: String = "host-1", id: String = "keepAwake",
        unsafePath: String? = nil, symlink: Bool = false
    ) throws -> (ExtensionPackage, URL) {
        let placeholder = fixturePackage(id, version: version, hostABI: hostABI)
        let manifest = try JSONEncoder().encode(ExtensionPayloadManifest(package: placeholder))
        let source = directory.appendingPathComponent(
            "\(id)-\(hostABI)-\(version)-\(UUID().uuidString).zip")
        let zip = try Archive(url: source, accessMode: .create)
        let entries: [(String, Data)] = [
            ("\(id)/package.json", manifest),
            (
                unsafePath ?? "\(id)/helper.bundle/Contents/MacOS/Runtime",
                Data("fixture runtime \(version)".utf8)
            ),
        ]
        for (path, bytes) in entries {
            try zip.addEntry(
                with: path, type: symlink && path != entries[0].0 ? .symlink : .file,
                uncompressedSize: Int64(bytes.count)
            ) { offset, count in
                bytes.subdata(in: Int(offset)..<min(Int(offset) + count, bytes.count))
            }
        }
        let data = try Data(contentsOf: source)
        let package = ExtensionPackage(
            id: id, version: version, hostABI: hostABI, downloadURL: placeholder.downloadURL,
            sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
            downloadBytes: Int64(data.count),
            installedBytes: Int64(entries.reduce(0) { $0 + $1.1.count }))
        return (package, source)
    }

    func installer(archives: [URL: URL], rejectsSignature: Bool = false)
        -> ExtensionPackageInstaller
    {
        ExtensionPackageInstaller(
            store: store,
            download: { url, _ in
                guard let archive = archives[url] else { throw MarketplaceError.downloadFailed }
                let copy = FileManager.default.temporaryDirectory.appendingPathComponent(
                    UUID().uuidString)
                try FileManager.default.copyItem(at: archive, to: copy)
                return copy
            },
            verify: { _ in
                if rejectsSignature { throw MarketplaceError.invalidSignature }
            })
    }
}

@Test func installingUpdatingAndUninstallingPreservesPreviousVersions() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (first, firstArchive) = try fixture.archive()
    let (second, secondArchive) = try fixture.archive("1.1.0")
    let installer = fixture.installer(archives: [
        first.downloadURL: firstArchive, second.downloadURL: secondArchive,
    ])
    _ = try await installer.install([first], repository: "example/app")
    #expect(
        try fixture.store.installedPackage(id: first.id, hostABI: "host-1", architecture: "arm64")
            == first)
    _ = try await installer.install([second], repository: "example/app")
    #expect(
        try fixture.store.installedPackage(id: first.id, hostABI: "host-1", architecture: "arm64")
            == second)
    #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: first).path))
    #expect(fixture.store.diskBytes() > 0)
    #expect(try fixture.store.remove(id: first.id))
    #expect(try fixture.store.installedPackages().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: first).path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: second).path))
}

@Test func failedUpdatesKeepTheWorkingVersion() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (first, archive) = try fixture.archive()
    _ = try await fixture.installer(archives: [first.downloadURL: archive]).install(
        [first], repository: "example/app")
    let (second, _) = try fixture.archive("1.1.0")
    await #expect(throws: MarketplaceError.downloadFailed) {
        try await fixture.installer(archives: [:]).install([second], repository: "example/app")
    }
    #expect(
        try fixture.store.installedPackage(id: first.id, hostABI: "host-1", architecture: "arm64")
            == first)
    #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: first).path))
}

@Test func aRejectedDependencySetIsNotPartiallyCommitted() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (first, archive) = try fixture.archive()
    let (second, _) = try fixture.archive(id: "calendar")
    await #expect(throws: MarketplaceError.downloadFailed) {
        try await fixture.installer(archives: [first.downloadURL: archive]).install(
            [first, second], repository: "example/app")
    }
    #expect(try fixture.store.installedPackages().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: first).path))
}

@Test func appUpdatesRetainPackagesForBothHostVersions() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (old, oldArchive) = try fixture.archive()
    let (new, newArchive) = try fixture.archive("2.0.0", hostABI: "host-2")
    _ = try await fixture.installer(archives: [
        old.downloadURL: oldArchive, new.downloadURL: newArchive,
    ]).install([old], repository: "example/app")
    _ = try await fixture.installer(archives: [
        old.downloadURL: oldArchive, new.downloadURL: newArchive,
    ]).install([new], repository: "example/app")
    #expect(
        try fixture.store.installedPackage(id: old.id, hostABI: "host-1", architecture: "arm64")
            == old)
    #expect(
        try fixture.store.installedPackage(id: new.id, hostABI: "host-2", architecture: "arm64")
            == new)
}

@Test func offlineInstalledPackagesDoNotDownloadAgain() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (package, archive) = try fixture.archive()
    _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
        [package], repository: "example/app")
    _ = try await fixture.installer(archives: [:]).install([package], repository: "example/app")
    #expect(try fixture.store.installedPackages() == [package])
}

@Test func rejectedPublisherNeverInstalls() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (package, archive) = try fixture.archive()
    await #expect(throws: MarketplaceError.invalidSignature) {
        try await fixture.installer(
            archives: [package.downloadURL: archive], rejectsSignature: true
        ).install([package], repository: "example/app")
    }
    #expect(try fixture.store.installedPackages().isEmpty)
}

@Test func corruptDownloadsNeverInstall() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (package, archive) = try fixture.archive()
    var data = try Data(contentsOf: archive)
    data[20] ^= 1
    try data.write(to: archive)
    await #expect(throws: MarketplaceError.checksumMismatch) {
        try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
    }
    #expect(try fixture.store.installedPackages().isEmpty)
}

@Test(arguments: [
    "keepAwake/../../outside", "/keepAwake/outside", "other/helper.bundle/file",
    "keepAwake/..\\outside",
])
func unsafeArchivesNeverWriteOutsideTheStagingArea(_ path: String) async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (package, archive) = try fixture.archive(unsafePath: path)
    await #expect(throws: MarketplaceError.invalidArchive) {
        try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
    }
    #expect(try fixture.store.installedPackages().isEmpty)
    #expect(
        !FileManager.default.fileExists(
            atPath: fixture.directory.appendingPathComponent("outside").path))
}

@Test func archiveSymlinksAreRejected() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (package, archive) = try fixture.archive(symlink: true)
    await #expect(throws: MarketplaceError.invalidArchive) {
        try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
    }
}

@Test func inUsePackagesCannotBeDeleted() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (package, archive) = try fixture.archive()
    _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
        [package], repository: "example/app")
    let lease = try fixture.store.lease(package)
    #expect(throws: MarketplaceError.packageBusy) { try fixture.store.remove(id: package.id) }
    #expect(try fixture.store.installedPackages() == [package])
    lease.close()
    #expect(try fixture.store.remove(id: package.id))
}

@Test func concurrentProcessesCannotChangeTheInstalledState() throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let first = try PackageFileLock(
        url: fixture.store.root.appendingPathComponent(".operation.lock"), exclusive: true)
    defer { first.close() }
    #expect(throws: MarketplaceError.packageBusy) {
        try PackageFileLock(
            url: fixture.store.root.appendingPathComponent(".operation.lock"), exclusive: true)
    }
}
