import Darwin
import Foundation
import Testing
@testable import ExtensionMarketplace

struct ExtensionPackageFilesystemTests {
    @Test(arguments: [0, 1, 2, 3, 4])
    func linkedPackageAncestorsRejectRemovalPruningAndReplacement(_ depth: Int) async throws {
        for action in ["remove", "prune", "replace"] {
            let fixture = try PackageFixture()
            defer { fixture.clean() }
            let (package, archive) = try fixture.archive()
            _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
                [package], repository: "example/app")
            if action == "prune" {
                try fixture.store.commit([
                    package,
                    fixturePackage(package.id, version: "2.0.0"),
                    fixturePackage(package.id, version: "3.0.0"),
                ])
            }
            if action == "replace" { try fixture.store.commit([]) }
            var ancestor = fixture.store.root
            for component in [package.id, package.hostABI, package.architecture, package.version]
                .prefix(depth)
            {
                ancestor.appendPathComponent(component)
            }
            let data = fixture.directory.appendingPathComponent("Data")
            try FileManager.default.moveItem(at: ancestor, to: data)
            let sentinel = data.appendingPathComponent("retained-user-data")
            let bytes = Data("synthetic persistent history".utf8)
            try bytes.write(to: sentinel)
            try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: data)
            switch action {
            case "remove":
                #expect(throws: (any Error).self) { try fixture.store.remove(id: package.id) }
            case "prune":
                #expect(throws: (any Error).self) { try fixture.store.prune(hostABI: "host-1") }
            default:
                await #expect(throws: (any Error).self) {
                    try await fixture.installer(archives: [package.downloadURL: archive]).install(
                        [package], repository: "example/app")
                }
            }
            #expect(try Data(contentsOf: sentinel) == bytes)
            let originalPayload = data.appendingPathComponent(
                Array(
                    [package.id, package.hostABI, package.architecture, package.version].dropFirst(
                        depth)
                )
                .joined(separator: "/")
            )
            .appendingPathComponent(package.id).appendingPathComponent("package.json")
            #expect(FileManager.default.fileExists(atPath: originalPayload.path))
        }
    }

    @Test(arguments: [0, 1])
    func failedMultiVersionRemovalRetainsRecordsAndRetriesAfterRestart(_ failingIndex: Int)
        async throws
    {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let first = try fixture.archive("1.0.0")
        let second = try fixture.archive("2.0.0")
        let packages = [first.0, second.0]
        for (package, archive) in [first, second] {
            _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
                [package], repository: "example/app")
        }
        try fixture.store.select(second.0)
        let selected = fixture.store.root.appendingPathComponent("selected-packages.json")
        let selectionBytes = try Data(contentsOf: selected)
        let blocked = fixture.store.directory(for: packages[failingIndex])
            .appendingPathComponent(packages[failingIndex].id)
            .appendingPathComponent("helper.bundle/Contents/MacOS")
        #expect(chmod(blocked.path, 0o500) == 0)
        #expect(throws: (any Error).self) { try fixture.store.remove(id: first.0.id) }
        #expect(try fixture.store.installedPackages() == packages)
        #expect(try Data(contentsOf: selected) == selectionBytes)
        #expect(
            FileManager.default.fileExists(
                atPath: fixture.store.directory(for: packages[failingIndex]).path))
        if failingIndex == 1 {
            #expect(
                !FileManager.default.fileExists(atPath: fixture.store.directory(for: first.0).path))
        }
        #expect(chmod(blocked.path, 0o700) == 0)
        let restarted = ExtensionPackageStore(root: fixture.store.root)
        #expect(try restarted.remove(id: first.0.id))
        #expect(try restarted.installedPackages().isEmpty)
        for package in packages {
            #expect(!FileManager.default.fileExists(atPath: restarted.directory(for: package).path))
        }
        #expect(
            try JSONDecoder().decode([ExtensionPackage].self, from: Data(contentsOf: selected))
                .isEmpty)
        #expect(try restarted.remove(id: first.0.id) == false)
    }

    @Test func absentPayloadsCompleteRemovalAndPruningIdempotently() throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let packages = ["1.0.0", "2.0.0", "3.0.0"].map { fixturePackage("keepAwake", version: $0) }
        try fixture.store.commit(packages)
        try fixture.store.prune(hostABI: "host-1")
        #expect(try fixture.store.installedPackages() == Array(packages.dropFirst()))
        #expect(try fixture.store.remove(id: "keepAwake"))
        #expect(try fixture.store.installedPackages().isEmpty)
    }

    @Test(arguments: [false, true])
    func writableRootAndDescendantsAreRejected(_ descendant: Bool) async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        let target =
            descendant ? fixture.store.root.appendingPathComponent(package.id) : fixture.store.root
        #expect(chmod(target.path, 0o777) == 0)
        #expect(throws: MarketplaceError.invalidArchive) {
            try fixture.store.remove(id: package.id)
        }
        #expect(chmod(target.path, 0o700) == 0)
        #expect(try fixture.store.installedPackages() == [package])
        #expect(FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
    }

    @Test func deletionKeepsPinnedParentAuthorityAcrossSubstitution() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        let authority = try PackageDirectory(fixture.store.root, create: false)
        let parent = try #require(try authority.parent(package))
        let original = fixture.store.directory(for: package).deletingLastPathComponent()
        let detached = fixture.directory.appendingPathComponent("detached-packages")
        try FileManager.default.moveItem(at: original, to: detached)
        let data = fixture.directory.appendingPathComponent("Data")
        let foreign = data.appendingPathComponent(package.version)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        let sentinel = foreign.appendingPathComponent("history")
        let bytes = Data("synthetic retained history".utf8)
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: data)
        try parent.removeTree(package.version)
        #expect(
            !FileManager.default.fileExists(
                atPath: detached.appendingPathComponent(package.version).path))
        #expect(try Data(contentsOf: sentinel) == bytes)
        #expect(throws: (any Error).self) { try authority.remove(package) }
    }

    @Test func payloadLinksAreUnlinkedWithoutFollowingTheirTargets() async throws {
        let fixture = try PackageFixture()
        defer { fixture.clean() }
        let (package, archive) = try fixture.archive()
        _ = try await fixture.installer(archives: [package.downloadURL: archive]).install(
            [package], repository: "example/app")
        let sentinel = fixture.directory.appendingPathComponent("history")
        let bytes = Data("synthetic user history".utf8)
        try bytes.write(to: sentinel)
        let link = fixture.store.directory(for: package).appendingPathComponent("retained-data")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: sentinel)
        #expect(try fixture.store.remove(id: package.id))
        #expect(try fixture.store.installedPackages().isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.store.directory(for: package).path))
        #expect(try Data(contentsOf: sentinel) == bytes)
    }
}
