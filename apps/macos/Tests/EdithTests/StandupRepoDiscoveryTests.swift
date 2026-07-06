import Foundation
import Testing

@testable import EdithKit

@Suite struct StandupRepoDiscoveryTests {
    private func makeTree() -> URL {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let paths = [
            "level1repo/.git",
            "nested/level2repo/.git",
            "nested/toodeep/level3repo/.git",
            "plainfolder",
        ]
        for path in paths {
            try! fm.createDirectory(
                at: root.appendingPathComponent(path), withIntermediateDirectories: true)
        }
        return root
    }

    @Test func findsRepoAtOneLevel() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = StandupRepoDiscovery.discover(roots: [root.path])
        #expect(found.contains(root.appendingPathComponent("level1repo").path))
    }

    @Test func findsRepoAtTwoLevels() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = StandupRepoDiscovery.discover(roots: [root.path])
        #expect(found.contains(root.appendingPathComponent("nested/level2repo").path))
    }

    @Test func doesNotDescendPastTwoLevels() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = StandupRepoDiscovery.discover(roots: [root.path])
        #expect(!found.contains(root.appendingPathComponent("nested/toodeep/level3repo").path))
    }

    @Test func ignoresNonRepoFolders() {
        let root = makeTree()
        defer { try? FileManager.default.removeItem(at: root) }
        let found = StandupRepoDiscovery.discover(roots: [root.path])
        #expect(!found.contains(root.appendingPathComponent("plainfolder").path))
    }

    @Test func skipsMissingRoots() {
        let found = StandupRepoDiscovery.discover(roots: ["/nonexistent/path/for/tests"])
        #expect(found.isEmpty)
    }
}
