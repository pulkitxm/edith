import Foundation
import Testing

@testable import EdithKit

struct StorageInventoryTests {
    @Test func categoriesAreExclusiveAndSumToTheMeasuredTotal() throws {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        let inventory = fixture.inventory()
        let measurement = try StorageAccounting.scan(scopes: inventory.scopes)
        #expect(
            inventory.categories.map(\.id) == [
                "app", "feature-data", "selected-music-directory", "store", "cache",
                "logs-preferences", "other",
            ])
        #expect(
            inventory.categories.reduce(Int64(0)) { $0 + $1.bytes(in: measurement).logical }
                == measurement.total.logical)
        #expect(
            inventory.categories.reduce(Int64(0)) { $0 + $1.bytes(in: measurement).allocated }
                == measurement.total.allocated)
        #expect(measurement.total.complete)
        #expect(measurement.total.logical == StorageFixture.totalLogical)
    }

    @Test func featureAreasReportTheirOwnBytesAndNestedFoldersCountOnce() throws {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        let inventory = fixture.inventory()
        let measurement = try StorageAccounting.scan(scopes: inventory.scopes)
        let areas = Dictionary(uniqueKeysWithValues: inventory.areas.map { ($0.id, $0) })
        #expect(inventory.areas.map(\.id) == StorageAreaCatalog.areas.map(\.id))
        #expect(areas["machines"]?.bytes(in: measurement).logical == 1200)
        #expect(areas["music"]?.bytes(in: measurement).logical == 2600)
        #expect(areas["seoAudit"]?.bytes(in: measurement).logical == 1700)
        #expect(areas["latex"]?.bytes(in: measurement).exists == false)
        #expect(category("feature-data", inventory, measurement).logical == 5500)
        #expect(category("other", inventory, measurement).logical == 900)
        #expect(category("store", inventory, measurement).logical == 4300)
        #expect(category("cache", inventory, measurement).logical == 750)
        #expect(category("logs-preferences", inventory, measurement).logical == 520)
        #expect(category("app", inventory, measurement).logical == 7000)
    }

    @Test func usageListsEveryByteOnceLargestFirst() throws {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        let inventory = fixture.inventory()
        let measurement = try StorageAccounting.scan(scopes: inventory.scopes)
        let usage = inventory.usage(in: measurement)
        #expect(!usage.contains { $0.id == "feature-data" })
        #expect(!usage.contains { $0.id == "latex" })
        #expect(
            usage.reduce(Int64(0)) { $0 + $1.bytes.allocated } == measurement.total.allocated)
        #expect(
            usage.map(\.bytes.allocated) == usage.map(\.bytes.allocated).sorted(by: >))
        #expect(
            usage.first { $0.id == "music" }?.item.roots.map(\.lastPathComponent) == [
                "music", "thumbnails", "music-library-index.json",
            ])
        #expect(
            usage.first { $0.id == "store" }?.item.roots.map(\.lastPathComponent).contains(
                "Tasks") == true)
    }

    @Test func databaseBackupsCountUnderTheAppDatabase() throws {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        let inventory = fixture.inventory()
        let store = try #require(inventory.categories.first { $0.id == "store" })
        #expect(store.scopeIDs.count == 5)
        let roots = inventory.scopes.filter { store.scopeIDs.contains($0.id) }.map(
            \.root.lastPathComponent)
        #expect(roots.contains("edith.sqlite.pre-41"))
        #expect(roots.contains("Tasks"))
    }

    @Test func selectedMusicFolderInsideSupportOrDuplicatedIsNotCountedTwice() throws {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        for selected in [
            fixture.support.appendingPathComponent("music"),
            fixture.support.appendingPathComponent("Library/Tracks"),
            fixture.caches,
        ] {
            let inventory = fixture.inventory(selectedMusic: selected)
            #expect(!inventory.scopes.contains { $0.id == "music-selected-directory" })
            let measurement = try StorageAccounting.scan(scopes: inventory.scopes)
            #expect(
                category("selected-music-directory", inventory, measurement).logical == 0)
            #expect(measurement.total.logical == StorageFixture.totalLogical)
        }
        let outside = try fixture.file("Tracks/song.m4a", count: 640)
            .deletingLastPathComponent()
        let inventory = fixture.inventory(selectedMusic: outside)
        let measurement = try StorageAccounting.scan(scopes: inventory.scopes)
        #expect(category("selected-music-directory", inventory, measurement).logical == 640)
        #expect(measurement.total.logical == StorageFixture.totalLogical + 640)
    }

    @Test func missingAppBundleIsMarkedIncomplete() throws {
        let fixture = try StorageFixture()
        defer { fixture.clean() }
        let inventory = StorageInventory(
            appBundle: fixture.root.appendingPathComponent("Missing.app"), appVersion: nil,
            support: fixture.support, caches: fixture.caches, logs: fixture.logs,
            preferencesDirectory: fixture.preferences, preferenceSuites: [StorageFixture.suite],
            selectedMusicDirectory: nil)
        let measurement = try StorageAccounting.scan(scopes: inventory.scopes)
        #expect(!category("app", inventory, measurement).complete)
        #expect(!measurement.total.complete)
        #expect(
            measurement.issues.contains(
                "An expected app or package directory was not measured. Refresh after installation finishes."
            ))
    }

    private func category(
        _ id: String, _ inventory: StorageInventory, _ measurement: StorageMeasurement
    ) -> StorageBytes {
        inventory.categories.first { $0.id == id }?.bytes(in: measurement) ?? StorageBytes()
    }
}

struct StorageFixture {
    static let suite = "com.pulkit.edith.tests.storage"
    static let totalLogical: Int64 = 7000 + 5500 + 900 + 4300 + 750 + 520

    let root: URL
    var app: URL { root.appendingPathComponent("Edith.app") }
    var support: URL { root.appendingPathComponent("Support") }
    var caches: URL { root.appendingPathComponent("Caches") }
    var logs: URL { root.appendingPathComponent("Logs") }
    var preferences: URL { root.appendingPathComponent("Preferences") }

    init() throws {
        root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("storage-ui-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = try file("Edith.app/Contents/MacOS/Edith", count: 7000)
        _ = try file("Support/machines/machines.json", count: 1200)
        _ = try file("Support/music/track.json", count: 2000)
        _ = try file("Support/thumbnails/cover.jpg", count: 500)
        _ = try file("Support/music-library-index.json", count: 100)
        _ = try file("Support/SEOAudit/report.json", count: 1000)
        _ = try file("Support/Cache/SEOAudit/lighthouse.json", count: 700)
        _ = try file("Support/Cache/other.bin", count: 400)
        _ = try file("Support/settings.json", count: 500)
        _ = try file("Support/edith.sqlite", count: 3000)
        _ = try file("Support/edith.sqlite-wal", count: 200)
        _ = try file("Support/edith.sqlite.pre-41", count: 800)
        _ = try file("Support/Tasks/task.json", count: 300)
        _ = try file("Caches/favicons/icon.png", count: 600)
        _ = try file("Caches/Runtime/broker.lock", count: 150)
        _ = try file("Logs/edith.log", count: 400)
        _ = try file("Preferences/\(Self.suite).plist", count: 120)
        _ = try file("Preferences/unrelated.plist", count: 9000)
    }

    func inventory(selectedMusic: URL? = nil) -> StorageInventory {
        StorageInventory(
            appBundle: app, appVersion: "1.2.3", support: support, caches: caches, logs: logs,
            preferencesDirectory: preferences, preferenceSuites: [Self.suite, Self.suite],
            selectedMusicDirectory: selectedMusic)
    }

    @discardableResult
    func file(_ name: String, count: Int) throws -> URL {
        let url = root.appendingPathComponent(name)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 65, count: count).write(to: url)
        return url
    }

    func clean() { try? FileManager.default.removeItem(at: root) }
}
