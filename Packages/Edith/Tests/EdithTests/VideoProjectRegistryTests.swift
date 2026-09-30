import Foundation
import Testing
@testable import Edith

@Suite struct VideoProjectRegistryTests {
    @Test func referencesDeduplicateAndLeaveOriginalUntouched() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.openscreen")
        var project = VideoProject.create(title: "Synthetic sample")
        try project.save(to: url)
        let original = try Data(contentsOf: url)
        let registry = VideoProjectRegistry(libraryURL: root.appendingPathComponent("library"))
        let alias = root.appendingPathComponent("alias.openscreen")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: url)
        #expect(try registry.register(url).path == url.resolvingSymlinksInPath().path)
        _ = try registry.register(alias)
        #expect(try registry.library().count == 1)
        #expect(try registry.records().count == 1)
        #expect(try Data(contentsOf: url) == original)
        _ = try registry.unregister(alias)
        #expect(try registry.library().isEmpty)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func staleAndReplacedReferencesRemainVisible() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("sample.openscreen")
        var project = VideoProject.create(title: "Synthetic sample")
        try project.save(to: url)
        let registry = VideoProjectRegistry(libraryURL: root.appendingPathComponent("library"))
        _ = try registry.register(url)
        let duplicate = root.appendingPathComponent("duplicate.openscreen")
        try FileManager.default.copyItem(at: url, to: duplicate)
        #expect(throws: VideoEditorService.Failure.self) { try registry.register(duplicate) }
        try FileManager.default.removeItem(at: url)
        #expect(try registry.library().first?.errorCode == "project_unavailable")
        var replacement = VideoProject.create(title: "Replacement")
        try replacement.save(to: url)
        #expect(try registry.library().first?.errorCode == "project_identity_changed")
        #expect(throws: VideoEditorService.Failure.self) { try registry.register(url) }
        _ = try registry.unregister(url)
        #expect(try registry.register(url).projectID == replacement.id)
    }

    @Test func nativeLibraryAndExternalReferencesDeduplicateAndInvalidDocumentsDoNotRegister()
        throws
    {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = VideoProjectRegistry(libraryURL: root)
        let url = root.appendingPathComponent("sample.openscreen")
        var project = VideoProject.create(title: "Native synthetic sample")
        try project.save(to: url)
        _ = try registry.register(url)
        #expect(try registry.library().count == 1)
        #expect(try registry.library().first?.registered == true)
        #expect(try registry.unregister(url).registered == false)
        #expect(try registry.library().count == 1)
        #expect(try registry.library().first?.registered == false)
        let invalid = root.appendingPathComponent("invalid.openscreen")
        try Data("{}".utf8).write(to: invalid)
        #expect(throws: (any Error).self) { try registry.register(invalid) }
        #expect(try registry.records().isEmpty)
    }
}
