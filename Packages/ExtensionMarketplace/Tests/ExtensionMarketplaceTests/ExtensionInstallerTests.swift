import CryptoKit
import Foundation
import Testing
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
        unsafePath: String? = nil, symlink: Bool = false, carrier: Bool = false
    ) throws -> (ExtensionPackage, URL) {
        let placeholder = fixturePackage(id, version: version, hostABI: hostABI)
        let manifest = try JSONEncoder().encode(ExtensionPayloadManifest(package: placeholder))
        let source = directory.appendingPathComponent(
            "\(id)-\(hostABI)-\(version)-\(UUID().uuidString).zip")
        let zip = try Archive(url: source, accessMode: .create)
        var entries: [(String, Data)] = [
            ("\(id)/package.json", manifest),
            (
                unsafePath ?? "\(id)/helper.bundle/Contents/MacOS/Runtime",
                Data("fixture runtime \(version)".utf8)
            ),
        ]
        if carrier {
            entries.append(
                (
                    "\(id)/CameraCarrier.app/Contents/MacOS/Edith",
                    Data("sealed fixture carrier".utf8)
                ))
        }
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

@Test func pruningRetainsRollbackAndEveryPackageStillInUse() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let first = try fixture.archive("1.0.0")
    let second = try fixture.archive("1.1.0")
    let third = try fixture.archive("1.2.0")
    let fourth = try fixture.archive("1.3.0")
    let installer = fixture.installer(
        archives: Dictionary(
            uniqueKeysWithValues: [first, second, third, fourth].map { ($0.0.downloadURL, $0.1) }))
    for item in [first, second, third, fourth] {
        _ = try await installer.install([item.0], repository: "example/app")
    }
    let lease = try fixture.store.lease(first.0)
    try fixture.store.prune(hostABI: "host-1")
    #expect(
        try fixture.store.installedPackages().map(\.version).sorted() == [
            "1.0.0", "1.2.0", "1.3.0",
        ])
    lease.close()
    try fixture.store.prune(hostABI: "host-1")
    #expect(try fixture.store.installedPackages().map(\.version).sorted() == ["1.2.0", "1.3.0"])
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: first.0).path))
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: second.0).path))
}

@Test func installedSelectionAndPruningRespectTheRunningSystem() throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let old = fixturePackage("keepAwake", version: "1.0.0", hostABI: "host-1")
    let future = ExtensionPackage(
        id: old.id, version: "2.0.0", hostABI: old.hostABI, minimumSystemVersion: 15,
        downloadURL: old.downloadURL, sha256: old.sha256, downloadBytes: 1, installedBytes: 1)
    try FileManager.default.createDirectory(
        at: fixture.store.root, withIntermediateDirectories: true)
    try fixture.store.commit([old, future])
    try fixture.store.select(future)
    #expect(
        try fixture.store.installedPackage(
            id: old.id, hostABI: old.hostABI, architecture: "arm64", systemVersion: 14) == old)
    #expect(
        try fixture.store.installedPackage(
            id: old.id, hostABI: old.hostABI, architecture: "arm64", systemVersion: 15) == future)
    #expect(
        try fixture.store.installedPackage(
            id: old.id, hostABI: old.hostABI, architecture: "arm64", version: future.version,
            systemVersion: 14) == nil)
    try fixture.store.prune(hostABI: old.hostABI, systemVersion: 14)
    #expect(try fixture.store.installedPackages() == [old])
}

@Test func removalWaitsForTheLoadedProcessAndCompletesOnNextLaunch() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (package, archive) = try fixture.archive()
    _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
        [package], repository: "example/app")
    let lease = try fixture.store.lease(package)
    #expect(try fixture.store.requestRemoval(id: package.id) == false)
    #expect(try fixture.store.pendingRemovals() == [package.id])
    try fixture.store.completePendingRemovals()
    #expect(try fixture.store.installedPackages() == [package])
    lease.close()
    try fixture.store.completePendingRemovals()
    #expect(try fixture.store.installedPackages().isEmpty)
    #expect(try fixture.store.pendingRemovals().isEmpty)
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
}

@Test func appUpdatesBoundIncompatibleCopiesUntilACompatibleReplacementArrives() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let first = try fixture.archive("1.0.0", hostABI: "host-1")
    let second = try fixture.archive("1.1.0", hostABI: "host-2")
    let third = try fixture.archive("1.2.0", hostABI: "host-3")
    let current = try fixture.archive("2.0.0", hostABI: "host-4")
    let items = [first, second, third, current]
    let installer = fixture.installer(
        archives: Dictionary(uniqueKeysWithValues: items.map { ($0.0.downloadURL, $0.1) }))
    for item in [first, second, third] {
        _ = try await installer.install([item.0], repository: "example/app")
    }
    try fixture.store.prune(hostABI: "host-4")
    #expect(try fixture.store.installedPackages().map(\.version).sorted() == ["1.1.0", "1.2.0"])
    let lease = try fixture.store.lease(second.0)
    _ = try await installer.install([current.0], repository: "example/app")
    try fixture.store.prune(hostABI: "host-4")
    #expect(try fixture.store.installedPackages().map(\.version).sorted() == ["1.1.0", "2.0.0"])
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: third.0).path))
    lease.close()
    try fixture.store.prune(hostABI: "host-4")
    #expect(try fixture.store.installedPackages() == [current.0])
    #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: second.0).path))
}

@Test func sealedCameraCarrierIsAcceptedOnlyForItsOwningPackage() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (camera, cameraArchive) = try fixture.archive(id: "virtualCamera", carrier: true)
    _ = try await fixture.installer(archives: [camera.downloadURL: cameraArchive]).install(
        [camera], repository: "example/app")
    #expect(
        FileManager.default.fileExists(
            atPath: fixture.store.directory(for: camera)
                .appendingPathComponent("virtualCamera/CameraCarrier.app/Contents/MacOS/Edith").path
        ))
    let (other, otherArchive) = try fixture.archive(id: "calendar", carrier: true)
    await #expect(throws: MarketplaceError.invalidArchive) {
        try await fixture.installer(archives: [other.downloadURL: otherArchive]).install(
            [other], repository: "example/app")
    }
    #expect(try fixture.store.installedPackages() == [camera])
}

@Test func carrierSymlinksRemainRejected() async throws {
    let fixture = try PackageFixture()
    defer { fixture.clean() }
    let (camera, archive) = try fixture.archive(id: "virtualCamera", symlink: true, carrier: true)
    await #expect(throws: MarketplaceError.invalidArchive) {
        try await fixture.installer(archives: [camera.downloadURL: archive]).install(
            [camera], repository: "example/app")
    }
    #expect(try fixture.store.installedPackages().isEmpty)
}
