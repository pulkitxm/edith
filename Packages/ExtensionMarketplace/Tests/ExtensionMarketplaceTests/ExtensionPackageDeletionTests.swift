import Darwin
import Foundation
import Testing
@testable import ExtensionMarketplace

struct ExtensionPackageDeletionTests {
    private func installedFixture() async throws -> (PackageFixture, ExtensionPackage) {
        let fixture = try PackageFixture()
        let (package, archive) = try fixture.archive(runtime: "original payload")
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        try fixture.store.select(package)
        return (fixture, package)
    }

    private func intent(_ fixture: PackageFixture) -> URL {
        fixture.store.root.appendingPathComponent("package-deletions.json")
    }

    private func path(_ package: ExtensionPackage) -> String {
        "\(package.id)/\(package.hostABI)/\(package.architecture)/\(package.version)"
    }

    @Test(arguments: [0, 1, 2, 3, 4])
    func interruptedRemovalRecoversAtEveryCommitBoundary(_ boundary: Int) async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        let checkpoints: [PackageDeletionCheckpoint] = [
            .intentWritten, .installedWritten, .selectionsWritten,
            .payloadRemoved(path(package)), .beforeIntentRemoval,
        ]
        let checkpoint = checkpoints[boundary]
        var store = fixture.store
        store.deletionCheckpoint = { current in
            if current == checkpoint { throw POSIXError(.EINTR) }
        }
        if boundary == 0 {
            #expect(throws: POSIXError.self) { try store.remove(id: package.id) }
            #expect(try store.installedPackages() == [package])
        } else {
            #expect(throws: MarketplaceError.packageCleanupPending) {
                try store.remove(id: package.id)
            }
            #expect(try store.installedPackages().isEmpty)
            #expect(
                try store.installedPackage(id: package.id, hostABI: "host-1", architecture: "arm64")
                    == nil)
        }
        #expect(FileManager.default.fileExists(atPath: intent(fixture).path))
        let restarted = ExtensionPackageStore(root: store.root)
        try restarted.recoverPackageDeletions()
        #expect(!FileManager.default.fileExists(atPath: intent(fixture).path))
        #expect(
            FileManager.default.fileExists(atPath: store.directory(for: package).path)
                == (boundary == 0))
        #expect(try restarted.installedPackages() == (boundary == 0 ? [package] : []))
        try restarted.recoverPackageDeletions()
    }

    @Test(arguments: ["intent", "installed", "selected"])
    func failedMetadataWritesPreserveCoherentAuthorityAndRetry(_ name: String) async throws {
        try #require(geteuid() != 0)
        let (fixture, package) = try await installedFixture()
        defer {
            _ = chmod(fixture.store.root.path, 0o700)
            fixture.clean()
        }
        let metadata = fixture.store.root.appendingPathComponent("installed.json")
        let selected = fixture.store.root.appendingPathComponent("selected-packages.json")
        let originalMetadata = try Data(contentsOf: metadata)
        let originalSelection = try Data(contentsOf: selected)
        var store = fixture.store
        if name == "intent" {
            #expect(chmod(store.root.path, 0o500) == 0)
        } else {
            let checkpoint: PackageDeletionCheckpoint =
                name == "installed" ? .intentWritten : .installedWritten
            store.deletionCheckpoint = { current in
                if current == checkpoint { #expect(chmod(fixture.store.root.path, 0o500) == 0) }
            }
        }
        if name == "selected" {
            #expect(throws: MarketplaceError.packageCleanupPending) {
                try store.remove(id: package.id)
            }
            #expect(try store.installedPackages().isEmpty)
        } else {
            #expect(throws: POSIXError.self) { try store.remove(id: package.id) }
            #expect(try Data(contentsOf: metadata) == originalMetadata)
        }
        #expect(try Data(contentsOf: selected) == originalSelection)
        #expect(FileManager.default.fileExists(atPath: store.directory(for: package).path))
        #expect(chmod(store.root.path, 0o700) == 0)
        let restarted = ExtensionPackageStore(root: store.root)
        try restarted.recoverPackageDeletions()
        #expect(try restarted.installedPackages() == (name == "selected" ? [] : [package]))
        #expect(
            FileManager.default.fileExists(atPath: store.directory(for: package).path)
                == (name != "selected"))
        #expect(!FileManager.default.fileExists(atPath: intent(fixture).path))
    }

    @Test func recoveryRetainsReinstalledPayloadAtTheSameLocation() async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        var interrupted = fixture.store
        interrupted.deletionCheckpoint = { checkpoint in
            if checkpoint == .installedWritten { throw POSIXError(.EINTR) }
        }
        #expect(throws: MarketplaceError.packageCleanupPending) {
            try interrupted.remove(id: package.id)
        }
        let (replacement, archive) = try fixture.archive(runtime: "reinstalled payload")
        #expect(package != replacement)
        _ = try await fixture.installer(archives: [replacement.downloadURL: archive]).install(
            [replacement], repository: "example/app")
        try fixture.store.select(replacement)
        try fixture.store.recoverPackageDeletions()
        #expect(try fixture.store.installedPackages() == [replacement])
        #expect(
            try fixture.store.installedPackage(
                id: package.id, hostABI: "host-1", architecture: "arm64") == replacement)
        let runtime = fixture.store.directory(for: replacement).appendingPathComponent(
            replacement.id + "/helper.bundle/Contents/MacOS/Runtime")
        #expect(try Data(contentsOf: runtime) == Data("reinstalled payload".utf8))
        #expect(!FileManager.default.fileExists(atPath: intent(fixture).path))
    }

    @Test func recoveryDefersEveryPayloadWhileAnyDeletionLeaseIsLive() async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        let (second, archive) = try fixture.archive("2.0.0")
        _ = try await fixture.installer(archives: [second.downloadURL: archive]).install(
            [second], repository: "example/app")
        var interrupted = fixture.store
        interrupted.deletionCheckpoint = { checkpoint in
            if checkpoint == .installedWritten { throw POSIXError(.EINTR) }
        }
        #expect(throws: MarketplaceError.packageCleanupPending) {
            try interrupted.remove(id: package.id)
        }
        let lease = try fixture.store.lease(second)
        #expect(throws: MarketplaceError.packageCleanupPending) {
            try fixture.store.recoverPackageDeletions()
        }
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: second).path))
        #expect(FileManager.default.fileExists(atPath: intent(fixture).path))
        lease.close()
        try fixture.store.recoverPackageDeletions()
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: second).path))
    }

    @Test(arguments: [
        "unknown", "duplicate", "path", "noncanonical", "malformed", "writable", "symlink",
        "hardlink", "unsorted",
    ])
    func malformedOrUntrustedIntentNeverDeletesPayloads(_ kind: String) async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        try fixture.store.commit([])
        var location = [
            "id": package.id, "hostABI": package.hostABI, "architecture": package.architecture,
            "version": package.version,
        ]
        if kind == "unknown" { location["extra"] = "unexpected" }
        if kind == "path" { location["id"] = "../Data" }
        var locations = kind == "duplicate" ? [location, location] : [location]
        if kind == "unsorted" {
            var other = location
            other["id"] = "calendar"
            locations.append(other)
        }
        var data = try JSONSerialization.data(
            withJSONObject: locations, options: [.sortedKeys, .withoutEscapingSlashes])
        if kind == "noncanonical" { data.append(Data("\n".utf8)) }
        if kind == "malformed" { data = Data("[".utf8) }
        try data.write(to: intent(fixture))
        if kind == "writable" { #expect(chmod(intent(fixture).path, 0o666) == 0) }
        if kind == "symlink" || kind == "hardlink" {
            let outside = fixture.directory.appendingPathComponent("retained-intent")
            try FileManager.default.moveItem(at: intent(fixture), to: outside)
            if kind == "symlink" {
                try FileManager.default.createSymbolicLink(
                    at: intent(fixture), withDestinationURL: outside)
            } else {
                try FileManager.default.linkItem(at: outside, to: intent(fixture))
            }
        }
        #expect(throws: (any Error).self) { try fixture.store.recoverPackageDeletions() }
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
        #expect(try Data(contentsOf: intent(fixture)) == data)
    }

    @Test(arguments: ["remove", "prune"])
    func deletionHoldsAllCandidateLeasesUntilMetadataCommitsAndRecovers(_ action: String)
        async throws
    {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        var packages: [ExtensionPackage] = []
        for version in ["1.0.0", "2.0.0", "3.0.0", "4.0.0"] {
            let (package, archive) = try fixture.archive(version)
            _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
                [package], repository: "example/app")
            packages.append(package)
        }
        let removed = action == "remove" ? packages : Array(packages.prefix(2))
        let retained = action == "remove" ? [] : Array(packages.suffix(2))
        var store = fixture.store
        store.deletionCheckpoint = { checkpoint in
            if checkpoint == .installedWritten {
                for package in removed {
                    #expect(throws: MarketplaceError.packageBusy) {
                        try fixture.store.lease(package)
                    }
                }
                throw POSIXError(.EINTR)
            }
        }
        #expect(throws: MarketplaceError.packageCleanupPending) {
            if action == "remove" {
                _ = try store.remove(id: "keepAwake")
            } else {
                try store.prune(hostABI: "host-1")
            }
        }
        #expect(try store.installedPackages() == retained)
        for package in removed {
            #expect(FileManager.default.fileExists(atPath: store.directory(for: package).path))
        }
        try fixture.store.recoverPackageDeletions()
        for package in removed {
            #expect(!FileManager.default.fileExists(atPath: store.directory(for: package).path))
        }
        #expect(try store.installedPackages() == retained)
    }

    @Test func identicalInstallCancelsQueuedRemovalBeforeVerification() async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        let lease = try fixture.store.lease(package)
        defer { lease.close() }
        #expect(try fixture.store.requestRemoval(id: package.id) == false)
        let installer = ExtensionPackageInstaller(
            store: fixture.store,
            download: { _, _ in throw MarketplaceError.downloadFailed },
            verify: { _ in
                let before = try fixture.store.pendingRemovals()
                #expect(before.isEmpty)
                #expect(throws: MarketplaceError.packageBusy) {
                    try fixture.store.requestRemoval(id: package.id)
                }
                let after = try fixture.store.pendingRemovals()
                #expect(after.isEmpty)
            })
        #expect(try await installer.install([package], repository: "example/app") == [package])
        lease.close()
        try fixture.store.completePendingRemovals()
        #expect(try fixture.store.installedPackages() == [package])
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
    }

    @Test func identicalReinstallSupersedesRepeatedInterruptedPendingRemoval() async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        let archive = try #require(
            try FileManager.default.contentsOfDirectory(
                at: fixture.directory, includingPropertiesForKeys: nil
            )
            .first { $0.pathExtension == "zip" })
        let lease = try fixture.store.lease(package)
        #expect(try fixture.store.requestRemoval(id: package.id) == false)
        lease.close()
        var interrupted = fixture.store
        interrupted.deletionCheckpoint = { checkpoint in
            if checkpoint == .installedWritten { throw POSIXError(.EINTR) }
        }
        #expect(throws: MarketplaceError.packageCleanupPending) {
            try interrupted.completePendingRemovals()
        }
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(try fixture.store.pendingRemovals() == [package.id])
        var restarted = ExtensionPackageStore(root: fixture.store.root)
        restarted.deletionCheckpoint = { checkpoint in
            if checkpoint == .selectionsWritten { throw POSIXError(.EINTR) }
        }
        #expect(throws: MarketplaceError.packageCleanupPending) {
            try restarted.completePendingRemovals()
        }
        #expect(try restarted.pendingRemovals() == [package.id])
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        #expect(try fixture.store.pendingRemovals().isEmpty)
        let final = ExtensionPackageStore(root: fixture.store.root)
        try final.completePendingRemovals()
        #expect(try final.installedPackages() == [package])
        #expect(!FileManager.default.fileExists(atPath: intent(fixture).path))
        #expect(FileManager.default.fileExists(atPath: final.directory(for: package).path))
    }

    @Test func failedPendingCancellationPreservesPayloadAndMetadata() async throws {
        try #require(geteuid() != 0)
        let (fixture, package) = try await installedFixture()
        defer {
            _ = chmod(fixture.store.root.path, 0o700)
            fixture.clean()
        }
        let lease = try fixture.store.lease(package)
        #expect(try fixture.store.requestRemoval(id: package.id) == false)
        lease.close()
        let installed = fixture.store.root.appendingPathComponent("installed.json")
        let selected = fixture.store.root.appendingPathComponent("selected-packages.json")
        let pending = fixture.store.root.appendingPathComponent("pending-removals.json")
        let files = [installed, selected, pending]
        let original = try files.map { try Data(contentsOf: $0) }
        let payload = fixture.store.directory(for: package)
        let identity =
            try FileManager.default.attributesOfItem(atPath: payload.path)[.systemFileNumber]
            as? NSNumber
        #expect(chmod(fixture.store.root.path, 0o500) == 0)
        await #expect(throws: POSIXError.self) {
            try await fixture.installer(archives: [:]).install([package], repository: "example/app")
        }
        #expect(chmod(fixture.store.root.path, 0o700) == 0)
        #expect(try files.map { try Data(contentsOf: $0) } == original)
        #expect(
            try FileManager.default.attributesOfItem(atPath: payload.path)[.systemFileNumber]
                as? NSNumber == identity)
        let runtime = payload.appendingPathComponent(
            package.id + "/helper.bundle/Contents/MacOS/Runtime")
        #expect(try Data(contentsOf: runtime) == Data("original payload".utf8))
    }

    @Test func operationContentionNeverQueuesOrSweepsPendingRemoval() async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        let operation = try PackageFileLock(
            url: fixture.store.root.appendingPathComponent(".operation.lock"), exclusive: true)
        #expect(throws: MarketplaceError.packageBusy) {
            try fixture.store.requestRemoval(id: package.id)
        }
        #expect(try fixture.store.pendingRemovals().isEmpty)
        let pending = fixture.store.root.appendingPathComponent("pending-removals.json")
        let malformed = Data("malformed pending fixture".utf8)
        try malformed.write(to: pending)
        #expect(throws: MarketplaceError.packageBusy) {
            try fixture.store.completePendingRemovals()
        }
        #expect(try Data(contentsOf: pending) == malformed)
        #expect(try fixture.store.installedPackages() == [package])
        operation.close()
    }

    @Test func invalidPlanPreservesQueueAndAcceptedDownloadFailureCancelsIt() async throws {
        let (fixture, package) = try await installedFixture()
        defer { fixture.clean() }
        let lease = try fixture.store.lease(package)
        #expect(try fixture.store.requestRemoval(id: package.id) == false)
        lease.close()
        let installer = fixture.installer(archives: [:])
        await #expect(throws: MarketplaceError.invalidCatalog) {
            try await installer.install([package, package], repository: "example/app")
        }
        #expect(try fixture.store.pendingRemovals() == [package.id])
        let (update, _) = try fixture.archive("2.0.0")
        await #expect(throws: MarketplaceError.downloadFailed) {
            try await installer.install([update], repository: "example/app")
        }
        #expect(try fixture.store.pendingRemovals().isEmpty)
        try fixture.store.completePendingRemovals()
        #expect(try fixture.store.installedPackages() == [package])
    }

}
