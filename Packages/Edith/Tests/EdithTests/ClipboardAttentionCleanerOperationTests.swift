import AppKit
import Foundation
import Testing

@testable import EdithCLI
@testable import EdithKit

@Suite struct ClipboardAttentionCleanerOperationTests {
    @Test func descriptorsAreUniqueRegisteredAndMatchTheirLeaves() {
        let descriptors =
            ClipboardOperation.allCases.map(\.descriptor)
            + AttentionFocusOperation.allCases.map(\.descriptor)
            + CleanerOperation.allCases.map(\.descriptor)
        #expect(Set(descriptors.map(\.id)).count == descriptors.count)
        #expect(Set(descriptors.map(\.cli)).count == descriptors.count)
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(id: $0.id) == $0 })
        #expect(descriptors.allSatisfy { UserOperationCatalog.descriptor(cli: $0.cli) == $0 })
        #expect(
            descriptors.map(\.cli) == [
                ["clipboard", "stats"], ["clipboard", "copy"], ["clipboard", "pin"],
                ["clipboard", "unpin"], ["clipboard", "rm"],
                ["attention", "focus", "start"], ["attention", "focus", "stop"],
                ["cleaner", "scan"], ["cleaner", "clean"],
            ])
        #expect(
            Set(descriptors.filter(\.requiresPreview).map(\.id)) == [
                ClipboardOperation.remove.descriptor.id,
                CleanerOperation.clean.descriptor.id,
            ])
    }

    @Test func clipboardExecutorOwnsStatsPinningAndRemoval() async throws {
        try await CLIProbe.inWorld { world in
            try CLIClipboardTests.seed(world, count: 2)
            let entries = ClipboardActions.listed(defaults: world.shared)
            let loose = try #require(entries.first { !$0.pinned })

            #expect(ClipboardOperationExecution.stats(entries).count == 2)
            let pinned = try ClipboardOperationExecution.perform(.pin, entry: loose)
            #expect(pinned.changed == 1)
            #expect(pinned.entries.first { $0.id == loose.id }?.pinned == true)
            let unpinned = try ClipboardOperationExecution.perform(.unpin, entry: loose)
            #expect(unpinned.changed == 1)
            #expect(unpinned.entries.first { $0.id == loose.id }?.pinned == false)
            let removed = try ClipboardOperationExecution.perform(.remove, entry: loose)
            #expect(removed.changed == 1)
            #expect(!removed.entries.contains { $0.id == loose.id })
        }
    }

    @Test func clipboardCopyUsesTheNamedEntryAndReportsMissingBlobs() async throws {
        try await CLIProbe.inWorld { world in
            try CLIClipboardTests.seed(world, count: 1)
            let entry = try #require(ClipboardRepository.loadEntries().first)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            let copied = try ClipboardOperationExecution.perform(
                .copy, entry: entry, asPlainText: true, pasteboard: pasteboard)
            #expect(copied.changed == 1)
            #expect(pasteboard.string(forType: .string) == entry.preview)

            try FileManager.default.removeItem(
                at: ClipboardPaths.blobFile(sha256: entry.sha256, ext: entry.ext))
            #expect(throws: ClipboardOperationError.blobMissing) {
                try ClipboardOperationExecution.perform(
                    .copy, entry: entry, pasteboard: pasteboard)
            }
        }
    }

    @Test func clipboardCopyCanDeferTheIndexWriteForResponsiveUIActivation() async throws {
        try await CLIProbe.inWorld { world in
            try CLIClipboardTests.seed(world, count: 1)
            let entry = try #require(ClipboardRepository.loadEntries().first)
            let before = try Data(contentsOf: ClipboardPaths.indexFile)
            let pasteboard = NSPasteboard(name: NSPasteboard.Name(UUID().uuidString))
            let copiedAt = entry.lastCopiedAt.addingTimeInterval(60)

            let outcome = try ClipboardOperationExecution.perform(
                .copy, entry: entry, pasteboard: pasteboard,
                recordCopy: {
                    ClipboardActions.markingCopied(
                        id: $0, in: [entry], at: copiedAt)
                })
            #expect(outcome.entries.first?.lastCopiedAt == copiedAt)
            #expect(try Data(contentsOf: ClipboardPaths.indexFile) == before)
        }
    }

    @Test func focusExecutorNormalizesNamesAndCompletesTheSameSession() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let repository = AttentionRepository(root: root)

        let started = try AttentionFocusOperationExecution.start(
            name: "   ", duration: 1_500, repository: repository)
        #expect(started.name == "Focus")
        #expect(repository.activeFocus()?.id == started.id)
        let stopped = try AttentionFocusOperationExecution.stop(repository: repository)
        #expect(stopped.id == started.id)
        #expect(stopped.endedAt != nil)
        #expect(repository.activeFocus() == nil)
    }

    @Test func cleanerExecutorScansAndTargetsSelectedCategoryItems() throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: home) }
        let cache = home.appendingPathComponent("Library/Caches/Homebrew/downloads")
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
        try Data(repeating: 1, count: 4_096).write(to: cache.appendingPathComponent("bottle"))
        let entry = try #require(JunkCatalog.entries.first { $0.id == "homebrew" })

        let scan = CleanerOperationExecution.scan(entries: [entry], home: home)
        #expect(scan.categories.count == 1)
        let category = try #require(scan.categories.first)
        #expect(category.id == "homebrew")
        #expect(scan.items.count == 1)
        #expect(scan.totalBytes >= 4_096)
        let targets = CleanerOperationExecution.selectedItems(
            in: scan.categories, categoryID: "homebrew")
        #expect(targets.map(\.id) == scan.items.map(\.id))
        var reclaimed: [String] = []
        let clean = CleanerOperationExecution.clean(targets) { items in
            reclaimed = items.map(\.id)
            return items.reduce(0) { $0 + $1.sizeBytes }
        }
        #expect(reclaimed == targets.map(\.id))
        #expect(clean.items == 1)
        #expect(clean.reclaimedBytes == clean.requestedBytes)
    }
}
