import Foundation
import Testing
@testable import BlitzTreeExtension

@Suite struct BlitzTreeActionsTests {
    @Test func removalChecksIdentityAndScopeBeforeMoving() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("blitztree-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("fixture.bin")
        try Data([1, 2, 3]).write(to: file)
        let report = try BlitzTreeScanner.scan(root: root.path)
        let entry = try #require(report.report.inventory.largestChildren.first)
        var moved = false
        try BlitzTreeActions.trash(entry, root: report.root) { url in
            #expect(url.path == report.root + "/fixture.bin")
            moved = true
        }
        #expect(moved)
        #expect(throws: (any Error).self) {
            try BlitzTreeActions.trash(entry, root: root.path + "-other") { _ in
                Issue.record("An out-of-scope file must not move")
            }
        }
        try FileManager.default.moveItem(at: file, to: root.appendingPathComponent("original.bin"))
        try Data([4, 5]).write(to: file)
        #expect(throws: (any Error).self) {
            try BlitzTreeActions.trash(entry, root: report.root) { _ in
                Issue.record("A replaced file must not move")
            }
        }
        #expect(try Data(contentsOf: file) == Data([4, 5]))
    }

    @Test func swappedParentSymlinkIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
            .appendingPathComponent("blitztree-symlink-\(UUID().uuidString)")
        let parent = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data([1]).write(to: parent.appendingPathComponent("fixture.bin"))
        let report = try BlitzTreeScanner.scan(root: parent.path)
        let canonicalRoot = try BlitzTreeScanner.resolvedDirectory(root.path)
        let entry = try #require(report.report.inventory.largestChildren.first)
        let renamed = root.appendingPathComponent("renamed")
        try FileManager.default.moveItem(at: parent, to: renamed)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: renamed)
        #expect(throws: (any Error).self) {
            try BlitzTreeActions.trash(entry, root: canonicalRoot) { _ in
                Issue.record("A replaced parent must not be traversed for removal")
            }
        }
        #expect(
            FileManager.default.fileExists(
                atPath: renamed.appendingPathComponent("fixture.bin").path))
    }
}
