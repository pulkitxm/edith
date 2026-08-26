import Darwin
import Foundation
import Testing
@testable import EdithHelper
@testable import EdithKit

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

    @Test func copiesDirectoriesAndTheirSymbolicLinks() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-directory-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: source) }
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("Nested"), withIntermediateDirectories: true)
        let file = source.appendingPathComponent("Nested/file.txt")
        try "nested".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            atPath: source.appendingPathComponent("link.txt").path,
            withDestinationPath: "Nested/file.txt")

        let item = try #require(store.addCopy(of: source))
        let copied = store.fileURL(for: item)

        #expect(
            try String(
                contentsOf: copied.appendingPathComponent("Nested/file.txt"), encoding: .utf8)
                == "nested")
        #expect(
            try FileManager.default.destinationOfSymbolicLink(
                atPath: copied.appendingPathComponent("link.txt").path) == "Nested/file.txt")
    }

    @Test func persistsIndexAcrossInstances() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-source-\(UUID().uuidString).txt")
        try "hello".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        _ = store.addCopy(of: source)
        let reopened = ShelfStore(root: dir)
        await reopened.drainIndexRefreshes()
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
        try store.remove(item)
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
    }

    @Test func storesFilesFlatAtTheShelfRoot() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(store.addText("flat"))
        #expect(store.fileURL(for: item) == dir.appendingPathComponent(item.name))
    }

    @Test func duplicateNamesGetFinderStyleSuffixes() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-source-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: source) }
        let file = source.appendingPathComponent("Screenshot.png")
        try "a".write(to: file, atomically: true, encoding: .utf8)

        let first = try #require(store.addCopy(of: file))
        let second = try #require(store.addCopy(of: file))
        #expect(first.name == "Screenshot.png")
        #expect(second.name == "Screenshot 2.png")
        #expect(FileManager.default.fileExists(atPath: store.fileURL(for: second).path))
    }

    @Test func migratesLegacyPerItemFoldersToFlatFiles() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        let id = UUID()
        let legacyDir = dir.appendingPathComponent(id.uuidString)
        try fm.createDirectory(at: legacyDir, withIntermediateDirectories: true)
        try "legacy".write(
            to: legacyDir.appendingPathComponent("Note.txt"), atomically: true, encoding: .utf8)
        let legacyItems = [ShelfItem(id: id, name: "Note.txt", addedAt: Date())]
        try JSONEncoder().encode(legacyItems).write(to: dir.appendingPathComponent("index.json"))

        let store = ShelfStore(root: dir)
        await store.drainIndexRefreshes()
        let item = try #require(store.items.first)
        #expect(store.fileURL(for: item) == dir.appendingPathComponent("Note.txt"))
        #expect(try String(contentsOf: store.fileURL(for: item), encoding: .utf8) == "legacy")
        #expect(!fm.fileExists(atPath: legacyDir.path))

        let reopened = ShelfStore(root: dir)
        await reopened.drainIndexRefreshes()
        #expect(reopened.items.count == 1)
    }

    @Test func setPositionsPersistsAcrossInstances() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(store.addText("movable"))
        store.setPositions([item.id: CGPoint(x: 120, y: 60)])
        let reopened = ShelfStore(root: dir)
        await reopened.drainIndexRefreshes()
        #expect(reopened.items.first?.position == CGPoint(x: 120, y: 60))
    }

    @Test func purgeExpiredRemovesOnlyOnceThePolicyWindowHasPassed() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }

        let item = try #require(store.addText("drop me later"))
        let fileURL = store.fileURL(for: item)

        store.purgeExpired(keep: .oneHour, now: Date())
        await store.drainIndexRefreshes()
        #expect(store.items.map(\.id) == [item.id])
        #expect(FileManager.default.fileExists(atPath: fileURL.path))

        store.purgeExpired(keep: .oneHour, now: Date().addingTimeInterval(4000))
        await store.drainIndexRefreshes()
        #expect(store.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fileURL.path))
        #expect(try ShelfMutationExecution.snapshot(root: dir).items.isEmpty)
    }

    @Test func failedReloadKeepsTheLastKnownItems() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(store.addText("keep in memory"))
        try Data("broken".utf8).write(to: ShelfIndex.indexFile(in: dir))

        #expect(!store.reload())
        #expect(store.items.map(\.id) == [item.id])
        var performed = false
        #expect(throws: ShelfActionSelectionError.self) {
            _ = try store.withActionSelection(itemIDs: [item.id]) { _ in
                performed = true
            }
        }
        #expect(!performed)
        #expect(throws: ShelfMutationError.self) {
            try store.remove(item)
        }
        #expect(store.items.map(\.id) == [item.id])
    }

    @Test func failedPromiseAdoptionPreservesTheIncomingFile() async throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        await store.drainIndexRefreshes()
        try Data("broken".utf8).write(to: ShelfIndex.indexFile(in: dir))
        let id = UUID()
        let incoming = try #require(store.promiseDestination(id: id))
            .appendingPathComponent("Promised.txt")
        try "recoverable".write(to: incoming, atomically: true, encoding: .utf8)

        #expect(store.adopt(fileAt: incoming, id: id) == nil)
        #expect(FileManager.default.fileExists(atPath: incoming.path))
        #expect(try String(contentsOf: incoming, encoding: .utf8) == "recoverable")
    }

    @Test func successfulPromiseAdoptionPublishesBeforeRemovingTheIncomingFile() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let id = UUID()
        let incoming = try #require(store.promiseDestination(id: id))
            .appendingPathComponent("Promised.txt")
        try "received".write(to: incoming, atomically: true, encoding: .utf8)

        let item = try #require(store.adopt(fileAt: incoming, id: id))

        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        #expect(try String(contentsOf: store.fileURL(for: item), encoding: .utf8) == "received")
        #expect(try ShelfMutationExecution.snapshot(root: dir).items == [item])
    }

    @Test func activeSharePickerRejectsSecondIPCWithoutRelockingAndReleasesSelection() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let item = try #require(store.addText("shared"))
        var active: ShelfStoreActionSelection? = try store.actionSelection(itemIDs: [item.id])
        #expect(store.retainActionSelection(try #require(active).snapshot))
        active = nil
        let contender = open(
            dir.appendingPathComponent(".index.lock").path, O_RDWR | O_CLOEXEC)
        defer {
            if contender >= 0 { close(contender) }
        }
        #expect(contender >= 0)
        #expect(flock(contender, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
        let requestID = "second-share"
        let payload = ShelfItemOperationExecution.payload(
            .share, itemIDs: [item.id], requestID: requestID)
        var performed = false
        let clock = ContinuousClock()
        let started = clock.now

        let rejected = try #require(
            ShelfOperationRequestRouter.route(
                payload, isSharing: true,
                perform: { _, _ in
                    performed = true
                    return nil
                }))

        #expect(clock.now - started < .seconds(1))
        #expect(!performed)
        #expect(rejected.requestID == requestID)
        #expect(rejected.operation == .share)
        #expect(rejected.error == ShelfActionSelectionError.busy.localizedDescription)
        #expect(!store.reload())
        #expect(throws: ShelfActionSelectionError.self) {
            try store.remove(item)
        }

        store.releaseActionSelection()
        #expect(flock(contender, LOCK_EX | LOCK_NB) == 0)
        #expect(flock(contender, LOCK_UN) == 0)
        let completed = try #require(
            ShelfOperationRequestRouter.route(
                payload, isSharing: false,
                perform: { _, itemIDs in
                    performed = true
                    do {
                        return try store.withActionSelection(itemIDs: itemIDs) { selection in
                            try selection.fileURLs().count == 1
                                ? nil : "the selected shelf items are not available"
                        }
                    } catch {
                        return error.localizedDescription
                    }
                }))

        #expect(performed)
        #expect(completed.requestID == requestID)
        #expect(completed.error == nil)
    }

    @Test func promisedFileWaitsForPickerReleaseBeforeReportingSuccess() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = try #require(store.addText("shared"))
        let promiseID = UUID()
        let incoming = try #require(store.promiseDestination(id: promiseID))
        let promised = incoming.appendingPathComponent("Promised.txt")
        try "promised".write(to: promised, atomically: true, encoding: .utf8)
        var active: ShelfStoreActionSelection? = try store.actionSelection(itemIDs: [shared.id])
        #expect(store.retainActionSelection(try #require(active).snapshot))
        active = nil
        var completionCount = 0
        var hapticCount = 0
        var adopted: ShelfItem?

        store.adoptWhenAvailable(fileAt: promised, id: promiseID) { item in
            completionCount += 1
            adopted = item
            if item != nil { hapticCount += 1 }
        }

        #expect(completionCount == 0)
        #expect(hapticCount == 0)
        #expect(FileManager.default.fileExists(atPath: promised.path))
        store.releaseActionSelection()
        let item = try #require(adopted)
        #expect(completionCount == 1)
        #expect(hapticCount == 1)
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        #expect(try String(contentsOf: store.fileURL(for: item), encoding: .utf8) == "promised")
    }

    @Test func cancelledPickerCleansQueuedPromiseWithoutReportingSuccess() throws {
        let (store, dir) = makeStore()
        defer { try? FileManager.default.removeItem(at: dir) }
        let shared = try #require(store.addText("shared"))
        let promiseID = UUID()
        let incoming = try #require(store.promiseDestination(id: promiseID))
        let promised = incoming.appendingPathComponent("Promised.txt")
        try "promised".write(to: promised, atomically: true, encoding: .utf8)
        var active: ShelfStoreActionSelection? = try store.actionSelection(itemIDs: [shared.id])
        #expect(store.retainActionSelection(try #require(active).snapshot))
        active = nil
        var completionCount = 0

        store.adoptWhenAvailable(fileAt: promised, id: promiseID) { _ in
            completionCount += 1
        }
        store.cancelActionSelection()

        #expect(completionCount == 0)
        #expect(!FileManager.default.fileExists(atPath: incoming.path))
        #expect(store.reload())
        #expect(store.items.map(\.id) == [shared.id])
    }
}

@Suite struct ShelfMutationOperationTests {
    @Test func postRenameIndexSyncFailureKeepsAddedPayloadAndIndexAligned() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-add-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var synchronization = 0
        let hooks = ShelfFileSystemHooks { descriptor, _ in
            synchronization += 1
            return synchronization == 2 ? false : fsync(descriptor) == 0
        }

        let result = try ShelfMutationExecution.addText(
            "durable", root: root, sender: "test", fileSystem: hooks)
        let item = try #require(result.item)

        #expect(synchronization == 2)
        #expect(try ShelfMutationExecution.snapshot(root: root).items == [item])
        #expect(
            try String(
                contentsOf: ShelfIndex.fileURL(for: item, in: root), encoding: .utf8)
                == "durable")
    }

    @Test func postRenameIndexSyncFailureDoesNotRollbackCommittedRemoval() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-remove-sync-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(
            ShelfMutationExecution.addText("remove", root: root, sender: "test").item)
        var synchronization = 0
        let hooks = ShelfFileSystemHooks { descriptor, _ in
            synchronization += 1
            return synchronization == 5 ? false : fsync(descriptor) == 0
        }

        let result = try ShelfMutationExecution.remove(
            ids: [item.id], root: root, sender: "test", fileSystem: hooks)

        #expect(result.removed == [item])
        #expect(result.items.isEmpty)
        #expect(synchronization >= 5)
        #expect(try ShelfMutationExecution.snapshot(root: root).items.isEmpty)
        #expect(
            !FileManager.default.fileExists(atPath: ShelfIndex.fileURL(for: item, in: root).path))
    }

    @Test func nestedDirectorySyncFailurePreventsIndexPublication() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-nested-sync-\(UUID().uuidString)")
        let source = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-nested-source-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: source)
        }
        let nested = source.appendingPathComponent("Nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try "payload".write(
            to: nested.appendingPathComponent("file.txt"), atomically: true, encoding: .utf8)
        var rejectedNestedSync = false
        let hooks = ShelfFileSystemHooks { descriptor, url in
            if !rejectedNestedSync, url.lastPathComponent == "Nested" {
                rejectedNestedSync = true
                return false
            }
            return fsync(descriptor) == 0
        }

        #expect(throws: CocoaError.self) {
            _ = try ShelfMutationExecution.addCopy(
                of: source, root: root, sender: "test", fileSystem: hooks)
        }

        #expect(rejectedNestedSync)
        #expect(try ShelfMutationExecution.snapshot(root: root).items.isEmpty)
        #expect(
            FileManager.default.fileExists(atPath: nested.appendingPathComponent("file.txt").path))
    }

    @Test func concurrentTextAddsPreserveEveryItem() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-concurrent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<24 {
                group.addTask {
                    _ = try ShelfMutationExecution.addText(
                        "note \(index)", root: root, sender: "test")
                }
            }
            try await group.waitForAll()
        }

        let items = ShelfIndex.load(from: root)
        #expect(items.count == 24)
        #expect(Set(items.map(\.id)).count == 24)
        #expect(Set(items.map(\.name)).count == 24)
        let values = try Set(
            items.map {
                try String(
                    contentsOf: ShelfIndex.fileURL(for: $0, in: root), encoding: .utf8)
            })
        #expect(values == Set((0..<24).map { "note \($0)" }))
    }

    @Test func malformedIndexFailsClosedWithoutOverwritingIt() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-corrupt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let index = ShelfIndex.indexFile(in: root)
        let original = Data("not json".utf8)
        try original.write(to: index)

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.addText("must not land", root: root, sender: "test")
        }

        #expect(try Data(contentsOf: index) == original)
        #expect(
            !FileManager.default.fileExists(
                atPath: root.appendingPathComponent("Dropped Text.txt").path))
    }

    @Test func unsafeIndexNamesCannotRemoveFilesOutsideTheShelf() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-path-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let outside = container.appendingPathComponent("outside.txt")
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        let item = ShelfItem(id: UUID(), name: "../outside.txt", addedAt: Date())
        try JSONEncoder().encode([item]).write(to: ShelfIndex.indexFile(in: root))

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.clear(root: root, sender: "test")
        }

        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
    }

    @Test(
        arguments: [
            ".index.json", ".index.lock", "index.json", ".incoming-request",
            ".removing-transaction", ".preparing-removal-transaction",
            ".quarantined-removal-transaction",
        ])
    func internalIndexNamesFailClosed(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-internal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let item = ShelfItem(id: UUID(), name: name, addedAt: Date())
        try JSONEncoder().encode([item]).write(to: ShelfIndex.indexFile(in: root))

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.snapshot(root: root)
        }
    }

    @Test(
        arguments: [
            ".index.json", ".index.lock", "index.json", ".incoming-request",
            ".removing-transaction", ".preparing-removal-transaction",
            ".quarantined-removal-transaction", "../outside.txt",
        ])
    func internalAndTraversalNamesAreRewrittenOnAdd(_ name: String) throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-safe-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }

        let resolved = ShelfMutationExecution.uniqueName(name, root: root)

        #expect(resolved.hasPrefix("Shelf Item"))
        #expect((resolved as NSString).lastPathComponent == resolved)
    }

    @Test func internalAndMissingNamesCannotBeReused() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-reserved-\(UUID().uuidString)")
        let sources = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-sources-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: sources)
        }
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        let internalSource = sources.appendingPathComponent(".index.json")
        try "internal".write(to: internalSource, atomically: true, encoding: .utf8)
        let internalItem = try #require(
            ShelfMutationExecution.addCopy(
                of: internalSource, root: root, sender: "test"
            ).item)
        #expect(internalItem.name != ".index.json")

        let missing = ShelfItem(id: UUID(), name: "Missing.txt", addedAt: Date())
        var items = ShelfIndex.load(from: root)
        items.append(missing)
        ShelfIndex.save(items, to: root)
        let missingSource = sources.appendingPathComponent("Missing.txt")
        try "replacement".write(to: missingSource, atomically: true, encoding: .utf8)
        let added = try #require(
            ShelfMutationExecution.addCopy(
                of: missingSource, root: root, sender: "test"
            ).item)
        #expect(added.name == "Missing 2.txt")
    }

    @Test func unavailableLockPreventsMutation() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-lock-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent(".index.lock"), withIntermediateDirectories: true)

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.addText("blocked", root: root, sender: "test")
        }

        #expect(ShelfIndex.load(from: root).isEmpty)
    }

    @Test func lockSymlinksCannotRedirectCoordinationOutsideTheShelf() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-lock-link-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let outside = container.appendingPathComponent("outside.lock")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try "keep".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".index.lock"), withDestinationURL: outside)

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.addText("blocked", root: root, sender: "test")
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "keep")
    }

    @Test func shelfRootSymlinksCannotRedirectReadsOrRemovalOutsideTheShelf() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-root-link-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let outside = container.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)
        let item = ShelfItem(id: UUID(), name: victim.lastPathComponent, addedAt: Date())
        let index = ShelfIndex.indexFile(in: outside)
        let indexData = try JSONEncoder().encode([item])
        try indexData.write(to: index)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.snapshot(root: root)
        }
        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.clear(root: root, sender: "test")
        }
        #expect(try Data(contentsOf: index) == indexData)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
        #expect(
            !FileManager.default.fileExists(
                atPath: outside.appendingPathComponent(".index.lock").path))
        #expect(
            try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()
                == [".index.json", "victim.txt"])
    }

    @Test func rootReplacementAfterOpeningCannotRedirectTheLockedMutation() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-root-swap-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let pinned = container.appendingPathComponent("Pinned")
        let outside = container.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: container) }
        let item = try #require(
            ShelfMutationExecution.addText("inside", root: root, sender: "test").item)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent("victim.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)
        let outsideItem = ShelfItem(id: UUID(), name: victim.lastPathComponent, addedAt: Date())
        let outsideIndex = try JSONEncoder().encode([outsideItem])
        try outsideIndex.write(to: ShelfIndex.indexFile(in: outside))

        let result = try ShelfMutationExecution.clear(
            root: root, sender: "test",
            afterOpeningRoot: {
                try FileManager.default.moveItem(at: root, to: pinned)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
            })

        #expect(result.removed.map(\.id) == [item.id])
        #expect(
            !FileManager.default.fileExists(atPath: pinned.appendingPathComponent(item.name).path))
        #expect(try Data(contentsOf: ShelfIndex.indexFile(in: outside)) == outsideIndex)
        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
        #expect(
            !FileManager.default.fileExists(
                atPath: outside.appendingPathComponent(".index.lock").path))
    }

    @MainActor @Test func pinnedSelectionKeepsActionsOnTheOpenedShelfRoot() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-action-swap-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let pinned = container.appendingPathComponent("Pinned")
        let outside = container.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: container) }
        let item = try #require(
            ShelfMutationExecution.addText("inside", root: root, sender: "test").item)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let victim = outside.appendingPathComponent(item.name)
        try "outside".write(to: victim, atomically: true, encoding: .utf8)

        let selection = try ShelfMutationExecution.pinnedSelection(
            root: root,
            afterOpeningRoot: {
                try FileManager.default.moveItem(at: root, to: pinned)
                try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
            })
        let urls = try selection.fileURLs(for: [item.id])
        var opened: URL?

        #expect(
            ShelfItemOperationExecution.perform(
                .open, urls: urls,
                open: {
                    opened = $0
                    return true
                }))
        let openedURL = try #require(opened)
        #expect(
            openedURL.resolvingSymlinksInPath()
                == pinned.appendingPathComponent(item.name).resolvingSymlinksInPath())
        #expect(try String(contentsOf: openedURL, encoding: .utf8) == "inside")
        #expect(try String(contentsOf: victim, encoding: .utf8) == "outside")
    }

    @MainActor @Test func stagedShareAndDragIgnoreAPostResolutionRootSwap() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-staged-action-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let pinned = container.appendingPathComponent("Pinned")
        let outside = container.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: container) }
        let item = try #require(
            ShelfMutationExecution.addText("inside", root: root, sender: "test").item)
        var selection: ShelfPinnedSelection? = try ShelfMutationExecution.pinnedSelection(
            root: root)
        var staged: ShelfStagedFiles? = try #require(selection).stagedFiles(for: [item.id])
        let stagedURL = try #require(staged).urls[0]

        selection = nil
        try FileManager.default.moveItem(at: root, to: pinned)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try "outside".write(
            to: outside.appendingPathComponent(item.name), atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)

        var shared = ""
        #expect(
            ShelfItemOperationExecution.perform(
                .share, urls: try #require(staged).urls,
                share: { urls in
                    shared = (try? String(contentsOf: urls[0], encoding: .utf8)) ?? ""
                    return true
                }))
        let dragged = try String(contentsOf: stagedURL, encoding: .utf8)

        #expect(shared == "inside")
        #expect(dragged == "inside")
        #expect(
            try String(contentsOf: root.appendingPathComponent(item.name), encoding: .utf8)
                == "outside")
        let stagingRoot = stagedURL.deletingLastPathComponent()
        staged = nil
        #expect(!FileManager.default.fileExists(atPath: stagingRoot.path))
    }

    @MainActor @Test func pinnedSelectionSerializesSameNameRemovalAndReuseThroughAction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-action-reuse-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(
            ShelfMutationExecution.addText("original", root: root, sender: "test").item)
        var selection: ShelfPinnedSelection? = try ShelfMutationExecution.pinnedSelection(
            root: root)
        let urls = try #require(selection).fileURLs(for: [item.id])
        let competingLock = open(
            root.appendingPathComponent(".index.lock").path, O_RDWR | O_CLOEXEC)
        defer {
            if competingLock >= 0 { close(competingLock) }
        }
        #expect(competingLock >= 0)
        #expect(flock(competingLock, LOCK_EX | LOCK_NB) == -1)
        #expect(errno == EWOULDBLOCK)
        let started = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            started.signal()
            _ = try? ShelfMutationExecution.remove(
                id: item.id, root: root, sender: "test")
            _ = try? ShelfMutationExecution.addText(
                "replacement", root: root, sender: "test")
            finished.signal()
        }
        started.wait()
        var opened = ""

        #expect(
            ShelfItemOperationExecution.perform(
                .open, urls: urls,
                open: {
                    opened = (try? String(contentsOf: $0, encoding: .utf8)) ?? ""
                    return true
                }))
        #expect(opened == "original")
        selection = nil
        #expect(finished.wait(timeout: .now() + 2) == .success)
        let replacement = try #require(ShelfMutationExecution.snapshot(root: root).items.first)
        #expect(replacement.id != item.id)
        #expect(replacement.name == item.name)
        #expect(
            try String(
                contentsOf: ShelfIndex.fileURL(for: replacement, in: root), encoding: .utf8)
                == "replacement")
    }

    @MainActor @Test func filePromisesStageOutsideARedirectedShelfRoot() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-promise-root-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let outside = container.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root, withDestinationURL: outside)
        let store = ShelfStore(root: root)
        let id = UUID()
        let destination = try #require(store.promiseDestination(id: id))
        let promised = destination.appendingPathComponent("Promised.txt")
        try "staged".write(to: promised, atomically: true, encoding: .utf8)

        #expect(!destination.path.hasPrefix(outside.path + "/"))
        #expect(store.adopt(fileAt: promised, id: id) == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try String(contentsOf: promised, encoding: .utf8) == "staged")

        store.discardPromiseDestination(id: id)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func promisedFileCleanupPreservesAReplacementDirectory() throws {
        let incoming = try ShelfIncomingDirectory()
        let original = incoming.url
        let moved = original.deletingLastPathComponent().appendingPathComponent(
            "moved-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: original)
            try? FileManager.default.removeItem(at: moved)
        }
        try FileManager.default.moveItem(at: original, to: moved)
        try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
        let victim = original.appendingPathComponent("victim.txt")
        try "keep".write(to: victim, atomically: true, encoding: .utf8)

        try incoming.discard()

        #expect(try String(contentsOf: victim, encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: moved.path))
    }

    @Test func promisedFileCleanupPreservesAReplacementInsertedAtIsolation() throws {
        var original: URL?
        var moved: URL?
        var victim: URL?
        var interleaved = false
        let hooks = ShelfFileSystemHooks(beforePromisedDirectoryIsolation: {
            guard !interleaved, let original, let moved else { return }
            interleaved = true
            try FileManager.default.moveItem(at: original, to: moved)
            try FileManager.default.createDirectory(at: original, withIntermediateDirectories: true)
            let replacement = original.appendingPathComponent("victim.txt")
            try "keep".write(to: replacement, atomically: true, encoding: .utf8)
            victim = replacement
        })
        let incoming = try ShelfIncomingDirectory(fileSystem: hooks)
        original = incoming.url
        moved = incoming.url.deletingLastPathComponent().appendingPathComponent(
            "moved-\(UUID().uuidString)")
        defer {
            if let original { try? FileManager.default.removeItem(at: original) }
            if let moved { try? FileManager.default.removeItem(at: moved) }
        }

        try incoming.discard()

        #expect(interleaved)
        #expect(try String(contentsOf: #require(victim), encoding: .utf8) == "keep")
        #expect(!FileManager.default.fileExists(atPath: try #require(moved).path))
    }

    @Test func interruptedRemovalRollsBackFromItsTransaction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-removal-rollback-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let added = try ShelfMutationExecution.addText("recover", root: root, sender: "test")
        let item = try #require(added.item)
        let staging = root.appendingPathComponent(".removing-interrupted")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode([item]).write(to: staging.appendingPathComponent(".items.json"))
        try FileManager.default.moveItem(
            at: ShelfIndex.fileURL(for: item, in: root),
            to: staging.appendingPathComponent(item.id.uuidString))

        let snapshot = try ShelfMutationExecution.snapshot(root: root)

        #expect(snapshot.items == [item])
        #expect(
            FileManager.default.fileExists(
                atPath: ShelfIndex.fileURL(for: item, in: root).path))
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func committedRemovalFinishesDeletingItsTransaction() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-removal-commit-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let added = try ShelfMutationExecution.addText("remove", root: root, sender: "test")
        let item = try #require(added.item)
        let staging = root.appendingPathComponent(".removing-committed")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try JSONEncoder().encode([item]).write(to: staging.appendingPathComponent(".items.json"))
        try FileManager.default.moveItem(
            at: ShelfIndex.fileURL(for: item, in: root),
            to: staging.appendingPathComponent(item.id.uuidString))
        ShelfIndex.save([], to: root)

        let snapshot = try ShelfMutationExecution.snapshot(root: root)

        #expect(snapshot.items.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: staging.path))
    }

    @Test func missingRemovalManifestIsQuarantinedWithoutBlockingTheShelf() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-removal-missing-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(
            ShelfMutationExecution.addText("keep", root: root, sender: "test").item)
        let staging = root.appendingPathComponent(".removing-missing")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let snapshot = try ShelfMutationExecution.snapshot(root: root)
        let quarantine = root.appendingPathComponent(".quarantined-removal-missing")

        #expect(snapshot.items == [item])
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
        #expect(
            try ShelfMutationExecution.addText("still writable", root: root, sender: "test").items
                .count == 2)
    }

    @Test func interruptedRemovalPreparationIsQuarantinedBeforeRecovery() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-removal-preparation-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(
            ShelfMutationExecution.addText("keep", root: root, sender: "test").item)
        let preparation = root.appendingPathComponent(".preparing-removal-interrupted")
        try FileManager.default.createDirectory(
            at: preparation, withIntermediateDirectories: true)

        let snapshot = try ShelfMutationExecution.snapshot(root: root)
        let quarantine = root.appendingPathComponent(".quarantined-removal-interrupted")

        #expect(snapshot.items == [item])
        #expect(!FileManager.default.fileExists(atPath: preparation.path))
        #expect(FileManager.default.fileExists(atPath: quarantine.path))
    }

    @Test func truncatedRemovalManifestIsQuarantinedWithItsPayload() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-removal-truncated-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let item = try #require(
            ShelfMutationExecution.addText("keep", root: root, sender: "test").item)
        let staging = root.appendingPathComponent(".removing-truncated")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try Data("[{".utf8).write(to: staging.appendingPathComponent(".items.json"))
        let stranded = staging.appendingPathComponent("stranded")
        try "preserve".write(to: stranded, atomically: true, encoding: .utf8)

        let snapshot = try ShelfMutationExecution.snapshot(root: root)
        let quarantine = root.appendingPathComponent(".quarantined-removal-truncated")

        #expect(snapshot.items == [item])
        #expect(!FileManager.default.fileExists(atPath: staging.path))
        #expect(
            try String(
                contentsOf: quarantine.appendingPathComponent("stranded"), encoding: .utf8)
                == "preserve")
        #expect(
            try Data(contentsOf: quarantine.appendingPathComponent(".items.json"))
                == Data("[{".utf8))
    }

    @Test func transactionSymlinksCannotReachOutsideTheShelf() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-transaction-link-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let outside = container.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appendingPathComponent("marker")
        try "keep".write(to: marker, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(".removing-link"), withDestinationURL: outside)

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.snapshot(root: root)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test func legacyFolderSymlinksCannotReachOutsideTheShelf() throws {
        let container = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-legacy-link-\(UUID().uuidString)")
        let root = container.appendingPathComponent("Shelf")
        let outside = container.appendingPathComponent("Outside")
        defer { try? FileManager.default.removeItem(at: container) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let item = ShelfItem(id: UUID(), name: "outside.txt", addedAt: Date())
        let marker = outside.appendingPathComponent(item.name)
        try "keep".write(to: marker, atomically: true, encoding: .utf8)
        try JSONEncoder().encode([item]).write(to: ShelfIndex.indexFile(in: root))
        try FileManager.default.createSymbolicLink(
            at: root.appendingPathComponent(item.id.uuidString), withDestinationURL: outside)

        #expect(throws: ShelfMutationError.self) {
            _ = try ShelfMutationExecution.snapshot(root: root)
        }
        #expect(try String(contentsOf: marker, encoding: .utf8) == "keep")
    }

    @Test func concurrentAddsAndRemovalsPreserveTheSerializedResult() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-mixed-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        var original: [ShelfItem] = []
        for index in 0..<20 {
            original.append(
                try #require(
                    ShelfMutationExecution.addText(
                        "old \(index)", root: root, sender: "test"
                    ).item))
        }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    _ = try ShelfMutationExecution.addText(
                        "new \(index)", root: root, sender: "test")
                }
            }
            for item in original {
                group.addTask {
                    _ = try ShelfMutationExecution.remove(
                        id: item.id, root: root, sender: "test")
                }
            }
            try await group.waitForAll()
        }

        let items = try ShelfMutationExecution.snapshot(root: root).items
        #expect(items.count == 20)
        #expect(Set(items.map(\.id)).isDisjoint(with: Set(original.map(\.id))))
        #expect(Set(items.map(\.name)).count == 20)
    }

    @Test func previewedRemovalDoesNotConsumeItemsAddedAfterTheSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-preview-race-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ShelfMutationExecution.addText("first", root: root, sender: "test")
        _ = try ShelfMutationExecution.addText("second", root: root, sender: "test")
        let previewed = try ShelfMutationExecution.snapshot(root: root).items
        let late = try #require(
            ShelfMutationExecution.addText("late", root: root, sender: "test").item)

        let result = try ShelfMutationExecution.remove(
            ids: Set(previewed.map(\.id)), root: root, sender: "test")

        #expect(result.removed == previewed)
        #expect(result.items == [late])
        #expect(
            try String(
                contentsOf: ShelfIndex.fileURL(for: late, in: root), encoding: .utf8) == "late")
    }

    @Test func catalogCarriesEveryExactShelfInvocation() {
        let actual = Set(
            UserInterfaceActionCatalog.actions
                .filter { $0.operation.id.rawValue.hasPrefix("shelf.") }
                .map { [$0.surface, $0.action] + $0.cli })
        let expected: Set<[String]> = [
            ["Notch shelf", "drop a file onto the shelf", "shelf", "add", "./file"],
            ["Notch shelf", "drop text onto the shelf", "shelf", "add-text", "note"],
            [
                "Notch shelf", "move an item on the canvas", "shelf", "update", "1", "--x",
                "120", "--y", "60",
            ],
            [
                "Notch shelf", "take selected items off the shelf", "shelf", "rm", "1", "2",
                "--yes",
            ],
            [
                "Notch shelf", "remove expired items", "shelf", "purge", "oneDay", "--yes",
            ],
            ["Notch shelf", "open selected items", "shelf", "open", "1", "2"],
            ["Notch shelf", "reveal selected items", "shelf", "reveal", "1", "2"],
            ["Notch shelf", "share selected items", "shelf", "share", "1", "2"],
        ]
        #expect(actual == expected)
        #expect(
            UserOperationCatalog.commandLineOnly.contains {
                $0.descriptor.id == ShelfMutationOperation.clear.descriptor.id
            })
    }

    @Test func textAndFileMutationsShareOnePersistedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-operations-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.deletingLastPathComponent()
            .appendingPathComponent("edith-shelf-source-\(UUID().uuidString).txt")
        try "file".write(to: source, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: source) }

        let copied = try ShelfMutationExecution.addCopy(
            of: source, root: root, addedAt: Date(timeIntervalSince1970: 100), sender: "test")
        let text = try ShelfMutationExecution.addText(
            "note", root: root, addedAt: Date(timeIntervalSince1970: 200), sender: "test")
        let textItem = try #require(text.item)

        #expect(copied.item?.name == source.lastPathComponent)
        #expect(text.items.count == 2)
        #expect(
            try String(
                contentsOf: ShelfIndex.fileURL(for: textItem, in: root), encoding: .utf8)
                == "note")
        #expect(ShelfIndex.load(from: root) == text.items)
    }

    @Test func purgeRemovesOnlyItemsPastTheNamedWindow() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-purge-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try ShelfMutationExecution.addText(
            "old", root: root, addedAt: Date(timeIntervalSince1970: 100), sender: "test")
        let recent = try ShelfMutationExecution.addText(
            "recent", root: root, addedAt: Date(timeIntervalSince1970: 3_500), sender: "test")

        let result = try ShelfMutationExecution.purgeExpired(
            keep: .oneHour, now: Date(timeIntervalSince1970: 4_000), root: root, sender: "test")

        #expect(result.removed.count == 1)
        #expect(result.items.map(\.id) == [recent.item?.id].compactMap { $0 })
        #expect(ShelfIndex.load(from: root) == result.items)
    }

    @Test func updateAndGroupedRemoveUseOneSharedSnapshot() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("edith-shelf-update-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let first = try #require(
            ShelfMutationExecution.addText("first", root: root, sender: "test").item)
        let second = try #require(
            ShelfMutationExecution.addText("second", root: root, sender: "test").item)

        let positioned = try ShelfMutationExecution.updatePositions(
            [first.id: CGPoint(x: 30, y: 40), second.id: CGPoint(x: 90, y: 100)],
            root: root, sender: "test")
        #expect(positioned.items.first { $0.id == first.id }?.position == CGPoint(x: 30, y: 40))
        #expect(positioned.items.first { $0.id == second.id }?.position == CGPoint(x: 90, y: 100))

        let removed = try ShelfMutationExecution.remove(
            ids: [first.id, second.id], root: root, sender: "test")
        #expect(removed.items.isEmpty)
        #expect(Set(removed.removed.map(\.id)) == [first.id, second.id])
    }
}
