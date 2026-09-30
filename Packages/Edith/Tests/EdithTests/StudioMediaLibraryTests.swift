import Foundation
import Testing

@testable import EdithKit

struct StudioMediaLibraryTests {
    @Test func headlessEditsPreserveSourcesAndProjects() throws {
        let suite = "test.edith.studio.library.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let other = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = root.appendingPathComponent("first.mov")
        let second = root.appendingPathComponent("second.png")
        let project = root.appendingPathComponent("project.json")
        let recent = root.appendingPathComponent("recent.json")
        for url in [first, second, project, recent] {
            try Data("fixture".utf8).write(to: url)
        }
        try StudioMediaLibrary.add([first], defaults: defaults)
        try StudioMediaLibrary.add([second], defaults: other)
        #expect(try StudioMediaLibrary.list(defaults: defaults).map(\.url) == [second, first])
        try StudioMediaLibrary.remove([first], defaults: defaults)
        #expect(try StudioMediaLibrary.list(defaults: other).map(\.url) == [second])
        try StudioMediaLibrary.clear(defaults: other, recent: true, recentURL: recent)
        #expect(try StudioMediaLibrary.list(defaults: defaults).isEmpty)
        #expect(try Data(contentsOf: recent) == Data("[]".utf8))
        for url in [first, second, project] {
            #expect(try Data(contentsOf: url) == Data("fixture".utf8))
        }
    }

    @Test func mutationsReadExternalMetadataAndRejectCorruption() throws {
        let suite = "test.edith.studio.library.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let item = StudioMediaItem(
            url: URL(fileURLWithPath: "/missing.mov"),
            addedAt: Date(timeIntervalSince1970: 123))
        defaults.set(try JSONEncoder().encode([item]), forKey: AppStorageKeys.Studio.library)
        #expect(try StudioMediaLibrary.remove([], defaults: defaults) == [item])
        defaults.set(Data("broken".utf8), forKey: AppStorageKeys.Studio.library)
        #expect(throws: (any Error).self) {
            try StudioMediaLibrary.add([], defaults: defaults)
        }
        #expect(defaults.data(forKey: AppStorageKeys.Studio.library) == Data("broken".utf8))
    }
}
