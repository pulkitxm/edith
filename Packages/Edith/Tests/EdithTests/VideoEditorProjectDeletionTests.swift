import Foundation
import Testing

@testable import Edith

struct VideoEditorProjectDeletionTests {
    @Test func trashRemovesDiscoveryAndReferencesButPreservesProjectBytesAndMedia() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let library = root.appendingPathComponent("library")
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        let url = library.appendingPathComponent("sample.openscreen")
        let media = root.appendingPathComponent("source.mov")
        try Data("original source".utf8).write(to: media)
        var project = VideoProject.create(title: "Synthetic project")
        project.root["assets"] = [
            ["id": "source", "originalPath": media.path, "durationSec": 1],
            [
                "id": "missing", "originalPath": root.appendingPathComponent("missing.mov").path,
                "durationSec": 1,
            ],
        ]
        try project.save(to: url)
        let original = try Data(contentsOf: url)
        let registry = VideoProjectRegistry(libraryURL: library)
        _ = try registry.register(url)
        let trash = root.appendingPathComponent("trashed.openscreen")
        let dry = try await VideoEditorService.trashProject(url, dryRun: true, registry: registry) {
            _ in
            Issue.record("Dry run called the trash operation")
            return nil
        }
        #expect(!dry.written)
        #expect(dry.trashedPath == nil)
        #expect(try registry.library().count == 1)
        #expect(try Data(contentsOf: url) == original)
        let receipt = try await VideoEditorService.trashProject(url, registry: registry) {
            try FileManager.default.moveItem(at: $0, to: trash)
            return trash
        }
        #expect(receipt.written)
        #expect(receipt.trashedPath == trash.path)
        #expect(receipt.projectID == dry.projectID)
        #expect(try Data(contentsOf: trash) == original)
        #expect(try Data(contentsOf: media) == Data("original source".utf8))
        #expect(try registry.records().isEmpty)
        #expect(try registry.library().isEmpty)
    }

    @Test func invalidDocumentsFoldersAndSymlinksAreNeverTrashed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let invalid = root.appendingPathComponent("invalid.openscreen")
        try Data("{}".utf8).write(to: invalid)
        let folder = root.appendingPathComponent("folder.openscreen")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let alias = root.appendingPathComponent("alias.openscreen")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: invalid)
        let registry = VideoProjectRegistry(libraryURL: root)
        for url in [invalid, folder, alias] {
            await #expect(throws: (any Error).self) {
                try await VideoEditorService.trashProject(url, registry: registry) { _ in
                    Issue.record("Invalid input called the trash operation")
                    return nil
                }
            }
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }
}
