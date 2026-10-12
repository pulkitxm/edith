import EdithExtensionSupport
import Foundation
import Testing
@testable import HomebrewExtension

@Suite @MainActor
struct HomebrewSurfaceTests {
    @Test func selectedKindsHaveTheirOwnCountsAndStableSources() throws {
        var tile = SurfaceTile(.ability("homebrew"))
        tile.sourceIDs = ["cask"]
        let packages = [
            HomebrewPackage(
                kind: .formula, name: "sample-tool", displayName: "Sample tool",
                installedVersions: ["1"]),
            HomebrewPackage(
                kind: .cask, name: "sample-app", displayName: "Sample app",
                installedVersions: ["1"], currentVersion: "2", outdated: true),
        ]
        let snapshot = HomebrewSurface.snapshot(packages: packages, tile: tile)
        #expect(snapshot.metrics.map(\.value) == ["1", "1"])
        #expect(snapshot.rows.map(\.sourceID) == ["cask"])
        #expect(snapshot.rows.first?.value == "1 to 2")
        #expect(snapshot.sources.map(\.id) == ["formula", "cask"])
        #expect(!snapshot.rows.flatMap(\.actions).contains { $0.id.contains("install") })
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "homebrew")
    }

    @Test func localSnapshotsObserveStandaloneInventoryChangesWithoutStartingAProcess() async throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HomebrewListingStore(fileURL: root.appendingPathComponent("inventory.json"))
        let surface = HomebrewSurface(store: store)
        let tile = SurfaceTile(.ability("homebrew"))
        #expect(try await surface.snapshot(tile).metrics.isEmpty)
        try await store.save(
            .init(
                status: .init(available: true, executable: "/synthetic/brew", version: "1"),
                packages: [
                    .formula: [
                        .init(
                            kind: .formula, name: "synthetic", displayName: "Synthetic package",
                            installedVersions: ["1"])
                    ]
                ]))
        #expect(try await surface.snapshot(tile).metrics.first?.value == "1")
        try await store.save(
            .init(
                status: .init(available: true, executable: "/synthetic/brew", version: "1"),
                packages: [:]))
        #expect(try await surface.snapshot(tile).metrics.first?.value == "0")
        surface.shutdown()
        await #expect(throws: ExtensionPeerError.self) { _ = try await surface.snapshot(tile) }
    }

    @Test func oversizedOrLinkedInventoryFilesAreNotRead() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("inventory.json")
        FileManager.default.createFile(atPath: file.path, contents: Data())
        let handle = try FileHandle(forWritingTo: file)
        try handle.truncate(atOffset: 8 * 1024 * 1024 + 1)
        try handle.close()
        #expect(await HomebrewListingStore(fileURL: file).load() == nil)
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(await HomebrewListingStore(fileURL: link).load() == nil)
    }

    @Test func disablingRejectsAnUncooperativeLateInventory() async {
        let gate = SurfaceInventoryGate()
        let surface = HomebrewSurface(load: { await gate.load() })
        let task = Task { try await surface.snapshot(SurfaceTile(.ability("homebrew"))) }
        while !(await gate.waiting) { await Task.yield() }
        surface.shutdown()
        await gate.release()
        await #expect(throws: (any Error).self) { _ = try await task.value }
    }
}

private actor SurfaceInventoryGate {
    private var continuation: CheckedContinuation<HomebrewListingSnapshot?, Never>?
    var waiting: Bool { continuation != nil }
    func load() async -> HomebrewListingSnapshot? {
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(returning: nil); continuation = nil }
}
