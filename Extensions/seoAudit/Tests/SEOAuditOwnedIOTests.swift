import Foundation
import Testing
@testable import SEOAuditExtension

@Suite struct SEOAuditOwnedIOTests {
    @Test func projectDeleteRejectsAnAssetsSymlinkWithoutTouchingExternalData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = SEOAuditRepository(root: root.appendingPathComponent("owned"))
        let project = SEOAuditProject(name: "Synthetic", baseURL: "https://example.invalid")
        try repository.save(project)
        let external = root.appendingPathComponent("external")
        let saved = external.appendingPathComponent(project.id.uuidString.lowercased())
        try FileManager.default.createDirectory(at: saved, withIntermediateDirectories: true)
        let sentinel = saved.appendingPathComponent("sentinel")
        try Data([1]).write(to: sentinel)
        try FileManager.default.createSymbolicLink(
            at: repository.root.appendingPathComponent("assets"), withDestinationURL: external)
        let original = try repository.loadProject(id: project.id)
        #expect(throws: (any Error).self) { try repository.delete(id: project.id) }
        #expect(try Data(contentsOf: sentinel) == Data([1]))
        #expect(try repository.loadProject(id: project.id) == original)
    }

    @Test func stateReadsRejectOversizedAndSymbolicFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("bytes")
        try Data(repeating: 1, count: 10).write(to: file)
        #expect(SEOAuditOwnedIO.read(file, root: root, limit: 10)?.count == 10)
        #expect(SEOAuditOwnedIO.read(file, root: root, limit: 9) == nil)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(SEOAuditOwnedIO.read(link, root: root) == nil)
    }
}
