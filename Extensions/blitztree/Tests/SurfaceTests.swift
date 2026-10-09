import EdithExtensionSupport
import Testing
@testable import BlitzTreeExtension

@Suite @MainActor
struct BlitzTreeSurfaceTests {
    @Test func FolderSelectionAndScanStateUseOwnedOperations() async throws {
        let model = BlitzTreeModel(
            client: .init { root, _ in BlitzTreeClientTests.report(root: root) })
        #expect(BlitzTreeSurface.snapshot(model).actions.map(\.id) == ["choose"])
        model.scan("/synthetic")
        #expect(BlitzTreeSurface.snapshot(model).actions.map(\.id) == ["cancel"])
        await model.finishWork()
        let snapshot = BlitzTreeSurface.snapshot(model)
        #expect(snapshot.actions.map(\.id) == ["choose", "rescan"])
        #expect(snapshot.metrics.map(\.id) == ["space", "categories"])
        #expect(!snapshot.actions.contains { $0.id.contains("trash") })
        _ = try SurfaceSnapshot.decode(snapshot.encoded(), providerID: "blitztree")
        await model.shutdown()
    }
    @Test func overlappingFoldersAndHardLinksDoNotInflateReclaimableSpace() {
        let entries: [BlitzTreeReport.Entry] = [
            .init(
                path: "/synthetic/cache", kind: "directory", allocatedBytes: 8192,
                logicalBytes: 8192, fileCount: 1, complete: true, reason: nil, device: 1, inode: 1),
            .init(
                path: "/synthetic/cache/child", kind: "file", allocatedBytes: 4096,
                logicalBytes: 4096, fileCount: 1, complete: true, reason: nil, device: 1, inode: 2),
            .init(
                path: "/synthetic/other", kind: "file", allocatedBytes: 4096, logicalBytes: 4096,
                fileCount: 1, complete: true, reason: nil, device: 1, inode: 3),
            .init(
                path: "/synthetic/link", kind: "file", allocatedBytes: 4096, logicalBytes: 4096,
                fileCount: 1, complete: true, reason: nil, device: 1, inode: 3),
        ]
        #expect(BlitzTreeSurface.reclaimableBytes(entries) == 12288)
    }

}
