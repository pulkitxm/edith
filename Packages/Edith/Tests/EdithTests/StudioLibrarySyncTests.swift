import Foundation
import Testing

@testable import Edith
@testable import EdithKit

@MainActor
struct StudioLibrarySyncTests {
    @Test func projectNotificationsAndDirectoryChangesRefreshCards() async throws {
        _ = try #require(ProcessInfo.processInfo.environment[DataRoot.devOverrideVariable])
        let root = try StudioTestFiles.folder().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("project.openscreen")
        var project = VideoProject.create(title: "Before")
        try project.save(to: source)
        let model = StudioModel(defaults: StudioTestFiles.defaults())
        model.watchLibrary(paths: [root])
        _ = try VideoEditorService.register(source)
        defer { _ = try? VideoEditorService.unregister(source) }
        for _ in 0..<150 where !model.videoProjects.contains(where: { $0.url == source }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.videoProjects.contains { $0.url == source && $0.title == "Before" })
        var metadata = try #require(project.root["project"] as? [String: Any])
        metadata["title"] = "After"
        project.root["project"] = metadata
        try project.save(to: source)
        for _ in 0..<150
        where !model.videoProjects.contains(where: { $0.url == source && $0.title == "After" }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.videoProjects.contains { $0.url == source && $0.title == "After" })
        let trash = root.appendingPathComponent("trashed.json")
        _ = try await VideoEditorService.trashProject(source, registry: VideoProjectRegistry()) {
            try FileManager.default.moveItem(at: $0, to: trash)
            return trash
        }
        for _ in 0..<150 where model.videoProjects.contains(where: { $0.url == source }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!model.videoProjects.contains { $0.url == source })
    }

    @Test func notificationRefreshesMediaAndSelectionWithoutMountingAView() async throws {
        let defaults = StudioTestFiles.defaults()
        let root = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.mov")
        try Data("source".utf8).write(to: source)
        let model = StudioModel(defaults: defaults)
        try StudioMediaLibrary.add([source], defaults: defaults)
        for _ in 0..<100 where model.files.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.files.map(\.url) == [source])
        model.selection = [source]
        try StudioMediaLibrary.clear(defaults: defaults)
        for _ in 0..<100 where !model.files.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.files.isEmpty)
        #expect(model.selection.isEmpty)
        #expect(try Data(contentsOf: source) == Data("source".utf8))
    }

    @Test func staleModelEditsReadLatestSavedState() throws {
        let defaults = StudioTestFiles.defaults()
        let root = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let first = root.appendingPathComponent("first.png")
        let second = root.appendingPathComponent("second.png")
        for url in [first, second] { try Data("source".utf8).write(to: url) }
        let model = StudioModel(defaults: defaults, loadsState: false)
        try StudioMediaLibrary.add([first], defaults: defaults)
        model.add([second])
        #expect(Set(model.files.map(\.url)) == [first, second])
        try StudioMediaLibrary.clear(defaults: defaults)
        model.remove([second])
        #expect(model.files.isEmpty)
        #expect(try StudioMediaLibrary.list(defaults: defaults).isEmpty)
    }

    @Test func directoryEventsRefreshMetadataWithoutLibraryNotification() async throws {
        let defaults = StudioTestFiles.defaults()
        let root = try StudioTestFiles.folder()
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("source.png")
        try Data("source".utf8).write(to: source)
        let model = StudioModel(defaults: defaults, loadsState: false)
        model.watchLibrary(paths: [root])
        let item = StudioMediaItem(url: source, addedAt: Date(timeIntervalSince1970: 42))
        defaults.set(try JSONEncoder().encode([item]), forKey: AppStorageKeys.Studio.library)
        defaults.synchronize()
        try Data("external edit".utf8).write(
            to: root.appendingPathComponent("event.json"), options: .atomic)
        for _ in 0..<150 where model.files != [item] {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(model.files == [item])
    }
}
