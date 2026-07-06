import Foundation
import Testing
@testable import EdithMenuBar

@Suite struct ShelfExpiryTests {
    let now = Date(timeIntervalSince1970: 1_750_000_000)

    @Test func foreverNeverExpires() {
        #expect(!ShelfExpiry.isExpired(addedAt: .distantPast, keep: .forever, now: now))
    }

    @Test func expiresAfterItsWindow() {
        let addedAt = now.addingTimeInterval(-3700)
        #expect(ShelfExpiry.isExpired(addedAt: addedAt, keep: .oneHour, now: now))
        #expect(!ShelfExpiry.isExpired(addedAt: addedAt, keep: .oneDay, now: now))
    }

    @Test func boundaryIsInclusive() {
        let addedAt = now.addingTimeInterval(-3600)
        #expect(ShelfExpiry.isExpired(addedAt: addedAt, keep: .oneHour, now: now))
    }
}

@MainActor
@Suite struct ShelfStoreTests {
    private func makeStore() -> (ShelfStore, URL) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-tests-\(UUID().uuidString)")
        return (ShelfStore(root: dir), dir)
    }

    @Test func copiesFileWithoutRemovingSource() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-source-\(UUID().uuidString).txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let item = try #require(store.addCopy(of: source))
        #expect(store.items.count == 1)
        #expect(FileManager.default.fileExists(atPath: source.path))
        #expect(try String(contentsOf: store.fileURL(for: item), encoding: .utf8) == "hello")
    }

    @Test func persistsIndexAcrossInstances() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-source-\(UUID().uuidString).txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        _ = store.addCopy(of: source)
        let reopened = ShelfStore(root: dir)
        #expect(reopened.items.count == 1)
    }

    @Test func removeDeletesFileAndIndexEntry() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-source-\(UUID().uuidString).txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let item = try #require(store.addCopy(of: source))
        let fileURL = store.fileURL(for: item)
        store.remove(item)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func purgeExpiredRemovesOnlyOnceThePolicyWindowHasPassed() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(store.addText("drop me later"))
        let fileURL = store.fileURL(for: item)

        store.purgeExpired(keep: .oneHour, now: Date())
        #expect(store.items.map(\.id) == [item.id])

        store.purgeExpired(keep: .oneHour, now: Date().addingTimeInterval(4000))
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }
}
