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

    @Test(arguments: [false, true])
    func unregisterUsesStoredPathWhenReplacedBySymlink(targetRegistered: Bool) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let registry = VideoProjectRegistry(libraryURL: root.appendingPathComponent("library"))
        let source = root.appendingPathComponent("first.openscreen")
        let target = root.appendingPathComponent("second.openscreen")
        let original = root.appendingPathComponent("original.openscreen")
        _ = try VideoEditorService.create(at: source, title: "Original synthetic project")
        _ = try VideoEditorService.create(at: target, title: "Target synthetic project")
        let sourceBytes = try Data(contentsOf: source)
        let targetBytes = try Data(contentsOf: target)
        let registered = try registry.register(source)
        if targetRegistered { _ = try registry.register(target) }
        try FileManager.default.moveItem(at: source, to: original)
        try FileManager.default.createSymbolicLink(at: source, withDestinationURL: target)
        #expect(
            try registry.library().contains {
                $0.projectID == registered.projectID && $0.errorCode == "project_identity_changed"
            })
        let removed = try registry.unregister(source)
        #expect(removed.projectID == registered.projectID)
        #expect(removed.path == registered.path)
        #expect(!removed.registered)
        #expect(try registry.records().count == (targetRegistered ? 1 : 0))
        #expect(try Data(contentsOf: source) == targetBytes)
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(try Data(contentsOf: original) == sourceBytes)
        let targetEntry = try registry.register(target)
        try registry.checkIdentity(VideoEditorService.open(target), at: target)
        #expect(try registry.library().first?.projectID == targetEntry.projectID)
        #expect(try registry.library().first?.errorCode == nil)
    }

    @Test func unregisterKeepsStoredPathsDistinctAfterParentDirectoryBecomesSymlink() throws {
        let root = VideoProjectRegistry.canonical(
            FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        let firstDirectory = root.appendingPathComponent("A")
        let secondDirectory = root.appendingPathComponent("B")
        let preservedDirectory = root.appendingPathComponent("original-A")
        try FileManager.default.createDirectory(
            at: firstDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: secondDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let first = firstDirectory.appendingPathComponent("edit.openscreen")
        let second = secondDirectory.appendingPathComponent("edit.openscreen")
        _ = try VideoEditorService.create(at: first, title: "First synthetic project")
        _ = try VideoEditorService.create(at: second, title: "Second synthetic project")
        let firstBytes = try Data(contentsOf: first)
        let secondBytes = try Data(contentsOf: second)
        let registry = VideoProjectRegistry(libraryURL: root.appendingPathComponent("library"))
        let firstEntry = try registry.register(first)
        let secondEntry = try registry.register(second)
        let retained = try #require(registry.records().first)
        let stale = retained.projectID == firstEntry.projectID ? secondEntry : firstEntry
        let source = URL(fileURLWithPath: stale.path)
        let target = URL(fileURLWithPath: retained.path)
        let sourceDirectory = source.deletingLastPathComponent()
        let targetDirectory = target.deletingLastPathComponent()
        let sourceBytes = stale.projectID == firstEntry.projectID ? firstBytes : secondBytes
        let targetBytes = retained.projectID == firstEntry.projectID ? firstBytes : secondBytes
        try FileManager.default.moveItem(at: sourceDirectory, to: preservedDirectory)
        try FileManager.default.createSymbolicLink(
            at: sourceDirectory, withDestinationURL: targetDirectory)
        let removed = try registry.unregister(source)
        #expect(removed.path == stale.path)
        #expect(removed.projectID == stale.projectID)
        let remaining = try registry.records()
        #expect(remaining.count == 1)
        #expect(remaining.first?.path == retained.path)
        #expect(remaining.first?.projectID == retained.projectID)
        #expect(
            try Data(contentsOf: preservedDirectory.appendingPathComponent("edit.openscreen"))
                == sourceBytes)
        #expect(try Data(contentsOf: target) == targetBytes)
        #expect(
            try FileManager.default.destinationOfSymbolicLink(atPath: sourceDirectory.path)
                == targetDirectory.path)
    }
}
