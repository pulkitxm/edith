import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct CLIDestructiveSafetyTests {
    @Test func clipboardPreviewPreservesIndexAndBlobsThenConfirmationRemovesOnlyTargets()
        async throws
    {
        try await CLIProbe.inWorld { world in
            try CLIClipboardTests.seed(world, count: 3)
            let before = try Data(contentsOf: ClipboardPaths.indexFile)
            let entries = ClipboardBridge.entries()
            let blobBytes = try Dictionary(
                uniqueKeysWithValues: entries.map {
                    (
                        $0.id,
                        try Data(
                            contentsOf: ClipboardPaths.blobFile(sha256: $0.sha256, ext: $0.ext))
                    )
                })
            let preview = await CLIProbe.capture([
                "clipboard", "clear", "--keep-pinned", "--json",
            ])
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["changed"] as? Bool == false)
            let targets = Set(preview.object?["targets"] as? [String] ?? [])
            #expect(targets == Set(entries.filter { !$0.pinned }.map(\.id)))
            #expect(try Data(contentsOf: ClipboardPaths.indexFile) == before)
            for entry in entries {
                #expect(
                    try Data(
                        contentsOf: ClipboardPaths.blobFile(
                            sha256: entry.sha256, ext: entry.ext)) == blobBytes[entry.id])
            }

            let applied = await CLIProbe.capture([
                "clipboard", "clear", "--keep-pinned", "--yes", "--json",
            ])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            let remaining = ClipboardRepository.loadEntries()
            #expect(remaining.map(\.id) == entries.filter(\.pinned).map(\.id))
            #expect(Set(entries.map(\.id)).subtracting(remaining.map(\.id)) == targets)
        }
    }

    @Test func shelfPreviewPreservesBytesThenConfirmationRemovesOnlyNamedItem() async throws {
        try await CLIProbe.inWorld { world in
            try CLIShelfTests.seed(world, names: ["one.txt", "two.txt"])
            let items = ShelfBridge.items()
            let beforeIndex = try Data(contentsOf: ShelfIndex.indexFile())
            let beforeFiles = try Dictionary(
                uniqueKeysWithValues: items.map {
                    ($0.id, try Data(contentsOf: ShelfIndex.fileURL(for: $0)))
                })
            let preview = await CLIProbe.capture(["shelf", "rm", "1", "--json"])
            #expect(preview.object?["applied"] as? Bool == false)
            #expect(preview.object?["changed"] as? Bool == false)
            let target = try #require((preview.object?["targets"] as? [String])?.only)
            #expect(target == ShelfIndex.fileURL(for: items[0]).path)
            #expect(try Data(contentsOf: ShelfIndex.indexFile()) == beforeIndex)
            for item in items {
                #expect(try Data(contentsOf: ShelfIndex.fileURL(for: item)) == beforeFiles[item.id])
            }

            let applied = await CLIProbe.capture(["shelf", "rm", "1", "--yes", "--json"])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(!FileManager.default.fileExists(atPath: target))
            let kept = try #require(ShelfIndex.load().only)
            #expect(kept.id == items[1].id)
            #expect(try Data(contentsOf: ShelfIndex.fileURL(for: kept)) == beforeFiles[kept.id])
        }
    }

    @Test func shelfAndColorClearPreviewWithoutChangingTheirStores() async throws {
        try await CLIProbe.inWorld { world in
            try CLIShelfTests.seed(world, names: ["one.txt", "two.txt"])
            CLIColorTests.seed(world, count: 2)
            let shelfIndex = try Data(contentsOf: ShelfIndex.indexFile())
            let colorData = try #require(world.shared.data(forKey: "colorPickerHistory"))

            let shelf = await CLIProbe.capture(["shelf", "clear", "--json"])
            let color = await CLIProbe.capture(["color", "clear", "--json"])
            #expect(shelf.object?["applied"] as? Bool == false)
            #expect(color.object?["applied"] as? Bool == false)
            #expect(try Data(contentsOf: ShelfIndex.indexFile()) == shelfIndex)
            #expect(world.shared.data(forKey: "colorPickerHistory") == colorData)

            let applied = await CLIProbe.capture(["color", "clear", "--yes", "--json"])
            #expect(applied.object?["applied"] as? Bool == true)
            #expect(applied.object?["changed"] as? Bool == true)
            #expect(ColorHistoryStore.load(from: world.shared).isEmpty)
            #expect(try Data(contentsOf: ShelfIndex.indexFile()) == shelfIndex)
        }
    }
}

extension Array {
    fileprivate var only: Element? { count == 1 ? first : nil }
}
