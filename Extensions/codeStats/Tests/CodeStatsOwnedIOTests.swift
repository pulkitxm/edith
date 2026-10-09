import EdithExtensionUI
import EdithExtensionSupport
import Foundation
import Testing
@testable import CodeStatsExtension

@Suite struct CodeStatsOwnedIOTests {
    @Test func rejectsTraversalAndSymlinkPublication() throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("owned")
        let external = fixture.root.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("repositories"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent("repositories/octo"), withDestinationURL: external)
        let store = CodeStatsStore(root: root)
        for name in [
            "../escape", "octo/../../escape", "octo/demo", "octo/", "octo\\demo", "octo/demo\u{0}",
        ] {
            #expect(throws: (any Error).self) {
                try store.save(
                    CodeStatsRepositoryCache(
                        repository: name, refsFingerprint: "a", identityFingerprint: "b",
                        commits: []))
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: external.path).isEmpty)
        #expect(store.loadCaches().isEmpty)
    }

    @Test func boundedReadRejectsOversizedAndSpecialFiles() throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let file = fixture.root.appendingPathComponent("bytes")
        try Data(repeating: 1, count: 10).write(to: file)
        #expect(CodeStatsOwnedIO.read(file, root: fixture.root, limit: 10)?.count == 10)
        #expect(CodeStatsOwnedIO.read(file, root: fixture.root, limit: 9) == nil)
        let link = fixture.root.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(CodeStatsOwnedIO.read(link, root: fixture.root) == nil)
        #expect(CodeStatsOwnedIO.read(fixture.root, root: fixture.root) == nil)
    }

    @Test func ownedStateUsesPrivatePermissionsAndRejectsRootSymlinks() throws {
        let fixture = try CodeStatsGitFixture()
        defer { fixture.remove() }
        let root = fixture.root.appendingPathComponent("state")
        let store = CodeStatsStore(root: root)
        try store.saveState(CodeStatsState())
        let permissions =
            try FileManager.default.attributesOfItem(
                atPath: root.appendingPathComponent("state.json").path)[.posixPermissions]
            as? NSNumber
        #expect(permissions?.intValue == 0o600)
        let linked = fixture.root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: root)
        #expect(throws: (any Error).self) {
            try CodeStatsStore(root: linked).saveState(CodeStatsState())
        }
        #expect(CodeStatsStore(root: linked).loadState() == CodeStatsState())
    }
}
