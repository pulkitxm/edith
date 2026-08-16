import Testing
@testable import EdithHelper

@Suite struct ShelfThumbnailCacheTests {
    @Test func evictsLeastRecentlyUsedEntryAtCapacity() {
        var cache = ShelfThumbnailLRUCache<String, Int>()
        cache.insert(1, for: "first", maxEntries: 3)
        cache.insert(2, for: "second", maxEntries: 3)
        cache.insert(3, for: "third", maxEntries: 3)

        #expect(cache.value(for: "first") == 1)

        cache.insert(4, for: "fourth", maxEntries: 3)

        #expect(cache.count == 3)
        #expect(cache.value(for: "second") == nil)
        #expect(cache.value(for: "first") == 1)
        #expect(cache.value(for: "third") == 3)
        #expect(cache.value(for: "fourth") == 4)
    }

    @Test func replacingEntryRefreshesItsRecency() {
        var cache = ShelfThumbnailLRUCache<String, Int>()
        cache.insert(1, for: "first", maxEntries: 2)
        cache.insert(2, for: "second", maxEntries: 2)
        cache.insert(10, for: "first", maxEntries: 2)
        cache.insert(3, for: "third", maxEntries: 2)

        #expect(cache.count == 2)
        #expect(cache.value(for: "first") == 10)
        #expect(cache.value(for: "second") == nil)
        #expect(cache.value(for: "third") == 3)
    }

    @Test func evictsOldestEntriesDownToThumbnailLimit() {
        var cache = ShelfThumbnailLRUCache<Int, Int>()
        for key in 0..<205 {
            cache.insert(key, for: key, maxEntries: 200)
        }

        #expect(cache.count == 200)
        #expect(cache.value(for: 4) == nil)
        #expect(cache.value(for: 5) == 5)
        #expect(cache.value(for: 204) == 204)
    }
}
