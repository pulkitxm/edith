import CryptoKit
import Foundation
import Testing
@testable import ExtensionMarketplace

private struct PersistentDataSentinels {
    let bytes: [URL: Data]
    let hashes: [URL: Data]

    init(directory: URL, packageRoot: URL) throws {
        let values: [String: Data] = [
            "data/usage.json": Data(#"{"history":[{"provider":"synthetic","tokens":37}]}"#.utf8),
            "data/usage.sqlite": Data([0, 1, 2, 255, 17, 0, 83]),
            "data/usage.sqlite-wal": Data([55, 127, 6, 130, 0, 254, 31]),
            "data/usage.sqlite-shm": Data([0, 19, 0, 128, 7]),
            "Data/usage/data/usage.json": Data(#"{"history":[{"tokens":91}]}"#.utf8),
            "Core/Commands/Tasks/00000000-0000-0000-0000-000000000001.json": Data(
                #"{"title":"synthetic retained task","state":"completed"}"#.utf8),
            "Core/agent.json": Data(#"{"events":[{"message":"synthetic retained event"}]}"#.utf8),
            "machines/companion-config.json": Data(
                #"{"provider":"synthetic","enabled":true}"#.utf8),
            "provider-hook-ownership.json": Data(#"{"provider":"synthetic","owned":false}"#.utf8),
        ]
        bytes = Dictionary(
            uniqueKeysWithValues: values.map {
                (directory.appendingPathComponent($0.key), $0.value)
            })
        hashes = bytes.mapValues { Data(SHA256.hash(data: $0)) }
        for (file, data) in bytes {
            #expect(
                !file.standardizedFileURL.path.hasPrefix(
                    packageRoot.standardizedFileURL.path + "/"))
            try FileManager.default.createDirectory(
                at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: file)
        }
    }

    func expectPreserved() throws {
        for (file, expected) in bytes {
            let actual = try Data(contentsOf: file)
            #expect(actual == expected)
            #expect(Data(SHA256.hash(data: actual)) == hashes[file])
        }
    }
}

@Suite struct ExtensionPersistentDataLifecycleTests {
    @Test func failedUpdatesRollbackPruningRemovalAndReinstallPreserveExactData() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let sentinels = try PersistentDataSentinels(
            directory: fixture.directory.appendingPathComponent("support/Edith"),
            packageRoot: fixture.store.root)
        let first = try fixture.archive("1.0.0", id: "usage")
        let second = try fixture.archive("1.1.0", id: "usage")
        let third = try fixture.archive("1.2.0", id: "usage")
        let fourth = try fixture.archive("1.3.0", id: "usage")
        let items = [first, second, third, fourth]
        let paths = items.map { (package: $0.0, url: fixture.store.directory(for: $0.0)) }
        let installer = fixture.installer(
            archives: Dictionary(uniqueKeysWithValues: items.map { ($0.0.downloadURL, $0.1) }))
        _ = try await installer.install([first.0], repository: "example/app")
        try sentinels.expectPreserved()
        try fixture.store.select(first.0)
        try expectState(fixture.store, installed: [first.0], selected: first.0, paths: paths)
        try sentinels.expectPreserved()
        let metadata = try Data(
            contentsOf: fixture.store.root.appendingPathComponent("installed.json"))
        let selection = try Data(
            contentsOf: fixture.store.root.appendingPathComponent("selected-packages.json"))

        await #expect(throws: MarketplaceError.downloadFailed) {
            try await fixture.installer(archives: [:]).install(
                [second.0], repository: "example/app")
        }
        try expectState(fixture.store, installed: [first.0], selected: first.0, paths: paths)
        try expectUnchangedMetadata(fixture.store, metadata: metadata, selection: selection)
        try sentinels.expectPreserved()

        let originalArchive = try Data(contentsOf: second.1)
        var corruptArchive = originalArchive
        corruptArchive[20] ^= 1
        try corruptArchive.write(to: second.1)
        await #expect(throws: MarketplaceError.checksumMismatch) {
            try await installer.install([second.0], repository: "example/app")
        }
        try expectState(fixture.store, installed: [first.0], selected: first.0, paths: paths)
        try expectUnchangedMetadata(fixture.store, metadata: metadata, selection: selection)
        try sentinels.expectPreserved()
        try originalArchive.write(to: second.1)

        await #expect(throws: MarketplaceError.invalidSignature) {
            try await fixture.installer(
                archives: [second.0.downloadURL: second.1], rejectsSignature: true
            ).install([second.0], repository: "example/app")
        }
        try expectState(fixture.store, installed: [first.0], selected: first.0, paths: paths)
        try expectUnchangedMetadata(fixture.store, metadata: metadata, selection: selection)
        try sentinels.expectPreserved()

        _ = try await installer.install([second.0], repository: "example/app")
        try expectState(
            fixture.store, installed: [first.0, second.0], selected: first.0, paths: paths)
        try sentinels.expectPreserved()
        try fixture.store.select(second.0)
        try expectState(
            fixture.store, installed: [first.0, second.0], selected: second.0, paths: paths)
        try sentinels.expectPreserved()
        try fixture.store.select(first.0)
        try expectState(
            fixture.store, installed: [first.0, second.0], selected: first.0, paths: paths)
        try sentinels.expectPreserved()
        for item in [third, fourth] {
            _ = try await installer.install([item.0], repository: "example/app")
            try sentinels.expectPreserved()
        }
        try expectState(fixture.store, installed: items.map(\.0), selected: first.0, paths: paths)

        let retainedLease = try fixture.store.lease(second.0)
        defer { retainedLease.close() }
        try fixture.store.prune(hostABI: "host-1", systemVersion: 14)
        try expectState(fixture.store, installed: items.map(\.0), selected: first.0, paths: paths)
        try sentinels.expectPreserved()
        retainedLease.close()
        try fixture.store.prune(hostABI: "host-1", systemVersion: 14)
        let retained = [first.0, third.0, fourth.0]
        try expectState(fixture.store, installed: retained, selected: first.0, paths: paths)
        try sentinels.expectPreserved()

        let removalLease = try fixture.store.lease(fourth.0)
        defer { removalLease.close() }
        #expect(try fixture.store.requestRemoval(id: "usage") == false)
        #expect(try fixture.store.pendingRemovals() == ["usage"])
        try expectState(fixture.store, installed: retained, selected: first.0, paths: paths)
        try sentinels.expectPreserved()
        let reopened = ExtensionPackageStore(root: fixture.store.root)
        try reopened.completePendingRemovals()
        #expect(try reopened.pendingRemovals() == ["usage"])
        try expectState(reopened, installed: retained, selected: first.0, paths: paths)
        try sentinels.expectPreserved()
        removalLease.close()
        try reopened.completePendingRemovals()
        #expect(try reopened.pendingRemovals().isEmpty)
        try expectState(reopened, installed: [], selected: nil, paths: paths)
        try sentinels.expectPreserved()

        let reinstalledStore = ExtensionPackageStore(root: fixture.store.root)
        try expectState(reinstalledStore, installed: [], selected: nil, paths: paths)
        try sentinels.expectPreserved()
        _ = try await fixture.installer(archives: [first.0.downloadURL: first.1]).install(
            [first.0], repository: "example/app")
        try expectState(reinstalledStore, installed: [first.0], selected: first.0, paths: paths)
        try sentinels.expectPreserved()
        #expect(try reinstalledStore.remove(id: "usage"))
        try expectState(reinstalledStore, installed: [], selected: nil, paths: paths)
        try sentinels.expectPreserved()
    }

    private func expectState(
        _ store: ExtensionPackageStore, installed: [ExtensionPackage], selected: ExtensionPackage?,
        paths: [(package: ExtensionPackage, url: URL)]
    ) throws {
        #expect(
            try store.installedPackages().sorted { $0.version < $1.version }
                == installed.sorted { $0.version < $1.version })
        #expect(
            try store.installedPackage(
                id: "usage", hostABI: "host-1", architecture: "arm64", systemVersion: 14)
                == selected)
        for (package, path) in paths {
            #expect(
                FileManager.default.fileExists(atPath: path.path) == installed.contains(package))
            if installed.contains(package) {
                let payload = path.appendingPathComponent(package.id)
                #expect(
                    try JSONDecoder().decode(
                        ExtensionPayloadManifest.self,
                        from: Data(contentsOf: payload.appendingPathComponent("package.json")))
                        == ExtensionPayloadManifest(package: package))
                #expect(
                    try Data(
                        contentsOf: payload.appendingPathComponent(
                            "helper.bundle/Contents/MacOS/Runtime"))
                        == Data("fixture runtime \(package.version)".utf8))
            }
        }
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: store.root.path).allSatisfy {
                !$0.hasPrefix(".staging-")
            })
    }

    private func expectUnchangedMetadata(
        _ store: ExtensionPackageStore, metadata: Data, selection: Data
    ) throws {
        #expect(
            try Data(contentsOf: store.root.appendingPathComponent("installed.json")) == metadata)
        #expect(
            try Data(contentsOf: store.root.appendingPathComponent("selected-packages.json"))
                == selection)
    }
}
